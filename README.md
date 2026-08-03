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

## 节点命名

这些出口在 Surge 里叫什么，由一份模板决定（「通用 → 节点命名」，也可用网页的
「节点命名」卡片或 `routebar naming`）：

| 占位符 | 含义 |
|---|---|
| `{index}` | 两位序号，从 01 起（就是本地端口的顺序） |
| `{name}` | 机场给的节点名 |
| `{subscription}` | 来源订阅名 |
| `{port}` | 本机 SOCKS5 端口 |

默认是 `RouteBar {index} - {name}`，与 1.6.1 及以前写死的名字逐字相同——升级不会改动
任何已有的名字。**改模板会重命名 Surge 里的全部出口**，策略组里手工引用过旧名字的地方
需要一并更新。

改之前先**试跑**：填完模板点「测试」（网页同名按钮、命令行 `routebar naming --test '<模板>'`），
会逐个列出「原名 → 输出名」，确认无误再保存。试跑只算不存，不碰正在用的配置。
节点列表和详情栏也并排显示这两个名字，随时能对上「机场给的名字」和「Surge 里看到的名字」。

单条订阅可以在订阅编辑器里另设模板（留空跟随全局），例如让两个机场的节点在策略组里
一眼可分：

```
A机场 {index} · {name}
{subscription}-{index}
```

几条约束：

- 名字里的逗号、等号、引号、换行会被替换成空格——它们在 Surge 配置里是语法字符，
  留着会把 `名字 = socks5, 127.0.0.1, 端口` 这一行拆坏。清洗对拼好的整串生效，
  因为模板和订阅名同样是用户输入。
- 模板不含 `{index}` / `{port}` 时同名节点会撞车。`[Proxy]` 段以名字为键，重名的行
  只有最后一条生效，其余静默消失，所以 RouteBar 会给重复的名字自动补序号。
- 一个节点同时来自多条订阅时，按订阅列表里靠前的那条来命名。
- sing-box 配置里的 `in-routebar-01` / `out-routebar-01` 不受影响：那是内部标签，
  入站与出站靠它们一一绑定，只要求唯一且稳定。

## 本地服务：订阅地址与 Web 界面

「通用 → 输出到 Surge」选择包含订阅地址的方式后，RouteBar 会在 `127.0.0.1` 上起一个
本地 HTTP 服务，同端口同令牌提供两样东西：

| 地址 | 给谁用 |
|---|---|
| `http://127.0.0.1:<端口>/<令牌>/proxies` | Surge 的 `policy-path=`，返回裸策略行 |
| `http://127.0.0.1:<端口>/<令牌>/` | 浏览器，一个不必打开 Mac 窗口就能操作的界面 |

Surge 侧的写法与外部订阅（sub.store 之类）完全一致，因此两者可以并存：

```
🔰 RouteBar = select, policy-path=http://127.0.0.1:7899/<令牌>/proxies, update-interval=0
```

Web 界面能做的事和窗口一样：增删订阅、启停节点、测速、起停 sing-box、重新生成配置。
它调用的是与 SwiftUI 界面**完全相同的一组方法**（`RouteBarAPIHost`），所以两边的行为
——包括改动后 500ms 合并重装、测速端点取自设置——不可能分叉。

约束与边界：

- **只绑定 `127.0.0.1`**（`requiredLocalEndpoint`，不是监听全部接口再过滤），局域网访问不通。
- 路径里的令牌即凭据，与订阅地址共用；不匹配一律 404，不返回 403——403 等于确认
  「这个端口上确实有 RouteBar」。
- 校验 `Host` 头必须是回环地址且端口相符。绑定地址挡不住 DNS rebinding：
  攻击者把自己域名解到 `127.0.0.1`，浏览器就会以该域名为 Origin 发请求且认为同源可读。
- 写操作要求 `Content-Type: application/json`。服务不返回任何 CORS 头，因此跨源的
  预检必然失败；没有这一条，恶意页面能用表单发出简单 POST——读不到响应，但副作用已经产生。
- 响应体里没有任何凭据：节点只给名称、主机、本地端口与延迟，VLESS UUID 与 Reality
  公钥留在 sing-box 配置里，订阅地址留在钥匙串。
- **只在 RouteBar 运行时可访问。** Surge 会缓存上一次拉到的列表，所以进程没开不会立刻断，
  但拿不到新节点。要长期可靠，在「通用 → 启动」里打开登录自启。

## 命令行

`scripts/routebar` 是同一套 API 的命令行客户端，只依赖 Python 3 标准库。
端口与令牌从 `settings.json` 读，不需要另外配置：

```bash
ln -s "$PWD/scripts/routebar" /usr/local/bin/routebar   # 装到 PATH 上（可选）

routebar                    # 等同 status
routebar nodes 韓國         # 按关键词筛节点，列出序号/端口/延迟
routebar test 5             # 测速，可用序号、完整名或名字的一部分
routebar off 5              # 停用节点（配置会在 0.5 秒后合并重装）
routebar update             # 更新全部订阅
routebar naming             # 看节点名模板；带参数就是改（routebar naming '{subscription} {index}'）
routebar url | pbcopy       # 订阅地址
routebar surge              # 可直接粘进 Surge 的策略组行
routebar web                # 浏览器打开 Web 界面
```

`routebar help` 列出全部命令。名字匹配到多个时会把候选列出来要求说得更具体，
不会猜一个执行。检测到输出被重定向（或设了 `NO_COLOR`）时自动去掉颜色。

## 日志

- **运行日志**页：RouteBar 自身的诊断记录（内存保留最近 1000 条，重启清空），
  同时镜像到统一日志，更早的记录可用
  `log show --predicate 'subsystem BEGINSWITH "com.liuyude.RouteBar"'` 查看。
- **服务**页：sing-box 进程自己写的标准日志与错误日志文件。

排查顺序：先看服务页的错误日志有没有配置解析或 Reality 握手报错，再回运行日志看
RouteBar 这边做了什么。
