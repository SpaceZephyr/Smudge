import AVFoundation
import Foundation

/// 全部实时合成，不带音频文件。
/// 摩擦声是一条持续的带通白噪声，频率和音量跟着刮的速度走；
/// 干的地方会additionally 冒出高频的吱声，就是刮板刮干玻璃那个动静。
///
/// 音频线程上不做任何加锁的逐采样操作：新的一次性声音先进 inbox，
/// 每个回调开头一次锁把它们收走，之后整块都是无锁的。没声音的时候引擎会自己停。
final class SoundEngine {

    private let engine = AVAudioEngine()
    private var src: AVAudioSourceNode?
    private var sr: Float = 48000
    private var started = false
    private var idleTimer: Timer?

    var enabled = true {
        didSet { if !enabled { fricTarget = 0; squeakTarget = 0 } }
    }
    var volume: Float = 0.55

    // 摩擦声（主线程写、音频线程读，单个 Float 读写是安全的）
    private var fricTarget: Float = 0
    private var fricLevel: Float = 0
    private var fricFreq: Float = 900
    private var fricFreqCur: Float = 900
    private var squeakTarget: Float = 0
    private var squeakLevel: Float = 0

    private var f1low: Float = 0, f1band: Float = 0
    private var f2low: Float = 0, f2band: Float = 0

    private struct Voice {
        var kind: Int      // 0 噪声扫频 1 正弦 2 短促咔哒
        var t: Float = 0
        var dur: Float
        var f0: Float
        var f1: Float
        var amp: Float
        var low: Float = 0
        var band: Float = 0
        var phase: Float = 0
    }
    private var inbox: [Voice] = []          // 上锁
    private var active: [Voice] = []         // 只有音频线程碰
    private let lock = NSLock()
    private var lastAudible = CACurrentMediaTime()

    // 音频线程自己的随机数，别用 Float.random
    private var rng: UInt32 = 0x9E37_79B9
    @inline(__always) private func white() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(Int32(bitPattern: rng)) * (1.0 / 2_147_483_648.0)
    }

    // MARK: - 生命周期

    private func ensureStarted() {
        lastAudible = CACurrentMediaTime()
        if started {
            if !engine.isRunning { try? engine.start() }
            return
        }
        started = true
        let out = engine.outputNode.outputFormat(forBus: 0)
        sr = Float(out.sampleRate > 0 ? out.sampleRate : 48000)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(sr), channels: 2) else { return }
        let node = AVAudioSourceNode(format: fmt) { [weak self] _, _, frameCount, ablPtr in
            guard let self else { return noErr }
            self.render(UnsafeMutableAudioBufferListPointer(ablPtr), Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        src = node
        do { try engine.start() } catch { started = false; return }
        startIdleWatch()
    }

    /// 安静几秒就把设备放开，别让一个常驻小工具一直占着音频硬件
    private func startIdleWatch() {
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.started, self.engine.isRunning else { return }
            let quiet = self.fricLevel < 0.0005 && self.fricTarget < 0.0005 && self.activeCount == 0
            if quiet && CACurrentMediaTime() - self.lastAudible > 4 {
                self.engine.pause()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }
    private var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return active.count + inbox.count
    }

    func shutdown() {
        idleTimer?.invalidate(); idleTimer = nil
        guard started else { return }
        engine.stop()
        started = false
    }

    // MARK: - 外面调的

    /// speed: px/s   dirt: 0..1 这块有多脏   dry: 0..1 有多干（越干越吱）
    func friction(speed: Float, dirt: Float, dry: Float) {
        guard enabled else { return }
        ensureStarted()
        let sp = min(1, speed / 2000)
        fricTarget = sp * (0.05 + dirt * 0.5) * 0.9
        fricFreq = 600 + sp * 2200 + dry * 900
        squeakTarget = max(0, 1 - dirt * 3) * sp * 0.11
    }
    func quiet() {
        fricTarget = 0
        squeakTarget = 0
    }

    func plop(size: Float, type: DirtType) {
        guard enabled else { return }
        switch type {
        case .oil:    push(0, dur: 0.06, f0: max(300, 900 - size * 3), f1: 260, amp: 0.07)
        case .dust:   push(0, dur: 0.09, f0: 2600, f1: 5200, amp: 0.035)
        case .fog:    push(0, dur: 0.30, f0: 300,  f1: 900,  amp: 0.030)
        case .coffee: push(0, dur: 0.11, f0: 600,  f1: 180,  amp: 0.075)
        case .ink:    push(2, dur: 0.05, f0: 1400, f1: 500,  amp: 0.080)
        case .rain:
            push(2, dur: 0.04, f0: 2600, f1: 1200, amp: 0.06)
            push(1, dur: 0.07, f0: Float.random(in: 700...1500), f1: 0, amp: 0.05)
        }
    }
    /// 油脊推厚了崩开
    func burst() {
        guard enabled else { return }
        push(0, dur: 0.22, f0: 1800, f1: 180, amp: 0.30)
        push(1, dur: 0.24, f0: 84, f1: 0, amp: 0.28)
    }
    /// 任务完成，一道水冲下来然后叮一声
    func flush() {
        guard enabled else { return }
        push(0, dur: 0.62, f0: 280, f1: 7000, amp: 0.24)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
            guard let self, self.enabled else { return }
            self.push(1, dur: 0.50, f0: 1318, f1: 0, amp: 0.13)
            self.push(1, dur: 0.45, f0: 1976, f1: 0, amp: 0.09)
        }
    }
    /// 吃到一枚金币：两个音一前一后，越连越高
    func coin(pitch: Int) {
        guard enabled else { return }
        let base: Float = 988 * powf(1.0595, Float(min(pitch, 12)))
        push(1, dur: 0.07, f0: base, f1: 0, amp: 0.07)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in
            guard let self, self.enabled else { return }
            self.push(1, dur: 0.17, f0: base * 1.5, f1: 0, amp: 0.075)
        }
    }

    func fault() {
        guard enabled else { return }
        push(1, dur: 0.30, f0: 150, f1: 0, amp: 0.16)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.enabled else { return }
            self.push(1, dur: 0.42, f0: 112, f1: 0, amp: 0.14)
        }
    }

    private func push(_ kind: Int, dur: Float, f0: Float, f1: Float, amp: Float) {
        ensureStarted()
        lock.lock()
        if inbox.count + active.count < 24 {
            inbox.append(Voice(kind: kind, dur: dur, f0: f0, f1: f1, amp: amp))
        }
        lock.unlock()
    }

    // MARK: - 合成

    @inline(__always)
    private func svf(_ input: Float, _ freq: Float, _ q: Float,
                     _ low: inout Float, _ band: inout Float) -> Float {
        let f = 2 * sin(Float.pi * min(freq, sr * 0.45) / sr)
        low += f * band
        let high = input - low - q * band
        band += f * high
        return band
    }

    private func render(_ abl: UnsafeMutableAudioBufferListPointer, _ frames: Int) {
        // 整个回调只锁这一次
        lock.lock()
        if !inbox.isEmpty { active.append(contentsOf: inbox); inbox.removeAll(keepingCapacity: true) }
        lock.unlock()

        let vol = volume
        let dt = 1 / sr
        var audible = false

        for frame in 0..<frames {
            var out: Float = 0
            let n = white()

            fricLevel += (fricTarget - fricLevel) * 0.004
            squeakLevel += (squeakTarget - squeakLevel) * 0.004
            fricFreqCur += (fricFreq - fricFreqCur) * 0.002
            if fricLevel > 0.0002 {
                out += svf(n, fricFreqCur, 0.9, &f1low, &f1band) * fricLevel
            }
            if squeakLevel > 0.0002 {
                out += svf(n, 3400, 0.11, &f2low, &f2band) * squeakLevel
            }

            var i = 0
            while i < active.count {
                var v = active[i]
                let p = v.t / v.dur
                if p >= 1 { active.remove(at: i); continue }
                let env = (1 - p) * (1 - p) * (1 - p * 0.4)
                switch v.kind {
                case 0:
                    let f = v.f0 * powf(max(v.f1, 1) / max(v.f0, 1), p)
                    out += svf(white(), f, 1.4, &v.low, &v.band) * env * v.amp
                case 1:
                    v.phase += 2 * Float.pi * v.f0 * dt
                    if v.phase > 2 * Float.pi { v.phase -= 2 * Float.pi }
                    out += sin(v.phase) * env * env * v.amp
                default:
                    let f = v.f0 + (v.f1 - v.f0) * p
                    out += svf(white(), f, 0.25, &v.low, &v.band) * env * env * v.amp
                }
                v.t += dt
                active[i] = v
                i += 1
            }

            let s = max(-1, min(1, out * vol))
            if s != 0 { audible = true }
            for buf in abl {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                p[frame] = s
            }
        }
        if audible { lastAudible = CACurrentMediaTime() }   // 每个回调记一次就够
    }
}
