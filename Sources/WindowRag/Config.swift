import Foundation
import simd

/// 六种脏。顺序必须和 shader 里的通道顺序一致：
/// T0.r=oil T0.g=dust T0.b=fog T0.a=coffee / T1.r=ink T1.g=rain
enum DirtType: Int, CaseIterable, Codable {
    case oil = 0, dust, fog, coffee, ink, rain

    var key: String {
        switch self {
        case .oil: return "oil"; case .dust: return "dust"; case .fog: return "fog"
        case .coffee: return "coffee"; case .ink: return "ink"; case .rain: return "rain"
        }
    }
    var label: String {
        switch self {
        case .oil: return "机械油污"; case .dust: return "积灰"; case .fog: return "哈气"
        case .coffee: return "咖啡渍"; case .ink: return "墨渍"; case .rain: return "水珠"
        }
    }
    static func from(key: String) -> DirtType {
        DirtType.allCases.first { $0.key == key } ?? .oil
    }

    /// 落在哪张纹理的哪个通道
    var texIndex: Int { rawValue < 4 ? 0 : 1 }
    var channel: Int { rawValue < 4 ? rawValue : rawValue - 4 }

    /// shader 里的形状编号
    var shape: Int {
        switch self {
        case .oil: return 1; case .dust: return 2; case .fog: return 3
        case .coffee: return 4; case .ink: return 5; case .rain: return 6
        }
    }

    /// 挥发倍率 / 擦除阻力 / 水痕倍率 / 尺寸倍率 / 浓度倍率
    var evap: Float {
        switch self {
        case .oil: return 1; case .dust: return 0.35; case .fog: return 3.4
        case .coffee: return 0.45; case .ink: return 0.7; case .rain: return 0.9
        }
    }
    var resist: Float {
        switch self {
        case .oil: return 1; case .dust: return 0.45; case .fog: return 0.3
        case .coffee: return 1.6; case .ink: return 1.25; case .rain: return 0.5
        }
    }
    var streakMul: Float {
        switch self {
        case .oil: return 0.9; case .dust: return 1.8; case .fog: return 2.4
        case .coffee: return 0.7; case .ink: return 0.8; case .rain: return 2.0
        }
    }
    var sizeMul: Float {
        switch self {
        case .oil: return 1; case .dust: return 1.5; case .fog: return 2.1
        case .coffee: return 1.3; case .ink: return 0.9; case .rain: return 1.4
        }
    }
    var alphaMul: Float {
        switch self {
        case .oil: return 1; case .dust: return 0.85; case .fog: return 0.80
        case .coffee: return 1; case .ink: return 1; case .rain: return 0.95
        }
    }

    /// 吸光色 / 散射色 / 边缘高光 / 水痕色
    var dark: SIMD3<Float> {
        switch self {
        case .oil:    return SIMD3(0.075, 0.050, 0.026)
        case .dust:   return SIMD3(0.330, 0.342, 0.366)
        case .fog:    return SIMD3(0.400, 0.450, 0.500)
        case .coffee: return SIMD3(0.130, 0.072, 0.034)
        case .ink:    return SIMD3(0.038, 0.042, 0.090)
        case .rain:   return SIMD3(0.240, 0.290, 0.330)
        }
    }
    var lit: SIMD3<Float> {
        switch self {
        case .oil:    return SIMD3(0.405, 0.292, 0.130)
        case .dust:   return SIMD3(0.600, 0.625, 0.665)
        case .fog:    return SIMD3(0.660, 0.740, 0.800)
        case .coffee: return SIMD3(0.360, 0.215, 0.098)
        case .ink:    return SIMD3(0.130, 0.155, 0.300)
        case .rain:   return SIMD3(0.660, 0.780, 0.865)
        }
    }
    var rim: SIMD3<Float> {
        switch self {
        case .oil:    return SIMD3(0.478, 0.424, 0.290)
        case .dust:   return SIMD3(0.549, 0.576, 0.627)
        case .fog:    return SIMD3(0.576, 0.667, 0.722)
        case .coffee: return SIMD3(0.427, 0.325, 0.204)
        case .ink:    return SIMD3(0.290, 0.333, 0.502)
        case .rain:   return SIMD3(0.624, 0.776, 0.839)
        }
    }
    var streakColor: SIMD3<Float> {
        switch self {
        case .oil:    return SIMD3(0.302, 0.416, 0.463)
        case .dust:   return SIMD3(0.420, 0.455, 0.502)
        case .fog:    return SIMD3(0.490, 0.592, 0.651)
        case .coffee: return SIMD3(0.416, 0.322, 0.251)
        case .ink:    return SIMD3(0.247, 0.290, 0.420)
        case .rain:   return SIMD3(0.361, 0.514, 0.584)
        }
    }
}

/// 和刮板实验场导出的 JSON 一一对应
struct Params: Codable {
    var type: String = "oil"
    var mapMode: Bool = true

    var spawnRate: Float = 2.2
    var blobSize: Float = 52
    var blobDark: Float = 0.5
    var spatter: Float = 5
    var dirtCap: Float = 0.72

    var evapRate: Float = 0.5
    var filmFloor: Float = 0.17
    var filmGrow: Float = 0.45

    var wipeForce: Float = 0.62
    var slowSpeed: Float = 900
    var fastFloor: Float = 0.55
    var feather: Float = 13
    var ridge: Float = 0.78
    var burstAt: Float = 0.9
    var streak: Float = 0.46

    var haloR: Float = 130
    var haloS: Float = 0.62
    var oilAlpha: Float = 0.86

    var volume: Float = 0.55
    var quality: Float = 0.46

    /// 金币：Agent 烧掉的 token 变成屏幕上的金币，晃鼠标吃掉
    var coinsEnabled: Bool = true
    var tokensPerCoin: Float = 400      // 一枚金币值多少 token
    var coinLife: Float = 26            // 没人捡的话多久消失（秒）
    var coinMagnet: Float = 52          // 鼠标多近算吃到（点）
    var coinMax: Float = 140            // 屏幕上最多同时几枚

    /// 只有被拖动的 Claude Code 窗口能擦，还是任何窗口都能擦
    var claudeWindowOnly: Bool = false
    /// 认作 Claude Code 的进程名（CPU 兜底用）
    var agentProcessNames: [String] = ["claude", "claude-code"]

    var primaryType: DirtType { DirtType.from(key: type) }

    static var fileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/windowrag", isDirectory: true)
        return dir.appendingPathComponent("params.json")
    }

    static func load() -> Params {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Params.self, from: data) else {
            return Params()
        }
        return p
    }

    func save() throws {
        let dir = Params.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Params.fileURL)
    }
}

/// 合成的 Codable 缺一个键就整个失败，而实验场导出的 JSON 没有
/// claudeWindowOnly 这些 macOS 专有的键。所以缺什么就用默认值。
extension Params {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Params()
        func f(_ k: CodingKeys, _ dv: Float) -> Float { (try? c.decode(Float.self, forKey: k)) ?? dv }
        func b(_ k: CodingKeys, _ dv: Bool) -> Bool { (try? c.decode(Bool.self, forKey: k)) ?? dv }
        self.init()
        type = (try? c.decode(String.self, forKey: .type)) ?? d.type
        mapMode = b(.mapMode, d.mapMode)
        spawnRate = f(.spawnRate, d.spawnRate)
        blobSize = f(.blobSize, d.blobSize)
        blobDark = f(.blobDark, d.blobDark)
        spatter = f(.spatter, d.spatter)
        dirtCap = f(.dirtCap, d.dirtCap)
        evapRate = f(.evapRate, d.evapRate)
        filmFloor = f(.filmFloor, d.filmFloor)
        filmGrow = f(.filmGrow, d.filmGrow)
        wipeForce = f(.wipeForce, d.wipeForce)
        slowSpeed = f(.slowSpeed, d.slowSpeed)
        fastFloor = f(.fastFloor, d.fastFloor)
        feather = f(.feather, d.feather)
        ridge = f(.ridge, d.ridge)
        burstAt = f(.burstAt, d.burstAt)
        streak = f(.streak, d.streak)
        haloR = f(.haloR, d.haloR)
        haloS = f(.haloS, d.haloS)
        oilAlpha = f(.oilAlpha, d.oilAlpha)
        volume = f(.volume, d.volume)
        quality = f(.quality, d.quality)
        coinsEnabled = b(.coinsEnabled, d.coinsEnabled)
        tokensPerCoin = f(.tokensPerCoin, d.tokensPerCoin)
        coinLife = f(.coinLife, d.coinLife)
        coinMagnet = f(.coinMagnet, d.coinMagnet)
        coinMax = f(.coinMax, d.coinMax)
        claudeWindowOnly = b(.claudeWindowOnly, d.claudeWindowOnly)
        agentProcessNames = (try? c.decode([String].self, forKey: .agentProcessNames)) ?? d.agentProcessNames
    }
}

/// Agent 现在处于什么状态。污渍的行为完全由它决定。
enum AgentState: String {
    case idle, running, waiting, done, failed

    var label: String {
        switch self {
        case .idle: return "待机"; case .running: return "干活中"; case .waiting: return "等你确认"
        case .done: return "完成"; case .failed: return "挂了"
        }
    }
}

/// 工具名 → 留哪种脏
enum ToolMap {
    static func dirt(for tool: String) -> DirtType {
        switch tool.lowercased() {
        case "read", "glob", "notebookread": return .dust
        case "grep", "websearch", "webfetch": return .fog
        case "write", "edit", "multiedit", "notebookedit", "update": return .ink
        case "bash", "bashoutput", "killshell": return .oil
        case "task", "agent": return .coffee
        default: return .oil
        }
    }
    /// 不同工具喷出来的量不一样
    static func weight(for tool: String) -> (size: Float, alpha: Float) {
        switch tool.lowercased() {
        case "read", "glob": return (0.7, 0.7)
        case "grep": return (0.5, 0.6)
        case "bash": return (1.4, 1.1)
        case "write", "edit", "multiedit": return (1.0, 0.95)
        case "task", "agent": return (1.5, 1.1)
        default: return (1.0, 1.0)
        }
    }
}
