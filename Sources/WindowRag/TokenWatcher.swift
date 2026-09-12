import Foundation

/// 盯着 Claude Code 的会话记录，把烧掉的 token 变成金币。
///
/// hook 的输入里带着 transcript_path，拿到就直接盯那个文件；
/// 没配 hook 就退回去找 ~/.claude/projects 下最近改动的那份 jsonl。
/// 只读新追加的部分，不整file重读。
final class TokenWatcher {

    /// 这一批新烧掉的 token
    var onTokens: ((Int) -> Void)?

    private var path: URL?
    private var offset: UInt64 = 0
    private var timer: Timer?
    private var carry = Data()
    private let q = DispatchQueue(label: "com.windowrag.tokens")

    /// 一枚金币值多少 token
    var tokensPerCoin = 250

    func start() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// hook 报上来的 transcript 路径，最准
    func adopt(transcript: String) {
        let u = URL(fileURLWithPath: transcript)
        guard u != path, FileManager.default.fileExists(atPath: u.path) else { return }
        switchTo(u)
    }

    private func switchTo(_ u: URL) {
        path = u
        carry.removeAll()
        // 从当前末尾开始，别把历史 token 一次性全变成金币砸下来
        offset = TokenWatcher.fileSize(u)
    }

    /// 没有 hook 的时候自己找：projects 下最近 2 分钟内动过的那份
    private func discover() -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return nil }
        var best: (URL, Date)?
        for case let f as URL in e where f.pathExtension == "jsonl" {
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if best == nil || m > best!.1 { best = (f, m) }
        }
        guard let (u, m) = best, Date().timeIntervalSince(m) < 120 else { return nil }
        return u
    }

    private func poll() {
        q.async { [weak self] in
            guard let self else { return }
            if self.path == nil, let found = self.discover() {
                DispatchQueue.main.async { self.switchTo(found) }
                return
            }
            guard let u = self.path else { return }

            guard let h = try? FileHandle(forReadingFrom: u) else { return }
            defer { try? h.close() }
            let size = TokenWatcher.fileSize(u)
            if size < self.offset {          // 文件被换掉了，从头来
                self.offset = 0
                self.carry.removeAll()
            }
            guard size > self.offset else { return }
            try? h.seek(toOffset: self.offset)
            guard let chunk = try? h.readToEnd(), !chunk.isEmpty else { return }
            self.offset = size

            var buf = self.carry + chunk
            var tokens = 0
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf[buf.startIndex..<nl]
                buf = buf[buf.index(after: nl)...]
                tokens += TokenWatcher.burn(in: line)
            }
            // 最后一段可能是半行，留到下次
            self.carry = buf.count < 1 << 20 ? Data(buf) : Data()

            if tokens > 0 {
                DispatchQueue.main.async { self.onTokens?(tokens) }
            }
        }
    }

    static func fileSize(_ u: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// 一条记录烧了多少。只算真花钱的那部分：
    /// 输出 + 新建缓存。命中缓存（cache_read）便宜得多，不计。
    static func burn<D: DataProtocol>(in line: D) -> Int {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return 0 }
        let out = usage["output_tokens"] as? Int ?? 0
        let cache = usage["cache_creation_input_tokens"] as? Int ?? 0
        let input = usage["input_tokens"] as? Int ?? 0
        return out + cache + input
    }
}
