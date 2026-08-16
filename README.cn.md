<p align="center">
  <img src="Assets/DisplaySteward.svg" width="144" alt="Display Steward 图标">
</p>

# Display Steward

**中文** | [English](README.md)

Display Steward 是一个原生 macOS 菜单栏工具，用显式规则管理显示器启停状态。它支持为办公室、家里等使用方式创建多个 Display Profile，同时保留手动控制、恢复证据和最后活动屏保护。

## 功能

- **Display Profiles**：每个 Profile 独立保存名称、自动化设置、轮询配置和规则。
- **手动激活**：Profile 不会根据地点或显示器自动切换；用户从 Settings 或状态栏明确选择。
- **规则引擎**：按在线/活动显示器数量和具体设备状态匹配规则，并通过优先级合并动作。
- **安全切换**：激活前使用最新显示器拓扑预览；涉及关闭显示器或安全警告时要求确认。
- **最后活动屏保护**：阻止规则或手动操作关闭最后一台可用显示器。
- **可恢复状态**：记录由应用发起但尚未确认完成的禁用和恢复操作。
- **手动控制**：状态栏可开启、关闭或恢复受管显示器。
- **全局快捷键**：默认 `⌃⌥⇧D`，用于切换内建显示器，可在 Settings 中修改。

Display Steward 只管理显示器启用和停用，不修改主屏、排列、分辨率、刷新率、缩放、HDR 或色彩配置。

## 系统要求

- macOS 13 或更高版本
- Xcode Command Line Tools，提供 `swiftc`、`codesign`、`plutil`

项目直接使用 `swiftc` 和系统 Framework 构建，不依赖 Swift Package Manager 或第三方运行时库。

## 快速开始

### 本地构建

```sh
./build.sh
```

应用生成于：

```text
build/Display Steward.app
```

### 安装并启动

```sh
./install.sh
```

安装脚本会：

1. 构建并签名应用；
2. 停止旧的 Display Steward / Screen Manager 进程与 LaunchAgent；
3. 迁移兼容的旧配置目录；
4. 安装并启动 `com.anhoder.display-steward` LaunchAgent。

### 无副作用安装检查

```sh
./install.sh --smoke-test
```

该模式只验证构建、Bundle、plist 和代码签名，不修改 LaunchAgent、进程、配置或显示器状态。

## 使用

1. 从菜单栏打开 **Display Steward → 打开设置…**。
2. 在 Profile 列表中新建空白 Profile，或复制现有 Profile。
3. 编辑名称、自动化、轮询和规则。
4. 使用 **保存**、**保存并激活** 或 **保存并应用** 明确提交。
5. 也可以从状态栏的 **配置档** 子菜单快速激活已保存的 Profile。

Settings 会分别标记“正在编辑”和“当前激活”的 Profile。单击列表只切换编辑对象，不会改变显示器状态。未保存修改在切换、关闭、退出或状态栏操作前都会经过保存、放弃或取消确认。

## 配置文件

默认配置根目录：

```text
~/.config/display-steward/
├── config.json                         # 全局热键、显示器历史、Active Profile ID
├── config.last-good.json               # 全局设置安全代次
├── runtime-state.json                  # 当前启动周期的恢复证据
└── profiles/
    ├── <uuid>.json                     # Profile 正式文件
    └── last-good/
        └── <uuid>.json                 # Profile 安全代次
```

配置损坏时，应用只会尝试同一设置或 Profile 的最后有效代次，不会自动选择其他 Profile，也不会静默覆盖损坏文件。

## 故障排查

### 日志文件

- **主日志**：`~/Library/Logs/com.anhoder.display-steward.log`。应用以 ISO 8601 时间戳逐行追加，带类别前缀：`[AUTO]`（拓扑观察、规则求值、事务与后置检查）、`[HOTKEY]`（快捷键注册与使用）、`[RULES]`（规则播种与错误）。
- **LaunchAgent 标准错误**：`~/Library/Logs/com.anhoder.display-steward.error.log`。
- **配置与恢复证据**：`~/.config/display-steward/`（`config.json`、`config.last-good.json`、`runtime-state.json`）。
- **单实例锁**：`~/Library/Application Support/Display Steward/instance.lock`。

### 常见问题

| 症状 | 排查 |
| --- | --- |
| 菜单栏没有应用图标 | `launchctl print "gui/$(id -u)/com.anhoder.display-steward"`；用 `./install.sh` 重装 |
| 全局快捷键无效 | 查看日志 `[HOTKEY]` 行；可能被其他应用占用，在设置中更换 |
| 自动化行为与预期不符 | `[AUTO] evaluation` 行显示匹配规则、胜出动作、冲突与最后活动屏安全拦截 |
| 升级后显示行为异常 | 用 `./install.sh` 重新构建安装；可先 `./install.sh --smoke-test` 无副作用验证产物 |

## 开发与验证

运行完整测试：

```sh
./test-all.sh
```

测试分层：

| 阶段 | 范围 |
| --- | --- |
| Phase 1 | 领域模型、规则求值、配置存储与迁移 |
| Phase 2 | 显示器清单、动作事务、自动化与恢复生命周期 |
| Phase 3 | Presentation、Profile 草稿与 AppKit 管理界面 |
| Phase 4 | 启动、迁移、状态栏和端到端集成 |

单独运行某一阶段：

```sh
./test-phase1.sh
./test-phase2.sh
./test-phase3.sh
./test-phase4.sh
```

提交改动前建议运行：

```sh
./test-all.sh
./install.sh --smoke-test
```

更多开发约束见 [CONTRIBUTING.md](CONTRIBUTING.md)。领域语言和架构决策分别记录在 [CONTEXT.md](CONTEXT.md)、[SOUL.md](SOUL.md) 和 [`docs/adr/`](docs/adr/)。版本历史见 [CHANGELOG.md](CHANGELOG.md);安全策略见 [SECURITY.md](SECURITY.md)。

## 主要模块

| 文件 | 职责 |
| --- | --- |
| `DisplaySteward.swift` | 应用入口、状态栏、全局快捷键和 AppKit 生命周期 |
| `AutomationCoordinator.swift` | 自动化调度、Profile 激活、动作重试和恢复协调 |
| `RuleModel.swift` | 显示器、规则、Profile 和全局设置模型 |
| `RuleEvaluator.swift` | 条件匹配、优先级合并和最后活动屏保护 |
| `ConfigurationStore.swift` | 分离式配置持久化、回退、迁移和 Profile 生命周期 |
| `RuntimeStateStore.swift` | 当前启动周期的禁用与恢复证据 |
| `AppPresentation.swift` | 用户可见状态和交互文案 |
| `ManagementUI.swift` | Settings、Profile、规则和显示器管理界面 |

## 安全说明

显示器启停依赖动态解析的私有 CoreGraphics SPI `CGSConfigureDisplayEnabled`。应用将其限制在事务适配器内，并在每次操作前后验证显示器拓扑与结果，但系统升级仍可能改变该接口行为。

修改真实显示器状态前，请确保至少保留一台可用显示器。自动化、恢复和手动操作都必须继续满足最后活动屏安全约束。

## 许可证

[MIT](LICENSE) © 2026 anhoder
