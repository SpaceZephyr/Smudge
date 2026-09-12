import Foundation
import Metal
import simd

/// 一枚要画的金币
struct CoinSprite {
    var rect: SIMD4<Float>     // 遮罩像素坐标，和合成同一套
    var tint: SIMD4<Float>     // rgb + alpha
    var spin: Float
    var pop: Float             // 0 普通，>0 正在被吃掉
}

/// 一次要画进遮罩的东西
struct SpriteOp {
    var target: Int          // 0=T0 1=T1 2=T2(薄膜)
    var mode: Int            // 见 shader
    var rect: SIMD4<Float>   // 纹理像素
    var tint: SIMD4<Float>
    var shapeP: SIMD4<Float> = .zero
    var seed: Float = 0
    var blend: Blend = .add

    enum Blend { case add, mul, erase }
}

final class DirtSim {

    let device: MTLDevice
    private let pAdd: MTLRenderPipelineState
    private let pMul: MTLRenderPipelineState
    private let pErase: MTLRenderPipelineState
    private let pComp: MTLRenderPipelineState
    private let pCoin: MTLRenderPipelineState

    private(set) var maskW = 1
    private(set) var maskH = 1
    private var t0: MTLTexture!
    private var t1: MTLTexture!
    private var t2: MTLTexture!
    private var needsClear = true

    /// CPU 侧对每种脏总量的估计。不回读 GPU，只用来决定
    /// 油脊跟哪一种走、是否到了脏污上限、以及哪些通道可以不管了。
    private(set) var levels = [Float](repeating: 0, count: 6)
    private(set) var filmCoverage: Float = 1

    init(device: MTLDevice, drawableFormat: MTLPixelFormat) throws {
        self.device = device
        let lib = try device.makeLibrary(source: Shaders.source, options: nil)
        guard let vs = lib.makeFunction(name: "sprite_vs"),
              let fs = lib.makeFunction(name: "sprite_fs"),
              let cs = lib.makeFunction(name: "comp_fs"),
              let coinF = lib.makeFunction(name: "coin_fs") else {
            throw WindowRagError.shader("着色器入口找不到")
        }

        func mask(_ configure: (MTLRenderPipelineColorAttachmentDescriptor) -> Void) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vs
            d.fragmentFunction = fs
            d.colorAttachments[0].pixelFormat = .rgba8Unorm
            d.colorAttachments[0].isBlendingEnabled = true
            configure(d.colorAttachments[0])
            return try device.makeRenderPipelineState(descriptor: d)
        }

        // dst = src*(1-dst) + dst  —— 叠加但会自然饱和在 1
        pAdd = try mask { c in
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .oneMinusDestinationColor
            c.destinationRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .oneMinusDestinationAlpha
            c.destinationAlphaBlendFactor = .one
        }
        // dst = dst * src  —— 挥发
        pMul = try mask { c in
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .zero
            c.destinationRGBBlendFactor = .sourceColor
            c.sourceAlphaBlendFactor = .zero
            c.destinationAlphaBlendFactor = .sourceAlpha
        }
        // dst = dst * (1-src)  —— 擦
        pErase = try mask { c in
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .zero
            c.destinationRGBBlendFactor = .oneMinusSourceColor
            c.sourceAlphaBlendFactor = .zero
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        let cd = MTLRenderPipelineDescriptor()
        cd.vertexFunction = vs
        cd.fragmentFunction = cs
        cd.colorAttachments[0].pixelFormat = drawableFormat
        cd.colorAttachments[0].isBlendingEnabled = false
        pComp = try device.makeRenderPipelineState(descriptor: cd)

        // 金币画在合成结果之上，预乘的 source-over
        let kd = MTLRenderPipelineDescriptor()
        kd.vertexFunction = vs
        kd.fragmentFunction = coinF
        kd.colorAttachments[0].pixelFormat = drawableFormat
        kd.colorAttachments[0].isBlendingEnabled = true
        kd.colorAttachments[0].rgbBlendOperation = .add
        kd.colorAttachments[0].alphaBlendOperation = .add
        kd.colorAttachments[0].sourceRGBBlendFactor = .one
        kd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        kd.colorAttachments[0].sourceAlphaBlendFactor = .one
        kd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pCoin = try device.makeRenderPipelineState(descriptor: kd)
    }

    // MARK: - 尺寸

    func resize(width: Int, height: Int) {
        let w = max(8, width), h = max(8, height)
        if w == maskW && h == maskH && t0 != nil { return }
        maskW = w; maskH = h
        func make() -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        t0 = make(); t1 = make(); t2 = make()
        needsClear = true
        levels = [Float](repeating: 0, count: 6)
        filmCoverage = 1
    }

    // MARK: - 一帧

    /// 挥发 + 薄膜回补。ops 里是这一帧要落下的脏和要擦掉的部分。
    func encodeSim(_ cmd: MTLCommandBuffer, ops: [SpriteOp], decay0: SIMD4<Float>,
                   decay1: SIMD4<Float>, filmGrow: Float) {
        guard t0 != nil else { return }

        if needsClear {
            clear(cmd, t0, SIMD4(0, 0, 0, 0))
            clear(cmd, t1, SIMD4(0, 0, 0, 0))
            clear(cmd, t2, SIMD4(1, 0, 0, 0))   // 薄膜一开始铺满
            needsClear = false
        }

        let full = SIMD4<Float>(0, 0, Float(maskW), Float(maskH))

        for target in 0..<3 {
            let tex = target == 0 ? t0! : (target == 1 ? t1! : t2!)
            let mine = ops.filter { $0.target == target }
            let hasDecay = target < 2
            let hasGrow = target == 2 && filmGrow > 0.0001
            if mine.isEmpty && !hasDecay && !hasGrow { continue }

            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = tex
            rp.colorAttachments[0].loadAction = .load
            rp.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { continue }
            enc.label = "dirt.\(target)"

            if hasDecay {
                var u = uniform(rect: full, tint: target == 0 ? decay0 : decay1,
                                mode: 0, seed: 0, shapeP: .zero)
                draw(enc, pMul, &u)
            }
            if hasGrow {
                var u = uniform(rect: full, tint: SIMD4(filmGrow, 0, 0, 0), mode: 0, seed: 0, shapeP: .zero)
                draw(enc, pAdd, &u)
            }
            for op in mine {
                var u = uniform(rect: op.rect, tint: op.tint, mode: Float(op.mode),
                                seed: op.seed, shapeP: op.shapeP)
                let p = op.blend == .add ? pAdd : (op.blend == .mul ? pMul : pErase)
                draw(enc, p, &u)
            }
            enc.endEncoding()
        }
    }

    func encodeComposite(_ cmd: MTLCommandBuffer, into rp: MTLRenderPassDescriptor,
                         uniforms: [Float], coins: [CoinSprite] = []) {
        guard t0 != nil, let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.label = "composite"
        enc.setRenderPipelineState(pComp)
        var vu = uniform(rect: SIMD4(0, 0, Float(maskW), Float(maskH)),
                         tint: .zero, mode: 0, seed: 0, shapeP: .zero)
        enc.setVertexBytes(&vu, length: MemoryLayout<SpriteU>.stride, index: 0)
        enc.setFragmentTexture(t0, index: 0)
        enc.setFragmentTexture(t1, index: 1)
        enc.setFragmentTexture(t2, index: 2)
        var u = uniforms
        enc.setFragmentBytes(&u, length: MemoryLayout<Float>.stride * u.count, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        if !coins.isEmpty {
            enc.setRenderPipelineState(pCoin)
            for c in coins {
                var cu = uniform(rect: c.rect, tint: c.tint, mode: 9, seed: 0,
                                 shapeP: SIMD4(c.spin, c.pop, 0, 0))
                enc.setVertexBytes(&cu, length: MemoryLayout<SpriteU>.stride, index: 0)
                enc.setFragmentBytes(&cu, length: MemoryLayout<SpriteU>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        enc.endEncoding()
    }

    // MARK: - CPU 侧的量估计

    func noteSpawn(_ type: DirtType, amount: Float) {
        levels[type.rawValue] = min(4, levels[type.rawValue] + amount)
    }
    func decayLevels(rate: Float, dt: Float, frozen: Bool, failed: Bool) {
        guard !frozen, !failed, rate > 0 else { return }
        for t in DirtType.allCases {
            let k = max(0, 1 - min(0.6, rate * t.evap * dt))
            levels[t.rawValue] *= k
            if levels[t.rawValue] < 0.003 { levels[t.rawValue] = 0 }
        }
    }
    func noteWipe(fraction: Float) {
        for i in 0..<6 { levels[i] *= max(0, 1 - fraction) }
        filmCoverage = max(0, filmCoverage - fraction)
    }
    func noteFilmGrow(_ k: Float) {
        filmCoverage = min(1, filmCoverage + (1 - filmCoverage) * k)
    }
    func clearLevels() {
        levels = [Float](repeating: 0, count: 6)
    }
    /// 现在屏幕上最重的那一种，油脊和水痕跟着它走
    func heaviest(fallback: DirtType) -> DirtType {
        var best = fallback, v: Float = 0
        for t in DirtType.allCases where levels[t.rawValue] > v {
            v = levels[t.rawValue]; best = t
        }
        return v > 0 ? best : fallback
    }
    var dirtEstimate: Float {
        min(1, levels.reduce(0, +) * 0.42)
    }

    // MARK: - 私有

    private struct SpriteU {
        var rect: SIMD4<Float>
        var tint: SIMD4<Float>
        var shapeP: SIMD4<Float>
        var texSize: SIMD2<Float>
        var mode: Float
        var seed: Float
    }

    private func uniform(rect: SIMD4<Float>, tint: SIMD4<Float>, mode: Float,
                         seed: Float, shapeP: SIMD4<Float>) -> SpriteU {
        SpriteU(rect: rect, tint: tint, shapeP: shapeP,
                texSize: SIMD2(Float(maskW), Float(maskH)), mode: mode, seed: seed)
    }

    private func draw(_ enc: MTLRenderCommandEncoder, _ p: MTLRenderPipelineState, _ u: inout SpriteU) {
        enc.setRenderPipelineState(p)
        enc.setVertexBytes(&u, length: MemoryLayout<SpriteU>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<SpriteU>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func clear(_ cmd: MTLCommandBuffer, _ tex: MTLTexture, _ color: SIMD4<Float>) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(color.x), green: Double(color.y),
            blue: Double(color.z), alpha: Double(color.w))
        cmd.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
    }
}

enum WindowRagError: Error, LocalizedError {
    case shader(String)
    case noMetal
    var errorDescription: String? {
        switch self {
        case .shader(let s): return "着色器编译失败：\(s)"
        case .noMetal: return "这台机器没有可用的 Metal 设备"
        }
    }
}
