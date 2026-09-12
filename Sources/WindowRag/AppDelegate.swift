import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var engine: WindowRagEngine!
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var refresh: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        do {
            engine = try WindowRagEngine()
        } catch {
            let a = NSAlert()
            a.messageText = "WindowRag 起不来"
            a.informativeText = error.localizedDescription
            a.runModal()
            NSApp.terminate(nil)
            return
        }

        engine.rebuildOverlays()
        engine.onStatusChange = { [weak self] in self?.updateStatus() }

        do { try engine.monitor.start() }
        catch {
            NSLog("hook 端口起不来（换个端口或看看谁占了 \(engine.monitor.port)）：\(error)")
        }

        buildMenu()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.engine.rebuildOverlays()
            }

        refresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
        updateStatus()
    }

    func applicationWillTerminate(_ note: Notification) {
        engine?.monitor.stop()
        engine?.sound.shutdown()
    }

    // MARK: - 菜单

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()

        statusLine = NSMenuItem(title: "待机", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        add(menu, "暂停", #selector(togglePause), tag: 1)
        add(menu, "立即擦干净", #selector(cleanNow))
        add(menu, "全部清空", #selector(resetAll))
        menu.addItem(.separator())

        add(menu, "喷一把脏（试手感）", #selector(testSpray))
        add(menu, "模拟任务完成", #selector(testDone))
        add(menu, "模拟任务失败", #selector(testFail))
        menu.addItem(.separator())

        add(menu, "只有 Claude Code 窗口能擦", #selector(toggleClaudeOnly), tag: 2)
        add(menu, "按工具映射污渍", #selector(toggleMapMode), tag: 3)
        add(menu, "声音", #selector(toggleSound), tag: 4)
        menu.addItem(.separator())

        add(menu, "载入参数 JSON…", #selector(loadParams))
        add(menu, "复制 hook 配置", #selector(copyHook))
        add(menu, "打开参数文件夹", #selector(openParamsFolder))
        menu.addItem(.separator())
        add(menu, "退出 WindowRag", #selector(quit))

        statusItem.menu = menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, tag: Int = 0) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.tag = tag
        menu.addItem(item)
    }

    private func updateStatus() {
        guard let engine else { return }
        let symbol: String
        switch engine.state {
        case .idle:    symbol = "drop"
        case .running: symbol = "drop.fill"
        case .waiting: symbol = "pause.circle"
        case .done:    symbol = "checkmark.circle"
        case .failed:  symbol = "exclamationmark.triangle.fill"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "WindowRag")
        statusItem.button?.image?.isTemplate = true

        let hook = engine.monitor.hookAlive ? "hook" : "CPU"
        statusLine.title = String(format: "%@ · 脏污 %d%% · 已擦 %.2f m² · %@",
                                  engine.state.label, engine.dirtPercent, engine.wipedArea, hook)

        if let m = statusItem.menu {
            m.item(withTag: 1)?.title = engine.paused ? "继续" : "暂停"
            m.item(withTag: 2)?.state = engine.params.claudeWindowOnly ? .on : .off
            m.item(withTag: 3)?.state = engine.params.mapMode ? .on : .off
            m.item(withTag: 4)?.state = engine.sound.enabled ? .on : .off
        }
    }

    // MARK: - 动作

    @objc private func togglePause() { engine.paused.toggle(); updateStatus() }
    @objc private func cleanNow()    { engine.manualClean() }
    @objc private func resetAll()    { engine.manualReset() }
    @objc private func quit()        { NSApp.terminate(nil) }

    @objc private func testSpray() {
        let tools = ["Read", "Bash", "Write", "Grep", "Task"]
        for t in tools { engine.simulateTool(t) }
    }
    @objc private func testDone() { engine.simulateStop() }
    @objc private func testFail() { engine.simulateFail() }

    @objc private func toggleClaudeOnly() {
        engine.params.claudeWindowOnly.toggle()
        try? engine.params.save()
        updateStatus()
    }
    @objc private func toggleMapMode() {
        engine.params.mapMode.toggle()
        try? engine.params.save()
        updateStatus()
    }
    @objc private func toggleSound() {
        engine.sound.enabled.toggle()
        updateStatus()
    }

    @objc private func loadParams() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.message = "选刮板实验场导出的那个 JSON"
        guard p.runModal() == .OK, let url = p.url,
              let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode(Params.self, from: data) else { return }
        var next = loaded
        next.claudeWindowOnly = engine.params.claudeWindowOnly
        next.agentProcessNames = engine.params.agentProcessNames
        engine.params = next
        try? next.save()
        engine.refreshQuality()
        updateStatus()
    }

    @objc private func copyHook() {
        let text = engine.monitor.hookConfigJSON()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let a = NSAlert()
        a.messageText = "hook 配置已复制"
        a.informativeText = """
        把它合并进 ~/.claude/settings.json 的 hooks 里。
        合并之后 Claude Code 每次调用工具都会告诉 WindowRag，
        污渍才分得清是在读文件还是在跑命令。

        没配也能用 —— WindowRag 会退回去看 claude 进程的 CPU，
        只是所有脏都长一个样。
        """
        a.runModal()
    }

    @objc private func openParamsFolder() {
        let dir = Params.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Params.fileURL.path) {
            try? engine.params.save()
        }
        NSWorkspace.shared.activateFileViewerSelecting([Params.fileURL])
    }
}
