# RouteBar 自用说明

## 管理范围

RouteBar 负责三件事：

1. 管理多个订阅地址，订阅 URL 存在 Keychain。
2. 解析 VLESS Reality 节点，去重后生成 sing-box 本地 SOCKS 出口。
3. 更新托管的 Surge 配置，让 Surge 规则指向 RouteBar 生成的代理组。

## 关键路径

RouteBar 会把这些路径保存到：

- RouteBar 设置：`~/Library/Application Support/RouteBar/settings.json`

首次启动时，如果检测到关键路径缺失，会打开“环境设置”向导。后续也可以在“订阅管理”或“设置”里打开。

- sing-box 配置：`~/.config/sing-box/surge-vless.json`
- sing-box 标准日志：`~/.config/sing-box/surge-vless.log`
- sing-box 错误日志：`~/.config/sing-box/surge-vless-error.log`
- Surge 托管配置：`~/Library/Application Support/Surge/Profiles/surge-singbox.conf`
- LaunchAgent：`~/Library/LaunchAgents/com.daniellau.sing-box-surge.plist`
- RouteBar 状态：`~/Library/Application Support/RouteBar/state.json`
- RouteBar 更新记录：`~/Library/Application Support/RouteBar/update.log`

这些是默认值，可以在环境设置里改成新用户自己的实际路径。

## 多订阅处理

- 每个订阅可以独立启用、更新、设置更新间隔。
- RouteBar 会把启用订阅中的节点合并，并按节点连接参数去重。
- 节点的启用状态和测速结果会在订阅刷新后尽量保留。
- “订阅管理”和“节点管理”默认只显示列表区；点击具体订阅或节点后才展开右侧详情。

## 自动更新

- 自动更新只在 RouteBar 运行时生效。
- RouteBar 启动、重新激活、系统唤醒时会重新计算到期订阅。
- 退出 RouteBar 后不会有额外后台任务更新订阅。
- 总开关在“设置 → 自动更新”里，暂停/恢复状态会保存到 RouteBar 状态文件。
- 每个订阅的更新间隔在“订阅管理 → 选择订阅 → 编辑订阅 → 更新间隔”里设置。

## 日志

- “日志 → 更新记录”显示 RouteBar 自己写入的订阅更新、解析结果和配置生成结果。
- “日志 → 标准日志 / 错误日志”显示 sing-box 的运行输出。
- 更新记录会持久化到 `~/Library/Application Support/RouteBar/update.log`，重启 RouteBar 后仍可查看。

## 常见排查顺序

1. 先看 RouteBar 仪表盘自检。
2. 到“服务管理”确认 LaunchAgent、sing-box 配置、Surge 配置是否存在。
3. 到“日志 → 更新记录”确认订阅拉取和配置生成是否成功。
4. 到“日志 → 错误日志”查看 `surge-vless-error.log`。
5. 到“节点管理”单测一个节点延迟。
6. 如果配置生成失败，运行：`/opt/homebrew/bin/sing-box check -c ~/.config/sing-box/surge-vless.json`。
