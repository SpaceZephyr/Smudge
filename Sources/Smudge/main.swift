import AppKit

// 离屏自检：不碰真实屏幕，出一张图看着色器对不对
if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
    let path = CommandLine.arguments.count > i + 1
        ? CommandLine.arguments[i + 1]
        : FileManager.default.currentDirectoryPath + "/smudge-selftest.png"
    let code = SelfTest.run(to: path)
    if code == 0 { print("写好了：\(path)") }
    exit(code)
}

// 看一个 JSON 会被解析成什么（实验场导出的文件缺键也应该能吃）
if let i = CommandLine.arguments.firstIndex(of: "--params") {
    let url = CommandLine.arguments.count > i + 1
        ? URL(fileURLWithPath: CommandLine.arguments[i + 1]) : Params.fileURL
    guard let data = try? Data(contentsOf: url),
          let p = try? JSONDecoder().decode(Params.self, from: data) else {
        print("读不出来：\(url.path)"); exit(1)
    }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try! enc.encode(p), as: UTF8.self))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)      // 只在菜单栏，不占 Dock
let delegate = AppDelegate()
app.delegate = delegate
app.run()
