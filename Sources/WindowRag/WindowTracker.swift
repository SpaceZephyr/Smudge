import AppKit
import CoreGraphics
import Darwin

/// 靠轮询窗口位置来判断"有人在拖窗口"。
/// 不用辅助功能权限，也不用录屏权限 —— CGWindowList 的 bounds 一直是公开的。
final class WindowTracker {

    struct Move {
        var id: CGWindowID
        var rect: CGRect      // CG 全局坐标，左上角原点
        var delta: CGVector
        var ownerPID: pid_t
    }

    /// 只认 Claude Code 那个窗口，还是任何窗口都能当刮板
    var claudeOnly = false
    /// hook 报上来的 claude 进程号，用来往上找它所在的终端窗口
    var agentPID: pid_t = 0

    /// 最前面那个普通窗口，用来避开你正在看的地方
    private(set) var frontRect: CGRect?

    private var lastRects: [CGWindowID: CGRect] = [:]
    private var ownerCache: [CGWindowID: pid_t] = [:]
    private var allowedPIDs: Set<pid_t> = []
    private var allowedStamp: CFTimeInterval = 0
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }
    /// 某块屏幕在 CG 全局坐标里的矩形
    static func cgFrame(of screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.minX,
               y: primaryHeight - screen.frame.maxY,
               width: screen.frame.width,
               height: screen.frame.height)
    }
    static var cursorCG: CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// 每帧调一次，返回这一帧动过的窗口
    func poll() -> [Move] {
        guard let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }

        if claudeOnly { refreshAllowedPIDs() }

        var moves: [Move] = []
        var seen: [CGWindowID: CGRect] = [:]
        seen.reserveCapacity(list.count)
        var front: CGRect?

        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let num = info[kCGWindowNumber as String] as? Int,
                  let pidNum = info[kCGWindowOwnerPID as String] as? Int,
                  let b = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary)
            else { continue }

            let pid = pid_t(pidNum)
            if pid == selfPID { continue }
            if rect.width < 60 || rect.height < 40 { continue }

            let id = CGWindowID(num)
            seen[id] = rect
            ownerCache[id] = pid
            if front == nil { front = rect }   // 列表是从前往后排的

            guard let prev = lastRects[id] else { continue }
            let dx = rect.minX - prev.minX, dy = rect.minY - prev.minY
            if dx == 0 && dy == 0 { continue }
            // 尺寸变了是在缩放窗口，不算擦
            if abs(rect.width - prev.width) > 0.5 || abs(rect.height - prev.height) > 0.5 { continue }
            if claudeOnly && !allowedPIDs.contains(pid) { continue }

            moves.append(Move(id: id, rect: rect, delta: CGVector(dx: dx, dy: dy), ownerPID: pid))
        }

        lastRects = seen
        frontRect = front
        return moves
    }

    func reset() {
        lastRects.removeAll()
    }

    // MARK: - 从 claude 进程往上找拥有窗口的祖先

    private func refreshAllowedPIDs() {
        let now = CACurrentMediaTime()
        guard now - allowedStamp > 2 else { return }
        allowedStamp = now
        var set = Set<pid_t>()
        var p = agentPID
        var hops = 0
        while p > 1 && hops < 8 {
            set.insert(p)
            p = ProcessScan.parent(of: p)
            hops += 1
        }
        allowedPIDs = set
    }
}

/// libproc 的一点包装：列进程、取名字、取父进程、取 CPU 时间
enum ProcessScan {

    private static let PROC_PIDTBSDINFO: Int32 = 3

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&buf, Int32(MemoryLayout<pid_t>.size * buf.count))
        guard n > 0 else { return [] }
        return Array(buf.prefix(Int(n))).filter { $0 > 0 }
    }

    static func name(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return "" }
        return String(cString: buf)
    }

    static func parent(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let r = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, size)
        }
        return r == size ? pid_t(info.pbi_ppid) : 0
    }

    /// 按名字找进程。CPU 兜底和 claudeOnly 都用它。
    static func pids(named names: [String]) -> [pid_t] {
        let want = Set(names.map { $0.lowercased() })
        return allPIDs().filter { want.contains(name(of: $0).lowercased()) }
    }
}
