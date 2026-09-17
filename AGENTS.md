# Project: Infinite Scroll

macOS 终端工作区管理器：把多个 tmux 终端按行/单元格排布在可无限滚动的画布上，并提供 `infinite-scroll` CLI 与 Agent 任务队列。Swift 5.9 + SwiftPM，SwiftUI/AppKit，最低 macOS 13。

## 目录结构

```
Sources/
├── InfiniteScroll/          # SwiftUI 应用（面板、CLI 服务、Agent 队列、设置）
├── InfiniteScrollCLI/       # infinite-scroll 命令行工具
└── InfiniteScrollProtocol/  # 应用与 CLI 共用的 Codable 协议
Resources/                   # AppIcon、terminfo、cli-prompt.md
docs/fault-reviews/          # 中文故障复盘文档
package.sh                   # 发布打包：release 构建 + .app + DMG
```

## 架构要点

- `Sources/InfiniteScroll/PanelStore.swift` 是工作区唯一数据源；`AgentWorkspaceStore` 独立管理队列状态。两者分别持久化到 `~/.infinite-scroll/`。
- `CLIServer` 通过 Unix socket（`~/.infinite-scroll/socket`，JSON Lines）暴露控制面。改动 `InfiniteScrollProtocol/Protocol.swift` 时必须同步考虑 app 与 CLI 两侧的兼容。
- 每个 terminal cell 对应一个 tmux 会话，命名 `is-<cell UUID>`（`TmuxManager.sessionName`）。
- Row 0 是 master 行：对 CLI 不可见，且禁止任何 CLI 变更。
- 颜色、间距、圆角统一取 `Theme.swift` 常量，不要硬编码。

## 线程规则（关键）

- 主线程禁止阻塞：不要在主线程调用 `TmuxManager.findTmux()`、`Process.waitUntilExit()` 或任何 tmux 子进程。
- 主线程需要 tmux 路径时用 `TmuxManager.cachedTmuxPath()`；启动时已通过 `prewarm()` 预热。
- 会拉起子进程的 CLI 请求（capture/send）遵循"主线程解析计划 + 后台队列执行"模式，见 `CLIServer.handleCaptureOffMain` / `handleSendOffMain`；不要退回在主线程同步执行。
- 共享状态变更回到主线程（`DispatchQueue.main`）。

## 常用命令

| 操作 | 命令 |
|---|---|
| 调试构建 | `swift build` |
| Release 构建 | `swift build -c release` |
| 运行应用 | `swift run InfiniteScroll` |
| 运行 CLI | `swift run infinite-scroll --help` |
| 安装 CLI | `swift run infinite-scroll install` |
| 打包 app + DMG | `./package.sh` |

## 测试与验证

- 项目没有测试 target：本机 Swift 工具链不可用 XCTest/Testing（见 `docs/fault-reviews/2026-07-22-swiftpm-xctest-unavailable.md`）。新增测试目标前必须先验证测试框架可导入。
- 提交前至少运行 `swift build`；涉及终端/tmux 的改动需要实机手动验证（启动 app 并用 `infinite-scroll` CLI 驱动）。
- 纯逻辑尽量抽成不依赖 tmux 会话的静态函数，便于用临时 `swiftc` 探针单独验证（参考 `AgentProcessInspector.inferredState(from:)`）。

## 编码约定

- 缩进 4 空格；代码与注释用英文；`docs/` 下的复盘文档用中文。
- 注释解释"为什么"（平台限制、规避过的 bug），不解释"是什么"。
- 新增或修改快捷键需同步更新：`InfiniteScrollApp.swift`（菜单命令）、`HelpOverlay.swift`（帮助列表）、必要时 `AppCommandShortcut.swift`（物理键码路由）和 README 快捷键表。

## 持久化兼容

- `PanelState` / `CellState` 字段必须向后兼容：新增字段一律 Optional 并提供默认值，不要删除旧字段（如 `cwd` / `notes`）。
- 新增版本号递增：`package.sh` 中 `VERSION`，发布时同步 CLI 版本输出。

## 约束

- 不要改动版本占位机制：`package.sh` 的 `VERSION` 与 `Sources/InfiniteScrollCLI/main.swift` 中的 `CLI_VERSION_PLACEHOLDER`（打包时 sed 替换、退出时恢复），也不要手动替换占位符提交。
- 不要引入新依赖，除非同步更新 `Package.swift` 并保持 macOS 13 最低版本。
- 不要引入新的状态管理或网络库；沿用 SwiftUI + Combine + AppKit 现有模式。
- 不要修改 `Resources/infinite-scroll.terminfo` 中省略 alternate-screen 的行为——SwiftTerm 本地回滚依赖它。
- `send --text` 是字面量语义，不解析按键；需要 Enter 用 `--keys Enter`（CLI 契约，勿改）。
- 不要提交 `.build/`、`*.app`、`*.dmg`（已在 `.gitignore`）。
- 除非用户明确要求，不要 commit 或 push。

## Git 约定

- 提交信息用祈使句英文、简短概括；发布提交附版本号，例如 `Fix font setting persistence and v1.0.17`。
- 发布流程见 `.claude/skills/publish/skill.md`；其中的绝对路径为旧机器路径，操作时以本仓库实际路径为准。
