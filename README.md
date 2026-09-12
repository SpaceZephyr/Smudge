# 窗口抹布 · WindowRag

Agent 干活的时候，屏幕会慢慢变脏。拖任何一个窗口，走过的地方就被刮干净。

一个常驻菜单栏的 macOS 覆盖层。它解决两个问题。

## 一、瞄一眼屏幕，就知道它干到哪儿了

Agent 干活的时候是个黑盒。你只看到终端里的字往上滚，不切回去就不知道它在读文件、在跑测试，还是已经卡住等你了。

所以让屏幕来说话：

| 屏幕上发生什么 | 意思 |
|---|---|
| 越来越脏 | 它在干活，脏得越快说明动作越密 |
| 脏在慢慢退 | 它慢下来了，或者在等模型返回 |
| 画面凝住不动 | 它在等你确认 |
| 一道水从上往下冲干净 | 任务真的结束了 |
| 一摊不会退的红渍 | 挂了 |

「凝住」那个状态最值钱。Claude Code 等你按回车的时候，你要是切走了根本不知道，屏幕整个凝住比终端里一行提示更容易被余光抓到。

配上 hook 之后，脏的种类还对得上它在干什么：Read 扬起积灰、Grep 是转瞬即逝的哈气、Write 留墨渍、Bash 漏油、Task 洒咖啡。

最实用的场景是你人不在电脑前。让它跑个长任务，回来瞄一眼屏幕——干净就是跑完了，糊着一团就是还在跑，有块红的就是挂了。不用切窗口、不用看终端。

## 二、等它的时候，你手里总得有点事做

这个问题没人正经讲过，但它真实存在：Agent 干活的那几分钟，人是空的。

你不好去干别的，怕它中途要你确认；又没什么能干的，活是它在干。于是就开始刷手机、开始盯着光标、开始每隔十秒 cmd+tab 回去看一眼。

所以给你一块抹布。

拖着窗口擦玻璃，慢推擦得净、快划只抹开，前缘会堆起油脊、推厚了会崩开甩到两边，还有刮玻璃那声吱呀。擦不完的——你擦的时候它还在往外冒。这事本来也不是为了擦完。

**擦不改变任何进度。** 这一点我没打算藏着：进度是 Agent 自己的事，抹布只是给你的手找点事干。做成「擦一擦能加速」那种假反馈，你试两次就会发现是骗人的。

![六种脏各来几块，中间横着擦了一道](docs/preview.png)

上图是 `--selftest` 的离屏渲染：左上机械油污、中上积灰、右上哈气、左下咖啡渍、中下墨渍、右下水珠，中间那条横带是抹布走过的地方，右半边的斜纹是没擦匀留下的水痕。底下垫的是假桌面，用来看可读性。

## 装

去 [Releases](https://github.com/SpaceZephyr/WindowRag/releases) 下 DMG，拖进 Applications。第一次打开被 Gatekeeper 拦的话，右键 → 打开，或者 `xattr -dr com.apple.quarantine /Applications/WindowRag.app`（只做了 ad-hoc 签名，没买苹果开发者证书）。

装好之后菜单栏会出现一滴油。先点「喷一把脏（试手感）」，然后拖任何一个窗口试试擦。

## 权限

**一个都不要。** 不读屏幕内容，所以不需要录屏权限；窗口位置走 `CGWindowListCopyWindowInfo`，那是公开信息，不需要辅助功能权限。

## 编译

```bash
./build.sh            # 出 build/WindowRag.app
./package.sh 0.2.0    # 出 build/WindowRag-0.2.0.dmg
open build/WindowRag.app
```

只用 Swift Package Manager，没有 Xcode 工程。着色器是运行时编译的，所以不需要装 Metal 离线工具链。

想在不动真实屏幕的前提下看渲染效果：

```bash
swift build && ./.build/debug/WindowRag --selftest /tmp/out.png
```

另外两个调试口子：

```bash
./.build/release/WindowRag --params 某个.json   # 看这个文件会被解析成什么
WINDOWRAG_DEBUG=1 ./.build/release/WindowRag    # 休眠/唤醒打日志
```

## 开销

屏幕干净的时候整个渲染是停的（MTKView 直接 pause，只留一个 10Hz 的计时器盯着窗口有没有被拖），两块 Retina 屏实测 **1.8% CPU / 149MB**。Agent 在干活、屏幕上有脏的时候升到 **8–10% CPU / 228MB**（两块屏 60fps）。合成着色器对完全干净的像素会直接返回，所以脏得少的时候更便宜。

## 怎么知道 Agent 在干活

两条路，hook 优先。

**Claude Code hooks（准，能分清工具）**
菜单里点「复制 hook 配置」，把复制到的内容合并进 `~/.claude/settings.json`。之后每次工具调用、每次等你确认、每次任务结束，窗口抹布都会收到通知，据此决定落哪种脏。

**进程 CPU（糙，但通用）**
没配 hook 的时候，每 1.5 秒看一眼名字叫 `claude` 的进程吃了多少 CPU。两头都有迟滞：连着忙 3 秒才算开工，连着闲 24 秒才算收工——agent 的 CPU 在一次会话里本来就忽高忽低（等模型返回的时候接近零），不迟滞就会疯狂抖。

**这条路不会触发冲洗。** 冲洗是一句「任务干完了」的断言，CPU 只能看出「这会儿不忙」，没资格下这个断言。所以走 CPU 的时候脏只是自己慢慢淡下去，不冲、不响铃。想要那一下冲洗和「全清 = 完成」这层意思，必须配 hook。

这条路也拿不到工具名，所有脏都长一个样，但换成 Cursor、Codex 或者别的 agent 也能用（改 `agentProcessNames`）。hook 一旦有动静，90 秒内就不看 CPU 了。

## 六种脏

| 类型 | 对应工具 | 性格 |
|---|---|---|
| 机械油污 | Bash | 厚圆瓣带甩点，有光泽 |
| 积灰 | Read / Glob | 干颗粒，一擦就掉，最容易抹花 |
| 哈气 | Grep / WebSearch | 全是软边，挥发是油的三倍多 |
| 墨渍 | Write / Edit | 实心核心甩细触须，赖着不走 |
| 咖啡渍 | Task | 环形，最难擦，挥发最慢 |
| 水珠 | — | 一颗颗硬边水滴，自带亮边 |

菜单里关掉「按工具映射污渍」就全用一种（`params.json` 里的 `type`）。

## 参数

刮板实验场（网页版）调好手感之后导出 JSON，菜单里「载入参数 JSON…」直接吃进来，存在 `~/.config/windowrag/params.json`。

两个 macOS 版独有的开关不在实验场里：

- `claudeWindowOnly` — 只有 Claude Code 所在的那个终端窗口能当抹布。默认关，也就是拖任何窗口都能擦。
- `agentProcessNames` — CPU 兜底认哪些进程名。

## 已知的坑

**盖不住真正全屏的应用。** 进了独立 Space 的全屏窗口在覆盖层之上，这是 macOS 的窗口层级限制，绕不过去。

**颜色和网页版实验场不完全一样。** 实验场用了 multiply 和 screen 混合模式，覆盖窗口只能 source-over，没法和底下的桌面做乘法。所以这里改成了物理上更对的模型：每种脏有一个吸光色和一个散射色，噪声决定局部是压暗还是提亮。油和墨还是压暗为主，灰、雾、水珠靠提亮，因为它们本来就是散射光的。

**token 见底还没接上。** Claude Code 目前没有暴露 context 用量的 hook，所以只有任务失败能触发红渍。

**ad-hoc 签名。** `build.sh` 用 `codesign --sign -`，换机器要重新编。

## 结构

```
Config.swift        六种脏的性格、参数表、工具映射
Shaders.swift       全部 MSL，运行时编译
DirtSim.swift       GPU 上的遮罩：生成 / 挥发 / 擦除全靠固定功能混合，不回读
Overlay.swift       每块屏幕一个透明窗口 + 一份遮罩
Engine.swift        状态机、生成节奏、擦除、油脊、冲洗
WindowTracker.swift 轮询窗口位置，动了就是在擦
AgentMonitor.swift  hook 的 HTTP 服务 + CPU 兜底
Sound.swift         实时合成，没有音频文件
SelfTest.swift      离屏出图
```

脏污全程待在 GPU 纹理里。生成是 `dst + src(1-dst)`，挥发是 `dst * k`，擦是 `dst * (1-e)` —— 三种固定功能混合，没有一次回读，所以四块屏幕也不心疼。
