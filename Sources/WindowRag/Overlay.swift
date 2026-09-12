import AppKit
import MetalKit

/// 盖住一块屏幕的透明窗口。点击穿透、跟着所有 Space 走、不进 Mission Control。
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless,
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true          // 污渍不拦鼠标，这条不能破
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 一块屏幕 = 一个窗口 + 一份遮罩 + 一份待办的绘制指令
final class ScreenOverlay: NSObject, MTKViewDelegate {

    let window: OverlayWindow
    let view: MTKView
    let sim: DirtSim
    private(set) var screen: NSScreen
    weak var engine: WindowRagEngine?

    /// 这一帧要落下 / 擦掉的东西
    var pending: [SpriteOp] = []

    init(screen: NSScreen, device: MTLDevice, engine: WindowRagEngine) throws {
        self.screen = screen
        self.engine = engine
        self.window = OverlayWindow(screen: screen)
        self.view = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        self.sim = try DirtSim(device: device, drawableFormat: .bgra8Unorm)
        super.init()

        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true
        view.wantsLayer = true
        view.layer?.isOpaque = false
        if let ml = view.layer as? CAMetalLayer { ml.isOpaque = false }
        view.delegate = self

        window.contentView = view
        window.orderFrontRegardless()
        resizeMask()
    }

    /// 这块屏幕在 CG 全局坐标里的位置
    var cgFrame: CGRect { WindowTracker.cgFrame(of: screen) }

    /// 遮罩每点多少像素
    var pxPerPoint: CGFloat {
        screen.frame.width > 0 ? CGFloat(sim.maskW) / screen.frame.width : 1
    }

    /// CG 全局点 → 遮罩像素
    func toMask(_ p: CGPoint) -> CGPoint {
        let f = cgFrame
        return CGPoint(x: (p.x - f.minX) * pxPerPoint, y: (p.y - f.minY) * pxPerPoint)
    }
    func toMask(_ r: CGRect) -> CGRect {
        let o = toMask(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * pxPerPoint, height: r.height * pxPerPoint)
    }

    func updateScreen(_ s: NSScreen) {
        screen = s
        window.setFrame(s.frame, display: false)
        resizeMask()
    }

    func resizeMask() {
        let q = CGFloat(engine?.params.quality ?? 0.46)
        let scale = window.backingScaleFactor
        let w = Int(screen.frame.width * scale * q)
        let h = Int(screen.frame.height * scale * q)
        sim.resize(width: max(64, w), height: max(64, h))
    }

    func close() {
        view.delegate = nil
        view.isPaused = true
        window.orderOut(nil)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let engine else { return }
        engine.frameTick()                       // 共享逻辑，一帧只跑一次
        engine.render(overlay: self)
    }
}
