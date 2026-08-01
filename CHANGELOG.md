# Changelog

## v1.5.0

新增 `scripts/routebar` 命令行客户端。走的是 v1.4.0 那套本地 API，因此它做的每件事
和在窗口里、网页上做的完全等价——同一个引擎、同一组动词。

- 只依赖 Python 3 标准库；端口与令牌从 settings.json 读，无需另外配置。
- 订阅与节点可用列表序号、完整名或名字的一部分指定。节点 id 是 64 位 SHA256
  十六进制串，命令行里没人会去敲。匹配到多个时列出候选并要求说得更具体，不猜一个执行。
- 输出被重定向或设了 NO_COLOR 时自动去色；CJK 名字按显示宽度对齐（一个汉字两列，
  用 len() 会让整张表歪掉）。
- 连不上时明确区分「RouteBar 没运行」和「输出方式没选订阅地址」两种原因。

## v1.4.0

本地服务从「只给 Surge 一个订阅地址」扩成「订阅地址 + 一个浏览器界面」，同端口同令牌。
不必打开 Mac 窗口就能改订阅、开关节点、测速、起停服务。

### HTTP 层

- `LocalSubscriptionServer` 泛化为 `LocalHTTPServer`：可插拔路由，支持请求体。
- 新增 `HTTPRequest` 增量解析（Domain 层，纯函数可测）。原来只 `receive` 一次就解析——
  TCP 不保证一次读到整条请求，带 body 的 POST 必然分包，那种写法会随机把 JSON 截断。
- 端口不变时换路由不重启监听，避免恰好在这一刻的 Surge 拉取失败。

### API 与 Web 界面

- 路由表（`/<令牌>/api/…`）全部映射到 `AppModel` 上**已有的**方法，经由 `RouteBarAPIHost`。
  API 层不含任何业务逻辑：两个前端共用一套动词，防抖重装、更新进度、测速端点因此
  不可能分叉。若让路由直连引擎，网页上的操作会绕过这些包装，行为会悄悄不一致。
- 响应用独立的 `APISnapshot` 等 DTO，不直接序列化 `SubscriptionRecord`、`ProxyNode`——
  那几个类型的 `Codable` 是为落盘服务的，让它们兼任对外契约，等于每次改存储格式
  都会静默改掉 API。
- 界面自包含，无任何外部请求；令牌不内联进页面，由脚本从自身 URL 读取。

### 安全边界

- 仅绑定 `127.0.0.1`；校验 `Host` 头是回环地址且端口相符——绑定地址挡不住 DNS rebinding。
- 令牌定长比较，不匹配返回 404 而非 403。
- 写操作要求 `Content-Type: application/json`，且不返回任何 CORS 头，跨源预检必然失败。
- 响应体不含凭据：只有节点名、主机、本地端口与延迟。

### 其他

- 新增 `ConfigurationGenerator.surgePolicyLines`，让「写进配置的 `[Proxy]` 段」与
  「订阅地址返回的列表」同源。各拼一遍的话，`.both` 模式下 Surge 会看到两套名字
  不同的同一批节点，而这种错位只有逐行比对才看得出来。
- 策略集改为按请求现算。原来缓存字符串，会在「配置未变化、跳过安装」那条分支上
  停留在上一轮的内容。

## v1.3.0

Surge 的接入方式从「改写它的配置文件」变成「给它一个订阅地址」，两种方式并存可选。

### 本地订阅地址

- 新增 `LocalSubscriptionServer`：`NWListener` 绑 `127.0.0.1`，只响应
  `GET /<token>/proxies`，其余一律 404。用 `requiredLocalEndpoint` 而非监听全部接口，
  局域网内访问不到——这份列表暴露的是本机全部出口。
- 输出的是裸策略行，**不带 `[Proxy]` 段头**。格式对照实际的 sub.store `policy-path`
  响应确认过，Surge 侧写法与外部订阅完全一致。
- 端口占用（errorCode 48）单独报「端口已被占用」，否则用户只会看到一个数字。

### 输出方式成为设置项

- `SurgeOutputMode`：写入 Surge 配置 / 本地订阅地址 / 两者都要。
- 选订阅时 `install` 不再触碰 Surge 配置文件——`[Proxy]` 是整段替换的，
  不写它才能和 sub.store 之类的外部订阅共存。
- 「服务」页新增卡片：服务状态、完整地址、可直接复制的 `policy-path` 示例。

### 修复

- **`subscriptionToken` 未持久化**，每次启动都会重新生成，用户填进 Surge 的地址
  次日即 404。协调器初始化时补齐的字段现在会写回磁盘。
- `RouteBarSettings` 改为逐字段 `decodeIfPresent`。合成的 Codable 遇到缺失键整体抛错，
  而 `loadSettings` 的策略是解不出就回落默认值——升级一次就会悄悄冲掉用户已有的路径设置。

## v1.2.0

让 RouteBar 能装在别人机器上。此前它检测得出 LaunchAgent 缺失，却不提供任何解法——
新用户只能自己手写 plist，这是唯一一处过不去的坎。

### LaunchAgent 成为第三个托管产物

- 新增 `LaunchAgentDefinition`：plist 的每个字段都从设置派生，和 `sing-box.json`、
  Surge 的 `[Proxy]` 段地位相同。做成一次性的「创建」按钮会让同一份信息有两个来源，
  用户改完路径后 plist 还指着旧的二进制。
- 「环境」页可直接创建并 `launchctl bootstrap` 加载，设置变更后可重新生成。
- 托管标记写成 XML 注释而非自定义键：launchd 对不认识的键会报警告，注释则在解析前丢弃。
- **绝不静默覆盖别人的文件。** 非 RouteBar 创建的 plist 会先展示完整内容供确认，
  原文件保留为 `.routebar-backup`——手写的 plist 里可能有 RouteBar 不知道的字段。

### 首次启动接管已有服务

- 新增 `LaunchAgentDiscovery`：没有 settings.json 时扫描 `~/Library/LaunchAgents`，
  按启动命令（`sing-box run -c <配置>`）识别，不看 Label 和文件名——那些是任人取的。
  认出后把 Label 与四个路径写进设置。
- 不这么做的话，已经手搭好一套的用户打开应用只会看到「LaunchAgent 未找到、服务已停止」，
  而他的代理明明跑得好好的，只是标识对不上。

### 默认值

- LaunchAgent Label 从 bundle identifier 派生，不再硬编码某个作者的名字。
- sing-box 路径按 `/opt/homebrew/bin` → `/usr/local/bin` → `/usr/bin` 探测，
  原来写死 Homebrew 的 Apple Silicon 前缀，在 Intel Mac 上必然是错的。
- Surge 提示改为说明「新建一份含 `[Proxy]` 和 `[Proxy Group]` 的配置即可」。

以上只影响没有 settings.json 的机器；已保存过设置的不受影响。

## v1.1.2

一轮代码审查后的集中修复。

### 行为

- 测速遇到失败（尤其是超时）不再重试满 3 次。一个死节点原来会把整批测速从 8 秒拖到 24 秒。
- 只有用户主动触发的操作才弹窗报错，后台自动更新失败只进日志；一次操作里的多条错误
  合并成一个弹窗，不再互相覆盖只剩最后一条。
- 连续开关节点/订阅时防抖 500ms，合并成一次重装，不再每点一下就重启 sing-box、断掉所有连接。
- 生成的配置与已装的逐字节相同时，跳过安装与重启（仍会刷新服务状态）。
- 关闭主窗口后点 Dock 图标可以重新唤出窗口。
- 从 Mihomo 导入订阅时钥匙串写入失败会明确报错，不再留下一条没有地址的订阅记录。

### 界面

- 延迟阈值改为 600 / 1000 ms 并集中到 `LatencyClassification`。RouteBar 测的是
  端到端链路，套用直连节点的 100/200 ms 阈值会让所有节点都显示成红色，等于没有信息。
  筛选项文案也由同一组常量生成，不会和配色漂移。
- 节点页筛选条在窄窗口下换成 2×2 排列，不再被详情栏挤掉。

### 内部

- `CommandRunner` 改为异步，子进程不再阻塞引擎 actor；同时补一把重装互斥锁，
  因为 actor 现在会重入，没有它新旧配置可能互相覆盖。
- `AppViewState` 的派生数据改为构造时算一次。原来是计算属性，界面一次刷新要重复
  merge + sort 全部节点，实测 51 个节点约 1.7ms/次。
- 新增 `ConfigurationGenerator.portMapping`：状态快照只需要端口号，原来却要走
  `generate` 把整份配置序列化一遍（51 节点 1.1ms、500 节点 11ms）。`generate` 复用
  同一方法，两条路径的编号规则不会分叉。
- 修掉更新任务的一处竞态：`guard` 与置位之间隔着 await，调度器与窗口激活同时触发时能进两次。

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
