# RouteBar

RouteBar 是一个 macOS SwiftUI 应用：拉取机场订阅、解析并去重 VLESS Reality 节点、
为每个启用节点生成一个 sing-box 本地 SOCKS 出口，再把这些出口注入 Surge 配置。
分流规则仍由 Surge 决定，RouteBar 只负责把可用出口准备好并保持同步。

## 架构

源码按依赖方向分三层，位于 `RouteBar/` 下：

| 目录 | 职责 | 约束 |
|------|------|------|
| `RouteBarDomain/` | 模型与纯逻辑：节点去重、配置生成、Surge 配置改写、订阅解析、排期、统一视图状态 | 只依赖 Foundation，无 I/O、无 SwiftUI。可单独跑 `swift test` |
| `RouteBarCore/` | I/O：命令执行、launchctl、订阅拉取、延迟测试、钥匙串、落盘，以及编排这一切的 `SubscriptionCoordinator` | 依赖 Domain，不依赖 SwiftUI |
| `RouteBarApp/` | 界面：`AppModel`、侧栏分区、各页面、运行日志、应用外壳 | 依赖前两层 |

根目录的 `RouteBarApp.swift`（场景与 `AppDelegate`）与 `ContentView.swift`（转发到
`MainWindowView`）保持极薄。

核心约定是 **单一视图状态**：引擎 `SubscriptionCoordinator`（actor）每完成一次操作就产出
一份 `AppViewState` 快照 + 一批待记录日志消息；`AppModel` 整份替换自己的状态。菜单栏面板
与主窗口读的是同一份快照，界面层不持有任何业务可变状态。

## 构建

```sh
xcodebuild build \
  -project RouteBar.xcodeproj \
  -scheme RouteBar \
  -destination 'platform=macOS'
```

> **不要传 `-derivedDataPath`。** Xcode 和命令行必须构建到*同一个*派生数据目录，
> 否则仓库里会出现多个不同版本的 `RouteBar.app`，LaunchServices 解析
> `com.liuyude.RouteBar` 时可能挑中旧的那份，`open`/Spotlight 会静默启动过期构建
> —— 看起来就像「我的改动没生效」。

## 测试

Domain 层是纯逻辑，用 SwiftPM 直接跑，不必启动整个 app：

```sh
swift test
```

## 发布

版本号的单一来源是仓库根的 `VERSION` 文件。

```sh
# 1. 改版本
echo "1.2.0" > VERSION

# 2. 同步到 AppVersion.swift 与 MARKETING_VERSION（不一致会直接失败）
./scripts/sync-version.sh

# 3. 构建 Release 并打包到 dist/RouteBar-<版本>.zip
./scripts/package.sh
```

`package.sh` 会在 app bundle 里的版本与 `VERSION` 不符时拒绝打包，所以忘记跑第 2 步
不会产出版本对不上的包。它用 `ditto` 而不是 `zip`：`zip` 会破坏 `.app` 里的符号链接与
扩展属性，解包后代码签名失效。

`dist/` 已被 git 忽略——包是构建产物，不是源码。

## 运行时依赖

RouteBar 不自带 sing-box，也不接管 Surge 的安装。以下路径都是设置项，在应用的「环境」页配置：

- sing-box 可执行文件（默认 `/opt/homebrew/bin/sing-box`）
- sing-box 配置与日志（默认 `~/.config/sing-box/`）
- Surge 托管配置（必须已存在，且含 `[Proxy]` 与 `[Proxy Group]` 段）
- LaunchAgent plist 与 Label（由你自己安装，决定 sing-box 如何被 launchd 拉起）

订阅地址存放在钥匙串，不写入任何配置文件。覆盖 sing-box 与 Surge 配置前都会留一份
`.routebar-backup`；新配置先经 `sing-box check` 校验，通过后才替换正式文件。

## 日志

- **运行日志**页：RouteBar 自身的诊断记录（内存保留最近 1000 条，重启清空），
  同时镜像到统一日志，更早的记录可用
  `log show --predicate 'subsystem BEGINSWITH "com.liuyude.RouteBar"'` 查看。
- **服务**页：sing-box 进程自己写的标准日志与错误日志文件。

排查顺序：先看服务页的错误日志有没有配置解析或 Reality 握手报错，再回运行日志看
RouteBar 这边做了什么。
