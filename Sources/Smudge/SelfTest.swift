import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// `Smudge --selftest out.png`
/// 离屏渲染一张图：六种脏各来几块，中间横着擦一道。
/// 不碰真实屏幕，用来核对着色器出来的东西对不对。
enum SelfTest {

    static func run(to path: String) -> Int32 {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            FileHandle.standardError.write(Data("没有 Metal 设备\n".utf8)); return 1
        }
        let W = 1000, H = 620
        let sim: DirtSim
        do { sim = try DirtSim(device: device, drawableFormat: .rgba8Unorm) }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); return 2 }
        sim.resize(width: W, height: H)

        // 六种脏各占一格
        var ops: [SpriteOp] = []
        for (i, t) in DirtType.allCases.enumerated() {
            let cx = Float(W) * (Float(i % 3) + 0.5) / 3
            let cy = Float(H) * (Float(i / 3) + 0.5) / 2
            for j in 0..<3 {
                let r = 62 * t.sizeMul * Float.random(in: 0.7...1.2)
                let x = cx + Float.random(in: -90...90)
                let y = cy + Float.random(in: -60...60)
                var tint = SIMD4<Float>()
                tint[t.channel] = min(1, 0.55 * t.alphaMul)
                ops.append(SpriteOp(target: t.texIndex, mode: t.shape,
                                    rect: SIMD4(x - r, y - r, r * 2, r * 2),
                                    tint: tint, shapeP: SIMD4(5, 0, 0, 0),
                                    seed: Float(i * 31 + j * 7) + 0.5, blend: .add))
            }
        }
        // 中间横着擦一道，带水痕
        let bandY = Float(H) * 0.5 - 46
        let f: Float = 13
        for step in 0..<20 {
            let x = Float(W) * Float(step) / 20 - f
            ops.append(SpriteOp(target: 0, mode: 7,
                                rect: SIMD4(x, bandY - f, 190 + f * 2, 92 + f * 2),
                                tint: SIMD4(0.5, 0.7, 0.9, 0.4),
                                shapeP: SIMD4(0, f, 0, 0), seed: 0, blend: .erase))
            ops.append(SpriteOp(target: 1, mode: 7,
                                rect: SIMD4(x, bandY - f, 190 + f * 2, 92 + f * 2),
                                tint: SIMD4(0.45, 0.8, 0.3, 0.5),
                                shapeP: SIMD4(0, f, 0, 0), seed: 0, blend: .erase))
        }
        ops.append(SpriteOp(target: 1, mode: 8,
                            rect: SIMD4(Float(W) * 0.55, bandY, 300, 92),
                            tint: SIMD4(0, 0, 0, 0.45),
                            shapeP: .zero, seed: 3.7, blend: .add))

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: false)
        outDesc.usage = [.renderTarget, .shaderRead]
        outDesc.storageMode = .shared
        guard let outTex = device.makeTexture(descriptor: outDesc),
              let cmd = queue.makeCommandBuffer() else { return 3 }

        sim.encodeSim(cmd, ops: ops, decay0: SIMD4(1, 1, 1, 1),
                      decay1: SIMD4(1, 1, 1, 1), filmGrow: 0.35)

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = outTex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        sim.encodeComposite(cmd, into: rp, uniforms: uniforms(W: W, H: H))
        cmd.commit()
        cmd.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: W * H * 4)
        outTex.getBytes(&px, bytesPerRow: W * 4,
                        from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)

        return write(px: px, W: W, H: H, to: path)
    }

    private static func uniforms(W: Int, H: Int) -> [Float] {
        var u = [Float](repeating: 0, count: 112)
        for t in DirtType.allCases {
            let b = t.rawValue * 16
            let d = t.dark, l = t.lit, r = t.rim
            u[b + 0] = d.x; u[b + 1] = d.y; u[b + 2] = d.z; u[b + 3] = 1
            u[b + 4] = l.x; u[b + 5] = l.y; u[b + 6] = l.z; u[b + 7] = 1
            u[b + 8] = r.x; u[b + 9] = r.y; u[b + 10] = r.z; u[b + 11] = 1
            u[b + 12] = t.alphaMul
        }
        let sc = DirtType.oil.streakColor
        u[96] = sc.x; u[97] = sc.y; u[98] = sc.z; u[99] = 1
        u[100] = Float(W); u[101] = Float(H)
        u[102] = Float(W) * 0.18; u[103] = Float(H) * 0.82   // 假装鼠标在左下
        u[104] = 120; u[105] = 0.62
        u[106] = 0.86; u[107] = 0.17
        u[108] = 1.2; u[109] = -1; u[110] = 3; u[111] = 0
        return u
    }

    /// 把预乘的结果叠到一张假桌面上，好判断可读性
    private static func write(px: [UInt8], W: Int, H: Int, to path: String) -> Int32 {
        var out = [UInt8](repeating: 255, count: W * H * 4)
        for y in 0..<H {
            for x in 0..<W {
                let i = (y * W + x) * 4
                // 假壁纸：斜向渐变 + 几行假代码
                let g = Float(y) / Float(H)
                var bg = SIMD3<Float>(0.16 + 0.12 * (1 - g), 0.20 + 0.14 * (1 - g), 0.25 + 0.16 * (1 - g))
                let row = y % 26
                if row < 11 && x > 60 && x < W - 60 {
                    let seg = (x / 9 + y / 26 * 7) % 11
                    if seg < 7 { bg = SIMD3(0.72, 0.76, 0.80) }
                }
                let a = Float(px[i + 3]) / 255
                let src = SIMD3<Float>(Float(px[i]) / 255, Float(px[i + 1]) / 255, Float(px[i + 2]) / 255)
                let c = src + bg * (1 - a)      // src 已经是预乘的
                out[i]     = UInt8(max(0, min(255, c.x * 255)))
                out[i + 1] = UInt8(max(0, min(255, c.y * 255)))
                out[i + 2] = UInt8(max(0, min(255, c.z * 255)))
                out[i + 3] = 255
            }
        }
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return 4 }
        var buf = out
        let provider = CGDataProvider(data: Data(bytes: &buf, count: buf.count) as CFData)!
        guard let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent) else { return 5 }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? 0 : 6
    }
}
