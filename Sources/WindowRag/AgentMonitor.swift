import Foundation
import Network

/// Agent 在干嘛。两条路：
/// 1) Claude Code hooks POST 到本地端口 —— 准，还能拿到工具名
/// 2) 找不到 hook 事件时退回看进程 CPU —— 糙，但对任何 agent 都管用
final class AgentMonitor {

    enum Event {
        case tool(String)
        case prompt
        case stop
        case notify
        case failed(String)
        case agentPID(pid_t)
        /// CPU 兜底判断的"这会儿不忙了"。注意它和 .stop 不是一回事：
        /// .stop 是 hook 说的"任务真的结束了"，才配得上一次冲洗。
        case quiet
        /// hook 输入里带的会话记录路径，token 金币要靠它
        case transcript(String)
    }

    var onEvent: ((Event) -> Void)?
    let port: UInt16
    private(set) var lastHook: Date?
    private(set) var hookAlive = false

    private var listener: NWListener?
    private let q = DispatchQueue(label: "com.windowrag.hook")
    private var cpuTimer: Timer?
    private var busyStreak = 0
    private var idleStreak = 0
    private var cpuRunning = false
    var processNames: [String] = ["claude"]

    init(port: UInt16 = 8787) {
        self.port = port
    }

    // MARK: - hook 服务

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"),
                                                 port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: q)
        listener = l
        startCPUFallback()
    }

    func stop() {
        listener?.cancel(); listener = nil
        cpuTimer?.invalidate(); cpuTimer = nil
    }

    private func handle(_ conn: NWConnection) {
        // 只收本机来的
        if case let .hostPort(host, _) = conn.endpoint {
            let s = "\(host)"
            if !(s.contains("127.0.0.1") || s.contains("::1") || s.contains("localhost")) {
                conn.cancel(); return
            }
        }
        conn.start(queue: q)
        var buf = Data()
        func step() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, done, err in
                guard let self else { conn.cancel(); return }
                if let d = data, !d.isEmpty { buf.append(d) }
                if let (path, body) = AgentMonitor.parse(buf) {
                    self.dispatch(path: path, body: body)
                    let resp = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    conn.send(content: resp.data(using: .utf8),
                              completion: .contentProcessed { _ in conn.cancel() })
                    return
                }
                if done || err != nil || buf.count > 1 << 20 { conn.cancel(); return }
                step()
            }
        }
        step()
    }

    /// 攒够一个完整请求才返回 (路径, body)
    private static func parse(_ buf: Data) -> (String, Data)? {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = buf.range(of: sep) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let request = lines.first else { return nil }
        lines.removeFirst()
        let parts = request.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var path = String(parts[1])
        if let qm = path.firstIndex(of: "?") { path = String(path[path.startIndex..<qm]) }

        var length = 0
        for line in lines where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let body = buf[r.upperBound...]
        if body.count < length { return nil }
        return (path, Data(body.prefix(length == 0 ? body.count : length)))
    }

    private func dispatch(path: String, body: Data) {
        lastHook = Date()
        hookAlive = true
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

        // claude 的 hook 输入里带着它自己的进程信息和会话记录路径，顺手记下来
        if let p = json["pid"] as? Int { emit(.agentPID(pid_t(p))) }
        if let t = json["transcript_path"] as? String, !t.isEmpty { emit(.transcript(t)) }

        switch path {
        case "/tool":
            let name = (json["tool_name"] as? String)
                ?? (json["name"] as? String)
                ?? (json["tool"] as? String) ?? "Bash"
            emit(.tool(name))
        case "/prompt":
            emit(.prompt)
        case "/stop":
            emit(.stop)
        case "/notify":
            emit(.notify)
        case "/error", "/fail":
            emit(.failed((json["message"] as? String) ?? "failed"))
        default:
            break
        }
    }

    private func emit(_ e: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }

    // MARK: - CPU 兜底

    private func startCPUFallback() {
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.scanCPU() }
        RunLoop.main.add(t, forMode: .common)
        cpuTimer = t
    }

    /// 最近 90 秒有 hook 事件就不管 CPU 了，hook 说了算
    private var hookIsAuthoritative: Bool {
        guard let l = lastHook else { return false }
        return Date().timeIntervalSince(l) < 90
    }

    /// agent 的 CPU 在一次会话里本来就是忽高忽低的（等模型返回的时候接近零），
    /// 所以两头都要迟滞：连着忙几秒才算开工，连着闲快半分钟才算收工。
    /// 而且收工只发 .quiet，不发 .stop —— CPU 看不出"任务完成"，
    /// 没资格触发那一下冲洗。
    private func scanCPU() {
        if hookIsAuthoritative { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let busy = self.agentCPU() > 12
            DispatchQueue.main.async {
                if busy { self.busyStreak += 1; self.idleStreak = 0 }
                else { self.idleStreak += 1; self.busyStreak = 0 }

                if !self.cpuRunning && self.busyStreak >= 2 {          // 约 3 秒
                    self.cpuRunning = true
                    self.onEvent?(.prompt)
                } else if self.cpuRunning && self.idleStreak >= 16 {   // 约 24 秒
                    self.cpuRunning = false
                    self.onEvent?(.quiet)
                }
            }
        }
    }

    /// 用 ps 拿一次总 CPU%。1.5 秒一次，开销可以忽略。
    private func agentCPU() -> Double {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "pid=,pcpu=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let want = Set(processNames.map { $0.lowercased() })
        var total = 0.0
        var found: pid_t = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = Int32(f[0]), let cpu = Double(f[1]) else { continue }
            let comm = String(f[2...].joined(separator: " "))
            let base = (comm as NSString).lastPathComponent.lowercased()
            if want.contains(base) {
                total += cpu
                if found == 0 { found = pid }
            }
        }
        if found != 0 { emit(.agentPID(found)) }
        return total
    }

    // MARK: - hook 配置

    /// 贴进 ~/.claude/settings.json 的那一段
    func hookConfigJSON() -> String {
        func cmd(_ route: String, passStdin: Bool) -> String {
            let url = "http://127.0.0.1:\(port)\(route)"
            return passStdin
                ? "curl -s -m 1 -X POST --data-binary @- \(url) >/dev/null 2>&1 || true"
                : "curl -s -m 1 -X POST -d '{}' \(url) >/dev/null 2>&1 || true"
        }
        func block(_ route: String, _ stdin: Bool) -> String {
            """
                  {
                    "matcher": "*",
                    "hooks": [{ "type": "command", "command": "\(cmd(route, passStdin: stdin))" }]
                  }
            """
        }
        return """
        {
          "hooks": {
            "UserPromptSubmit": [
        \(block("/prompt", false))
            ],
            "PreToolUse": [
        \(block("/tool", true))
            ],
            "Notification": [
        \(block("/notify", true))
            ],
            "Stop": [
        \(block("/stop", false))
            ]
          }
        }
        """
    }
}
