# Changelog

## v1.1.1

- 测速端点改为可配置（「通用 → 测速」），预设 Cloudflare / Google gstatic / Apple，也可自定义。
- 每个节点默认连测 3 次取最小值。实测同一节点连测五次得到 193ms 到 1207ms，
  单次采样会让一次偶发抖动把好节点判死；取最小而非平均，是因为要衡量的是链路能有多快。
- 默认端点从 gstatic 改为 Cloudflare：实测每个节点上都快 30–40%。
  **换端点后所有数字会整体平移，不要和换之前的比。** 运行日志会记录本次用的端点。

## v1.1.0

按 ServiceWatch 的架构整体重构。

### 分层

- 源码拆成 `RouteBarDomain/`（纯逻辑，无 I/O）、`RouteBarCore/`（I/O 与引擎）、
  `RouteBarApp/`（界面）三层；`RouteBarApp.swift` 与 `ContentView.swift` 收薄为纯外壳。
- 新增引擎 `SubscriptionCoordinator`（actor），独占持有订阅与设置，编排
  拉取 → 解析 → 去重 → 生成 → 校验 → 写入 Surge → 重启的完整链路。
- 新增统一视图状态 `AppViewState`：菜单栏与主窗口读同一份快照，`AppModel` 不再持有
  业务可变状态（原来散在十几个 `@Published` 里，两处显示不一致只能靠肉眼发现）。
- 引擎不写日志，改为随操作结果返回 `OutcomeMessage`，由界面层落进运行日志。

### 界面

- 侧栏改为系统标准的分组列表（状态 / 订阅与节点 / 运行 / 高级），替换原来六个平铺的
  自绘按钮；底部固定服务状态与「更新全部订阅」。
- 窗口从三栏改为两栏，删除各页的「XX 说明」填充详情页；订阅页与节点页的详情栏
  内嵌在页面内部。
- 页内不再重复窗口标题；新增共享组件 `PageBar` / `InfoCard` / `MetricTile` /
  `PathRow` / `settingsSection`，各页样式不再各写一套。
- 菜单栏从 `.menu` 改为 `.window` 面板：顶部状态卡片 + 待处理项 + 操作。
- 环境设置从一次性模态助手改为常驻的「环境」页。
- sing-box 的日志文件归入「服务」页，「运行日志」页只留 RouteBar 自身的记录。

### 新增

- 主题（浅色 / 深色 / 跟随系统）、默认窗口尺寸、隐藏 Dock 图标、登录时自动启动。
- 运行日志：内存环形缓冲 + 级别过滤 + 搜索 + 复制 / 导出，并镜像到系统统一日志。
- `VERSION` 单一版本来源，配 `scripts/sync-version.sh` 与 `scripts/package.sh`；
  新增「关于」页与 `README.md`。

### 移除

- `update.log`：同一批事件已进运行日志并镜像到统一日志，不再单独维护一份纯文本。

## v1.0.1

- 完成 RouteBar 原生菜单栏应用的订阅、节点、服务、日志和设置管理界面。
- 支持多订阅导入、VLESS Reality 节点解析、去重、测速、启用状态保留和 sing-box/Surge 配置生成。
- 新增环境设置向导，允许新用户配置 sing-box、Surge、LaunchAgent 和日志路径。
- 新增运行期自动更新；自动更新只在 RouteBar 运行时生效，暂停状态会持久化。
- 新增持久化更新记录，保存到 `~/Library/Application Support/RouteBar/update.log`。
- 优化三栏布局：订阅和节点详情不再默认展开，选择具体项目后再显示右侧详情。
