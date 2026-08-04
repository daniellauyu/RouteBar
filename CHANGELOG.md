# Changelog

## v1.9.1

重写 `docs/routebar-usage.md`，并修正一处会让人直接踩坑的错误示例。

- **`socks5` → `socks5h`**。README 里那条 `ALL_PROXY=socks5://…` 的例子是错的：实测
  `socks5://` 会 SSL 握手失败，`socks5h://` 才返回 204。区别在于域名由谁解析——写成
  `socks5` 时 DNS 在本机解析，被污染的域名拿到的是错地址。同一个端口用 HTTP 代理没这个
  问题（域名本来就交给代理）。排查文档里单列了一节讲这个症状。
- `docs/routebar-usage.md` 从早期自用笔记重写为「日常使用与排查」：文件都在哪（含
  钥匙串条目与 `.routebar-backup`）、按症状排查（连不上 / 节点变少 / Surge 看不到 /
  服务起不来 / 端口被占 / 测速看着不对）、以及**完全卸载**的四步命令。
  原文档里的 `update.log` 早在 v1.1.0 就不再产生，那段已经删掉。
- README 补上「更多文档」入口。

## v1.9.0

**Surge 不是必需的**——纠正文档与界面里「非 Surge 不可」的错误暗示。

RouteBar 产出的是一组本机端口（`127.0.0.1:7701` 起，sing-box 的 `mixed` 入站，
**同端口同时支持 SOCKS5 和 HTTP**）。Surge 只是消费它们的方式之一，而且是唯一一个
RouteBar 准备了现成配置格式的。任何能填代理地址的客户端都能直接用这些端口。

- **修复**：`surgeProfile` 缺失原来无条件产生一条健康警告，导致不用 Surge 的人
  永远顶着「需要处理」状态，且那条警告无论如何都消不掉。现在只在输出方式真的写
  Surge 配置时才提。
- 环境自检的「还差几项」不再把 Surge 那两项算进去（`expectsSurgeProfile`），
  「环境」页在不写配置的模式下也不再列出它们——事实判定不变，只是不计入待办。
- 首次引导第 5 步从「把订阅地址填进 Surge」改成「接上代理客户端」，说明两条路：
  Surge 用 policy-path，其它客户端直接填端口。
- README 重写开头与安装前置（Surge 从「必需」降为可选），新增「怎么用这些端口」一节，
  给出 `ALL_PROXY=socks5://127.0.0.1:7703 curl …` 这类直接用法，并说明节点命名模板
  只影响 Surge 那两种输出。

## v1.8.3

开源准备。

- 加上 **MIT License**。没有 LICENSE 的仓库法律上是「保留所有权利」，别人不能合法使用
  或分发——放到 GitHub 上也不算开源。
- 移除 `design-qa.md`：里面是设计走查记录，引用的是 `/Users/daniellau/.codex/…` 下的
  本地图片，对仓库外的人只是一串打不开的路径。
- `.gitignore` 补上 `.claude/settings.local.json`。

## v1.8.2

菜单栏面板右上角显示版本号，Debug 构建额外带一个 `DEBUG` 标记。

- 开发副本和已安装版本图标一模一样，两份同时跑着时认不出眼前这个菜单栏图标属于哪一份，
  「改了没生效」和「压根没在跑那一份」就分不开。
- 版本号相同也分得清：Debug 构建带标记。连构建类型都相同时，悬停版本号看 tooltip 里的
  bundle 路径。

## v1.8.1

面向开源发布的两处收拾：打包改用 ad-hoc 签名，最低系统版本从 26.3 降到 14.0。

- `package.sh` 打包前把签名换成 **ad-hoc**（`codesign -s -`），并在结果不是 adhoc 时
  直接报错退出。Xcode 默认用的开发证书里带着开发者的 Apple ID 邮箱，`codesign -dvvv`
  任何人都看得到——公开发布等于白送出去，而且发出去收不回来。证书还会过期。
  对用户没有区别：两种都没公证，都要放行一次。
- `MACOSX_DEPLOYMENT_TARGET` 26.3 → **14.0**（`LSMinimumSystemVersion` 随之变），
  `Package.swift` 的 platforms 同步到 `.v14`。**没有改动任何代码**：14.0 直接编译通过。
  再往下到 13.0 会卡在 `ContentUnavailableView`（7 处）和双参数 `onChange`（5 处），
  两者都是 macOS 14 才有的 SwiftUI API，要支持 Ventura 得自己实现替代视图。
- 打包输出补上最低系统版本与签名方式，README 的「发布」节说明为什么必须是 ad-hoc。

## v1.8.0

新增首次使用的分步引导，并给 README 补上面向使用者的安装与配置说明。

- 概览页顶部新增「开始使用」清单：安装 sing-box → 创建目录 → 安装 LaunchAgent →
  添加订阅 → 接上 Surge → 启动服务 →（建议）开机自启。每步只说「现在该做什么」，
  能代劳的都带按钮，必需项做完后整张卡片消失。
- 判定顺序放在 Domain 的 `SetupChecklist`，不写在视图里：概览页、README 和将来任何
  入口都该用同一套顺序，各写一遍必然漂移。
- 「Surge 那一步算不算做完」按输出方式分开判定——配置模式看托管配置在不在，
  订阅模式看本地服务有没有在监听。合成一句话会在两种模式下各错一次。
- 唯一 RouteBar 代劳不了的是装 sing-box，所以那一步直接给出可复制的
  `brew install sing-box`，并配一个「重新检测」（只重探二进制路径，不动其它设置）。
- 登录项状态收归 `AppModel.loginItemState`。原来设置页自己存一份 `@State`，
  在别处打开自启后它会继续显示「未开启」，直到那个视图碰巧重建。
- `surgePolicyGroupLine` 提到 `RouteBarSettings`，窗口与网页共用一份，不再各拼一遍。
- README 新增「安装」「首次配置」「RouteBar 和 sing-box 的分工」三节：说明本项目
  **没有做 Apple 公证**、下载版需要 `xattr -dr com.apple.quarantine` 或在系统设置里放行，
  以及为什么退出 RouteBar 后代理仍然正常（sing-box 归 launchd 管，不归 RouteBar 管）。

## v1.7.3

优化节点测速口径（见 `LatencyMeasurement`）。

## v1.7.2

关于页改用应用自己的图标（`NSApplication.applicationIconImage`），不再另挑一个 SF Symbol。
写死符号的话，换了图标之后这里会悄悄停在旧形象上，而没人会想起来回来改。

- 已知：图标是黑线条 + 透明背景，深色模式下关于页里的笔画对比很低（Dock 上同理）。
  这是图标资源本身的属性，要解决得给图标加底板并重新导出各尺寸。

## v1.7.1

换掉应用图标与菜单栏图标。

- AppIcon 补齐 16/32/128/256/512 五档的 1x 与 2x（共 10 个槽位，@2x 复用上一档的大图）。
- 菜单栏图标改用自带的 `MenuBarIcon` 模板图（18/36/54，灰度带 alpha，
  `template-rendering-intent` 为 template，跟随浅色/深色自动反色）。
- **菜单栏图标不再按状态换形状**：原来 running / stopped / needsAttention 各用一个
  SF Symbol，现在固定一个图形。状态仍可从图标点开的面板与主窗口看到。

## v1.7.0

输出给 Surge 的节点名不再写死成 `RouteBar 01 - …`，改成可配置的模板：全局一条，
每条订阅还可以各自覆盖。

- 模板占位符 `{index}`（两位序号）、`{name}`（机场给的节点名）、`{subscription}`
  （来源订阅名）、`{port}`（本机 SOCKS5 端口），见 `NodeNaming`。
- **默认模板逐字等于旧的写死值**，升级不改任何人已有的名字。老 `settings.json` /
  `state.json` 缺这两个新键时分别补默认模板和 nil——补成空串等于把所有人 Surge 策略组里
  存着的名字集体作废。
- 名字整批算而不是逐个算：`[Proxy]` 段以名字为键，重名的行只有最后一条生效、前面的
  静默消失，而不含 `{index}`/`{port}` 的模板必然撞车，所以自动补号只能在知道全部名字时做。
- 清洗（逗号、等号、引号、换行 → 空格）移到拼完之后：模板和订阅名同样是用户输入，
  只洗节点名挡不住把 `名字 = socks5, …` 这行拆坏。
- `GeneratedConfiguration` 带出 `policyNames`，策略组那一行直接用它。原来是从生成文本里
  挑 `RouteBar ` 开头的行反推——名字可配置之后那个前缀不再成立。
- sing-box 的 `in-routebar-01` / `out-routebar-01` **不受影响**：那是内部标签，只要求
  唯一稳定，掺进用户输入只会引入重名与非法字符。
- 只改了 Surge 那一侧时不再重启 sing-box（`installedSingBoxConfigMatches`）。改个名字
  顺手把全部连接断一次，是纯粹的浪费。
- 三个前端都能改：窗口「通用 → 节点命名」、网页的「节点命名」卡片、命令行
  `routebar naming`；单条订阅的覆盖在订阅编辑器里。
- **试跑**：填完模板点「测试」，逐个列出「原名 → 输出名」，看清楚再决定要不要生效。
  模板是即时生效的，存下去就等于把 Surge 里的名字全换一遍，所以试跑必须能不保存地做。
  网页与 CLI 走 `POST /api/naming/preview`（只算不存），`routebar naming --test <模板>`。
- **节点列表并排显示原名与输出名**（窗口、网页、`routebar nodes` 三处），详情栏也有
  「Surge 名称」一行——命名可配置之后两者可以毫无关系，在策略组里找不到某个节点时要对的是它。

## v1.6.1

节点列表显示上游协议，并修复 CLI 在遇到未启用节点时崩溃。

- 新增 `ProxyNode.protocolLabel`（`VLESS-Reality` / `VLESS`），窗口列表、详情栏、
  网页、命令行四处共用。详情栏原来写死 `"VLESS over TCP"`，写死的话它永远不会跟着
  解析器变。
- 今天它对每个节点都是同一个值，因为 `VLESSParser` 只认 VLESS Reality 链接——
  订阅里的 ss / trojan / vmess 会被**静默丢弃**。标出协议正是为了让「导入的节点比订阅里少」
  这件事有迹可循。
- **修复 `routebar nodes` 崩溃**：值为 nil 的可选字段会被 JSONEncoder 整个省略而非编成
  `null`，未启用的节点压根没有 `localPort` 键，下标取直接 KeyError。这条约定已写进
  `APICoding` 的文档注释，消费方需按「键可能不存在」处理。

## v1.6.0

Web 界面的订阅可以编辑了：名称、订阅地址、备注、更新间隔。

- **地址留空表示「保持不变」，不是「清空」。** 存下来的地址含机场凭据，只在钥匙串里，
  网页从不显示它——所以空值只能这么理解，否则每次改个名字都会把地址弄丢。
- 编辑器打开时暂停 8 秒一次的轮询。不停的话重绘会把填了一半的表单连同光标位置一起刷掉。
- 订阅行补上备注与更新间隔的显示，原来这两项在网页上看不到。

## v1.5.1

节点与订阅列表加上序号，三处（窗口、网页、命令行）指向同一个节点。

- **序号定义为「节点在完整列表（去重后按名称排序）中的位置」**，筛选或改排序时保留原号，
  会跳号但不重排。它是节点的编号，不是行号——这一页可以改排序，行号随之变化的话
  说「第 5 个」就没有意义了。
- 修复 CLI 的一处真 bug：`routebar nodes 韓國` 筛选后从 1 重排，而 `routebar test 1`
  按完整列表解析——显示的「1」和执行的「1」不是同一个节点。

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
