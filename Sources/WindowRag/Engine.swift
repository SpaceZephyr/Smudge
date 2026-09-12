import AppKit
import Metal
import MetalKit
import simd

/// 屏幕上的一枚金币。Agent 烧掉的 token 变的。
struct Coin {
    var x: Float, y: Float          // 遮罩像素坐标
    var vx: Float, vy: Float
    var born: CFTimeInterval
    var spin: Float
    var pop: Float = 0              // >0 正在被吃掉的动画
}

/// 把 Agent 状态、窗口拖动、污渍模拟和声音串起来。
/// 每帧只跑一次共享逻辑，然后各屏各自渲染。
final class WindowRagEngine {

    var params: Params { didSet { applyParams() } }
    private(set) var state: AgentState = .idle
    private(set) var calls = 0
    private(set) var wipedArea: Float = 0
    private(set) var coinsCollected = 0
    private(set) var tokensSeen = 0

    let device: MTLDevice
    let queue: MTLCommandQueue
    let sound = SoundEngine()
    let tracker = WindowTracker()
    let monitor: AgentMonitor
    let tokens = TokenWatcher()
    var overlays: [ScreenOverlay] = []
    var onStatusChange: (() -> Void)?
    var paused = false { didSet { quietSince = 0; updateFrameRate() } }

    private var filmLevel: Float = 0
    private var spawnAcc: Float = 0
    private var ridgeAmt: Float = 0
    private var flushT: Float = -1
    private var faultPulse: Float = 0
    private var lastTick = CACurrentMediaTime()
    private var lastShared: CFTimeInterval = 0
    private var idleAfter: CFTimeInterval = 0

    init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else {
            throw WindowRagError.noMetal
        }
        device = d
        queue = q
        params = Params.load()
        monitor = AgentMonitor()
        monitor.processNames = params.agentProcessNames
        monitor.onEvent = { [weak self] e in self?.handle(e) }
        tokens.onTokens = { [weak self] n in self?.addTokens(n) }
        applyParams()
    }

    private func applyParams() {
        sound.volume = params.volume
        tracker.claudeOnly = params.claudeWindowOnly
        monitor.processNames = params.agentProcessNames
    }

    // MARK: - 屏幕

    func rebuildOverlays() {
        overlays.forEach { $0.close() }
        overlays = NSScreen.screens.compactMap { s in
            try? ScreenOverlay(screen: s, device: device, engine: self)
        }
        tracker.reset()
        sleeping = false
        quietSince = 0
        updateFrameRate()
    }

    func refreshQuality() {
        overlays.forEach { $0.resizeMask() }
    }

    // MARK: - Agent 事件

    private func handle(_ e: AgentMonitor.Event) {
        switch e {
        case .agentPID(let p):
            tracker.agentPID = p
        case .prompt:
            setState(.running)
        case .tool(let name):
            setState(.running)
            calls += 1
            let type = params.mapMode ? ToolMap.dirt(for: name) : params.primaryType
            let w = ToolMap.weight(for: name)
            let n = 1 + Int.random(in: 0...1)
            for _ in 0..<n { spawnBlob(type: type, sizeMul: w.size, alphaMul: w.alpha) }
        case .transcript(let path):
            tokens.adopt(transcript: path)
        case .notify:
            setState(.waiting)
        case .quiet:
            // 只是"这会儿不忙了"，不是"干完了"：脏自己慢慢退下去，不冲洗、不响铃。
            if state == .running || state == .waiting { setState(.idle) }
        case .stop:
            guard state != .done, state != .idle else { return }
            setState(.done)
            flushT = 0
            sound.flush()
        case .failed(let msg):
            _ = msg
            setState(.failed)
            for _ in 0..<5 { spawnFault() }
            if params.mapMode {
                for _ in 0..<2 { spawnBlob(type: .coffee, sizeMul: 1.4, alphaMul: 1.1) }
            }
            sound.fault()
        }
    }

    private func setState(_ s: AgentState) {
        guard state != s else { return }
        state = s
        updateFrameRate()
        onStatusChange?()
    }

    /// 屏幕干净的时候一帧都不用画：把 MTKView 整个停掉，
    /// 改用一个 10Hz 的计时器继续盯着窗口有没有被拖。
    /// 一个常驻后台的小东西不该白烧 CPU。
    let debugLog = ProcessInfo.processInfo.environment["WINDOWRAG_DEBUG"] != nil
    private var sleeping = false
    private var quietSince: CFTimeInterval = 0
    private var idleTimer: Timer?

    private var isQuiet: Bool {
        !paused && state == .idle && filmLevel < 0.005 && flushT < 0
            && pendingCoins == 0
            && overlays.allSatisfy { $0.sim.dirtEstimate < 0.002 && $0.coins.isEmpty }
    }

    private func updateFrameRate() {
        if isQuiet {
            if quietSince == 0 { quietSince = CACurrentMediaTime() }
            // 多等一会儿，确保最后那帧空画面已经画出去了
            if !sleeping && CACurrentMediaTime() - quietSince > 0.8 { sleep() }
        } else {
            quietSince = 0
            wake()
        }
    }

    private func sleep() {
        sleeping = true
        if debugLog { NSLog("[windowrag] 休眠：屏幕干净，停渲染") }
        overlays.forEach { $0.view.isPaused = true }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.frameTick() }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    private func wake() {
        guard sleeping else { return }
        sleeping = false
        if debugLog { NSLog("[windowrag] 唤醒") }
        idleTimer?.invalidate(); idleTimer = nil
        overlays.forEach {
            $0.view.preferredFramesPerSecond = 60
            $0.view.isPaused = false
        }
    }

    func manualClean() {
        flushT = 0
        sound.flush()
        setState(.idle)
    }
    func manualReset() {
        overlays.forEach { $0.sim.resize(width: 0, height: 0); $0.resizeMask() }
        filmLevel = 0; calls = 0; wipedArea = 0; flushT = -1; ridgeAmt = 0
        overlays.forEach { $0.coins.removeAll() }
        coinsCollected = 0; tokensSeen = 0; tokenAcc = 0; pendingCoins = 0
        setState(.idle)
    }

    // MARK: - 金币

    private var tokenAcc: Float = 0
    private var pendingCoins = 0
    private var mouseMovedAt: CFTimeInterval = 0
    private var lastMouseCG = CGPoint(x: -9e5, y: -9e5)
    private var coinPitch = 0
    private var coinDrip: Float = 0
    private var lastCoinAt: CFTimeInterval = 0

    /// 烧掉的 token 攒够一枚就掉一枚金币
    private func addTokens(_ n: Int) {
        tokensSeen += n
        guard params.coinsEnabled, n > 0 else { return }
        tokenAcc += Float(n)
        let per = max(20, params.tokensPerCoin)
        var due = 0
        while tokenAcc >= per {
            tokenAcc -= per
            due += 1
        }
        // 一条消息动辄上万 token，一次性砸下来既撞上限又难看，
        // 排进队里按每秒几枚慢慢冒，像个小喷泉
        pendingCoins = min(90, pendingCoins + due)
        if debugLog && due > 0 {
            NSLog("[windowrag] +%d token，排队 %d 枚（待发 %d）", n, due, pendingCoins)
        }
    }

    private func spawnCoin() {
        guard let o = randomOverlay() else { return }
        let now = CACurrentMediaTime()
        let px = Float(o.pxPerPoint)
        o.coins.append(Coin(
            x: Float.random(in: 0.06...0.94) * Float(o.sim.maskW),
            y: Float.random(in: 0.06...0.66) * Float(o.sim.maskH),
            vx: Float.random(in: -6...6) * px,
            vy: Float.random(in: -3...6) * px,
            born: now,
            spin: Float.random(in: 0...1)))
        if o.coins.count > Int(params.coinMax) {
            o.coins.removeFirst(o.coins.count - Int(params.coinMax))
        }
    }

    /// 晃鼠标吃金币。停着不动不算 —— 这东西是给手找事干的。
    private func updateCoins(_ dt: Float) {
        let now = CACurrentMediaTime()
        let cur = WindowTracker.cursorCG
        if abs(cur.x - lastMouseCG.x) + abs(cur.y - lastMouseCG.y) > 1.5 {
            mouseMovedAt = now
            lastMouseCG = cur
        }
        let moving = now - mouseMovedAt < 0.4

        // 队列里的币按每秒 7 枚往外冒
        if pendingCoins > 0 {
            coinDrip += dt * 7
            while coinDrip >= 1 && pendingCoins > 0 {
                coinDrip -= 1
                pendingCoins -= 1
                spawnCoin()
            }
        }
        if now - lastCoinAt > 1.6 { coinPitch = 0 }     // 连吃才升调

        for o in overlays {
            guard !o.coins.isEmpty else { continue }
            let px = Float(o.pxPerPoint)
            let magnet = params.coinMagnet * px
            let onThis = o.cgFrame.insetBy(dx: -30, dy: -30).contains(cur)
            let m = onThis ? o.toMask(cur) : CGPoint(x: -9e5, y: -9e5)

            var i = 0
            while i < o.coins.count {
                var c = o.coins[i]
                if c.pop > 0 {
                    c.pop += dt * 3.4
                    if c.pop >= 1 { o.coins.remove(at: i); continue }
                    o.coins[i] = c; i += 1; continue
                }
                let age = Float(now - c.born)
                if age > params.coinLife { o.coins.remove(at: i); continue }

                c.vy = min(c.vy + 0.7 * px * dt, 17 * px)   // 很慢地往下飘，别沉出屏幕
                c.x += c.vx * dt
                c.y += c.vy * dt + sin(Float(now) * 2.2 + c.spin * 6) * 3 * px * dt
                c.spin += dt * 0.42
                if c.y > Float(o.sim.maskH) + 40 { o.coins.remove(at: i); continue }

                if moving, onThis {
                    let dx = c.x - Float(m.x), dy = c.y - Float(m.y)
                    if dx * dx + dy * dy < magnet * magnet {
                        c.pop = 0.001
                        coinsCollected += 1
                        coinPitch += 1
                        lastCoinAt = now
                        sound.coin(pitch: coinPitch)
                        onStatusChange?()
                    }
                }
                o.coins[i] = c
                i += 1
            }
        }
    }

    /// 交给渲染用的金币
    func coinSprites(_ o: ScreenOverlay) -> [CoinSprite] {
        guard params.coinsEnabled, !o.coins.isEmpty else { return [] }
        let now = CACurrentMediaTime()
        let r = 17 * Float(o.pxPerPoint)              // 半径，点 → 遮罩像素
        return o.coins.map { c in
            let age = Float(now - c.born)
            var a: Float = min(1, age / 0.22)                        // 淡入
            a *= min(1, max(0, (params.coinLife - age) / 2.2))       // 快过期时淡出
            let grow: Float = c.pop > 0 ? 1 + c.pop * 1.5 : 1
            let rr = r * grow
            return CoinSprite(
                rect: SIMD4(c.x - rr, c.y - rr, rr * 2, rr * 2),
                tint: SIMD4(1.0, 0.80, 0.26, max(0, a)),
                spin: c.spin, pop: c.pop)
        }
    }

    // 没有 agent 也能试手感
    func simulateTool(_ name: String) { handle(.tool(name)) }
    func simulateStop() { handle(.stop) }
    func simulateFail() { handle(.failed("test")) }
    func simulateCoins(_ n: Int) {
        guard params.coinsEnabled else { return }
        for _ in 0..<n { spawnCoin() }
        updateFrameRate()
    }

    var dirtPercent: Int {
        let v = overlays.first?.sim.dirtEstimate ?? 0
        return Int((min(1, v + filmLevel) * 100).rounded())
    }

    // MARK: - 每帧

    func frameTick() {
        let now = CACurrentMediaTime()
        guard now - lastShared > 0.006 else { return }   // 多屏时别跑两遍
        let dt = Float(min(0.05, max(0.001, now - lastTick)))
        lastTick = now
        lastShared = now
        faultPulse += dt

        if paused { return }

        // 薄膜：干活时蒙一层，完成才真的冲到零
        let target: Float = (state == .running || state == .waiting) ? params.filmFloor
                          : (state == .failed ? params.filmFloor * 0.8 : 0)
        filmLevel += (target - filmLevel) * min(1, dt * (state == .done ? 4 : 1.4))
        if state == .done && filmLevel < 0.004 { filmLevel = 0 }

        let frozen = (state == .waiting)

        // 挥发
        var decay0 = SIMD4<Float>(1, 1, 1, 1)
        var decay1 = SIMD4<Float>(1, 1, 1, 1)
        if !frozen && state != .failed && params.evapRate > 0 {
            func k(_ t: DirtType) -> Float { max(0, 1 - min(0.6, params.evapRate * t.evap * dt)) }
            decay0 = SIMD4(k(.oil), k(.dust), k(.fog), k(.coffee))
            decay1 = SIMD4(k(.ink), k(.rain), 1, max(0, 1 - min(0.6, params.evapRate * 0.35 * dt)))
        }
        let filmGrow: Float = frozen ? 0 : min(0.5, params.filmGrow * dt)
        overlays.forEach { ov in
            ov.sim.decayLevels(rate: params.evapRate, dt: dt, frozen: frozen, failed: state == .failed)
            ov.sim.noteFilmGrow(filmGrow)
        }

        // 干活时的底噪：没有工具调用的时候也在慢慢脏
        if state == .running && !frozen {
            spawnAcc += dt * params.spawnRate * 0.5
            while spawnAcc >= 1 {
                spawnAcc -= 1
                let cap = overlays.first?.sim.dirtEstimate ?? 0
                if cap < params.dirtCap {
                    let ambient = (params.mapMode && monitor.hookAlive) ? DirtType.fog : params.primaryType
                    spawnBlob(type: ambient, sizeMul: 0.7, alphaMul: 0.7)
                } else {
                    spawnAcc = 0
                }
            }
        }

        applyWipes(dt: dt)
        if params.coinsEnabled { updateCoins(dt) } else { overlays.forEach { $0.coins.removeAll() } }
        advanceFlush(dt: dt)
        for ov in overlays where ov.pending.count > 600 {
            ov.pending.removeFirst(ov.pending.count - 600)
        }
        updateFrameRate()

        // 参数改了要重建刮板的羽化，这里不用做别的
        _ = decay0
        pendingDecay = (decay0, decay1, filmGrow)
    }

    private var pendingDecay: (SIMD4<Float>, SIMD4<Float>, Float) = (.one, .one, 0)

    // MARK: - 擦

    private func applyWipes(dt: Float) {
        let moves = tracker.poll()
        guard !moves.isEmpty else {
            sound.quiet()
            ridgeAmt = max(0, ridgeAmt - dt * 0.6)
            return
        }

        var maxSpeed: Float = 0
        var dirtHere: Float = 0

        for m in moves {
            let distPts = Float(hypot(m.delta.dx, m.delta.dy))
            if distPts < 0.4 { continue }
            let speed = distPts / dt
            maxSpeed = max(maxSpeed, speed)
            let fast = min(1, speed / max(1, params.slowSpeed))
            let eff = params.wipeForce * (1 - fast * params.fastFloor)
            let prevRect = m.rect.offsetBy(dx: -m.delta.dx, dy: -m.delta.dy)

            for ov in overlays where ov.cgFrame.intersects(m.rect.union(prevRect)) {
                dirtHere = max(dirtHere, ov.sim.dirtEstimate)
                wipe(ov: ov, from: prevRect, to: m.rect, eff: eff, fast: fast, speed: speed)
            }
            wipedArea += distPts * Float(m.rect.width) / 1_000_000 * 3

            // 油脊：被推走的脏堆在前缘，推厚了会崩
            let lead = overlays.first?.sim.heaviest(fallback: params.primaryType) ?? params.primaryType
            ridgeAmt += distPts * dirtHere * eff * 0.02 * params.ridge
            if ridgeAmt > params.burstAt && params.ridge > 0 {
                burst(along: m, lead: lead)
                ridgeAmt = 0
                sound.burst()
            }
        }

        if maxSpeed > 0 {
            sound.friction(speed: maxSpeed, dirt: dirtHere, dry: 1 - min(1, dirtHere * 4))
        } else {
            sound.quiet()
        }
    }

    private func wipe(ov: ScreenOverlay, from prev: CGRect, to cur: CGRect,
                      eff: Float, fast: Float, speed: Float) {
        let a = ov.toMask(cur), b = ov.toMask(prev)
        let dx = Float(a.minX - b.minX), dy = Float(a.minY - b.minY)
        let distPx = sqrt(dx * dx + dy * dy)
        let steps = max(1, min(14, Int(ceil(distPx / 6))))
        let f = Float(params.feather) * Float(ov.pxPerPoint)

        // 单步强度，使 N 步累计正好等于目标强度
        func perStep(_ total: Float) -> Float {
            let t = min(0.995, max(0, total))
            return 1 - pow(1 - t, 1 / Float(steps))
        }
        let e0 = SIMD4<Float>(perStep(eff / DirtType.oil.resist),
                              perStep(eff / DirtType.dust.resist),
                              perStep(eff / DirtType.fog.resist),
                              perStep(eff / DirtType.coffee.resist))
        let e1 = SIMD4<Float>(perStep(eff / DirtType.ink.resist),
                              perStep(eff / DirtType.rain.resist),
                              perStep(eff * 0.55),
                              perStep(eff * 0.9))
        let e2 = SIMD4<Float>(perStep(min(1, eff * 1.15)), 0, 0, 0)

        var lastRect = SIMD4<Float>()
        for i in 1...steps {
            let t = Float(i) / Float(steps)
            let x = Float(b.minX) + dx * t - f
            let y = Float(b.minY) + dy * t - f
            let rect = SIMD4<Float>(x, y, Float(a.width) + f * 2, Float(a.height) + f * 2)
            lastRect = rect
            for (target, tint) in [(0, e0), (1, e1), (2, e2)] {
                ov.pending.append(SpriteOp(target: target, mode: 7, rect: rect, tint: tint,
                                           shapeP: SIMD4(0, f, 0, 0), seed: 0, blend: .erase))
            }
        }
        ov.sim.noteWipe(fraction: min(0.35, eff * 0.06 * Float(steps)))

        // 水痕：快划留得多
        if params.streak > 0 && fast > 0.12 {
            let lead = ov.sim.heaviest(fallback: params.primaryType)
            let amt = min(0.6, params.streak * lead.streakMul * fast * max(0.15, ov.sim.dirtEstimate) * 1.1)
            ov.pending.append(SpriteOp(target: 1, mode: 8, rect: lastRect,
                                       tint: SIMD4(0, 0, 0, amt),
                                       shapeP: .zero, seed: Float.random(in: 0...99), blend: .add))
        }
    }

    private func burst(along m: WindowTracker.Move, lead: DirtType) {
        let len = max(1, hypot(m.delta.dx, m.delta.dy))
        let nx = m.delta.dx / len, ny = m.delta.dy / len
        let c = CGPoint(x: m.rect.midX, y: m.rect.midY)
        for i in 0..<3 {
            let side: CGFloat = i % 2 == 0 ? -1 : 1
            let p = CGPoint(
                x: c.x + nx * m.rect.width * 0.55 + (-ny) * side * m.rect.width * CGFloat.random(in: 0.3...0.6),
                y: c.y + ny * m.rect.height * 0.55 + nx * side * m.rect.height * CGFloat.random(in: 0.3...0.6))
            spawnBlob(type: lead, sizeMul: Float.random(in: 0.4...0.8), alphaMul: 1.4, at: p)
        }
    }

    // MARK: - 生成

    private func randomOverlay() -> ScreenOverlay? {
        guard !overlays.isEmpty else { return nil }
        let areas = overlays.map { Float($0.screen.frame.width * $0.screen.frame.height) }
        let total = areas.reduce(0, +)
        var r = Float.random(in: 0..<max(total, 1))
        for (i, a) in areas.enumerated() {
            if r < a { return overlays[i] }
            r -= a
        }
        return overlays.last
    }

    /// at 给 CG 全局坐标；不给就在屏幕上随便找一处
    private func spawnBlob(type: DirtType, sizeMul: Float, alphaMul: Float, at global: CGPoint? = nil) {
        var ov: ScreenOverlay?
        var maskPoint = CGPoint.zero
        if let g = global {
            ov = overlays.first { $0.cgFrame.contains(g) } ?? overlays.first
            if let o = ov { maskPoint = o.toMask(g) }
        } else {
            ov = randomOverlay()
            if let o = ov { maskPoint = pickSpot(in: o) }
        }
        guard let o = ov else { return }

        let px = Float(o.pxPerPoint)
        let r = params.blobSize * type.sizeMul * sizeMul * Float.random(in: 0.75...1.3) * px
        let alpha = min(1, params.blobDark * type.alphaMul * alphaMul * Float.random(in: 0.8...1.2))
        var tint = SIMD4<Float>()
        tint[type.channel] = alpha

        o.pending.append(SpriteOp(
            target: type.texIndex, mode: type.shape,
            rect: SIMD4(Float(maskPoint.x) - r, Float(maskPoint.y) - r, r * 2, r * 2),
            tint: tint, shapeP: SIMD4(params.spatter, 0, 0, 0),
            seed: Float.random(in: 0...999), blend: .add))
        o.sim.noteSpawn(type, amount: alpha * 0.3)
        sound.plop(size: r / px, type: type)
    }

    private func spawnFault() {
        guard let o = randomOverlay() else { return }
        let px = Float(o.pxPerPoint)
        let p = pickSpot(in: o)
        let r = params.blobSize * 1.5 * Float.random(in: 0.75...1.3) * px
        o.pending.append(SpriteOp(
            target: 1, mode: params.primaryType.shape,
            rect: SIMD4(Float(p.x) - r, Float(p.y) - r, r * 2, r * 2),
            tint: SIMD4(0, 0, min(1, params.blobDark * 1.2), 0),
            shapeP: SIMD4(params.spatter, 0, 0, 0),
            seed: Float.random(in: 0...999), blend: .add))
    }

    /// 尽量别糊在你正在看的那个窗口上
    private func pickSpot(in o: ScreenOverlay) -> CGPoint {
        let front = tracker.frontRect.map { o.toMask($0) }
        for _ in 0..<10 {
            let p = CGPoint(x: CGFloat.random(in: 0...CGFloat(o.sim.maskW)),
                            y: CGFloat.random(in: 0...CGFloat(o.sim.maskH)))
            if let f = front, f.insetBy(dx: -6, dy: -6).contains(p) { continue }
            return p
        }
        return CGPoint(x: CGFloat.random(in: 0...CGFloat(o.sim.maskW)),
                       y: CGFloat.random(in: 0...CGFloat(o.sim.maskH)))
    }

    // MARK: - 冲洗

    private func advanceFlush(dt: Float) {
        guard flushT >= 0 else { return }
        flushT += dt
        let dur: Float = 0.85
        let p = min(1, flushT / dur)
        for ov in overlays {
            let h = Float(ov.sim.maskH)
            let y = p * h
            let f = max(4, h * 0.13)
            let rect = SIMD4<Float>(-f, -f, Float(ov.sim.maskW) + f * 2, y + f)
            for target in 0..<3 {
                ov.pending.append(SpriteOp(target: target, mode: 7, rect: rect,
                                           tint: SIMD4(1, 1, 1, 1),
                                           shapeP: SIMD4(0, f, 0, 0), seed: 0, blend: .erase))
            }
        }
        if p >= 1 {
            flushT = -1
            overlays.forEach { $0.sim.clearLevels() }
            idleAfter = CACurrentMediaTime() + 0.6
        }
        if idleAfter > 0 && CACurrentMediaTime() > idleAfter {
            idleAfter = 0
            if state == .done { setState(.idle) }
        }
    }

    private func flushYFor(_ ov: ScreenOverlay) -> Float {
        guard flushT >= 0 else { return -1 }
        return min(1, flushT / 0.85) * Float(ov.sim.maskH)
    }

    // MARK: - 渲染

    func render(overlay ov: ScreenOverlay) {
        guard let rp = ov.view.currentRenderPassDescriptor,
              let drawable = ov.view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }

        let (d0, d1, fg) = pendingDecay
        ov.sim.encodeSim(cmd, ops: ov.pending, decay0: d0, decay1: d1, filmGrow: fg)
        ov.pending.removeAll(keepingCapacity: true)   // 画完才清，见 frameTick
        ov.sim.encodeComposite(cmd, into: rp, uniforms: compositeUniforms(ov),
                               coins: coinSprites(ov))
        cmd.present(drawable)
        cmd.commit()
    }

    private func compositeUniforms(_ ov: ScreenOverlay) -> [Float] {
        var u = [Float](repeating: 0, count: 112)
        for t in DirtType.allCases {
            let b = t.rawValue * 16
            let d = t.dark, l = t.lit, r = t.rim
            u[b + 0] = d.x; u[b + 1] = d.y; u[b + 2] = d.z; u[b + 3] = 1
            u[b + 4] = l.x; u[b + 5] = l.y; u[b + 6] = l.z; u[b + 7] = 1
            u[b + 8] = r.x; u[b + 9] = r.y; u[b + 10] = r.z; u[b + 11] = 1
            u[b + 12] = t.alphaMul
        }
        let lead = ov.sim.heaviest(fallback: params.primaryType)
        let sc = lead.streakColor
        u[96] = sc.x; u[97] = sc.y; u[98] = sc.z; u[99] = 1
        u[100] = Float(ov.sim.maskW); u[101] = Float(ov.sim.maskH)

        let cur = WindowTracker.cursorCG
        if ov.cgFrame.insetBy(dx: -40, dy: -40).contains(cur) {
            let m = ov.toMask(cur)
            u[102] = Float(m.x); u[103] = Float(m.y)
        } else {
            u[102] = -1e6; u[103] = -1e6
        }
        u[104] = params.haloR * Float(ov.pxPerPoint)
        u[105] = params.haloS
        u[106] = params.oilAlpha
        u[107] = filmLevel
        u[108] = faultPulse
        u[109] = flushYFor(ov)
        u[110] = Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 1000))
        u[111] = Float(params.primaryType.rawValue)
        return u
    }
}
