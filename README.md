# RouteBar

RouteBar 是一个 macOS SwiftUI 应用：拉取机场订阅、解析并去重 VLESS Reality 节点、
**为每个启用节点在本机开一个代理端口**（`127.0.0.1:7701` 起，同端口同时支持 SOCKS5 和 HTTP），
并保持这批端口与订阅同步。

谁来消费这些端口，由你决定。RouteBar 额外为 **Surge** 准备了现成的接法（改写配置或提供
订阅地址），但那只是其中一种——分流规则从来不由 RouteBar 决定，它只负责把可用出口准备好。

## 安装

需要先有这两样：

- **macOS 14 (Sonoma) 或更新**
- **sing-box**：`brew install sing-box`。RouteBar 不自带它，只调用它

> 最低版本卡在 14 的原因是 `ContentUnavailableView` 与双参数的 `onChange`，两者都是
> macOS 14 才有的 SwiftUI API。开发是在更新的系统上做的，14 只做过编译验证。

**Surge 不是必需的**。装了 Surge 可以用现成的两种接法，没装则把本机端口填进任何支持
SOCKS5 或 HTTP 代理的客户端——见下面的「怎么用这些端口」。

安装本体二选一。

**自己构建**（推荐）。仓库里没有任何私有依赖，克隆后直接构建即可，也不会遇到下面的
Gatekeeper 问题：

```sh
git clone https://github.com/daniellauyu/RouteBar.git && cd RouteBar
xcodebuild build -project RouteBar.xcodeproj -scheme RouteBar -destination 'platform=macOS'
```

**下载 Release**。包是 **ad-hoc 签名、没有经过 Apple 公证**的，从浏览器下载后会被
Gatekeeper 拦下（提示「无法打开，因为 Apple 无法检查其是否包含恶意软件」）。放行方式二选一：

```sh
# 拖进「应用程序」后，去掉下载隔离标记
xattr -dr com.apple.quarantine /Applications/RouteBar.app
```

或者双击被拦下后，去「系统设置 → 隐私与安全性」，在最下面点「仍要打开」。

> 这两步的含义是「我确认信任这个来源」。不放心的话就用上面的自己构建——源码全在这里。

## 首次配置

打开 RouteBar，**概览页顶部会出现一张「开始使用」清单**，按顺序做完即可，能代劳的都有按钮。
必需项全部完成后这张清单会自动消失。

| 步骤 | 做什么 | RouteBar 能不能代劳 |
|---|---|---|
| 1. 安装 sing-box | `brew install sing-box`，装完点「重新检测」 | ✗ 只能你自己装 |
| 2. 创建配置目录 | 点「创建目录」 | ✓ |
| 3. 安装 LaunchAgent | 点「去安装」，在「环境」页一键生成并加载 | ✓ |
| 4. 添加订阅 | 粘贴机场订阅地址（只存钥匙串） | — |
| 5. 接上代理客户端 | 见下一节 | 部分 |
| 6. 启动 sing-box | 点「启动服务」 | ✓ |
| 7.（建议）开机自启 | 点「打开」 | ✓ |

只解析 **VLESS Reality** 节点，订阅里的 ss / trojan / vmess 会被静默跳过，所以导入的节点
可能比机场给的少。节点页每行都标了上游协议。

## 怎么用这些端口

每个**启用**的节点占一个本机端口，从 `7701` 开始顺排（节点页每行都显示自己的端口）。
入站类型是 sing-box 的 `mixed`，**同一个端口同时接受 SOCKS5 和 HTTP 代理**，只监听
`127.0.0.1`。所以有三种用法：

**一、任何支持代理的客户端**（不需要 Surge）。把地址填进去就行：

```sh
# 终端：让这一条命令走第 3 个节点
ALL_PROXY=socks5://127.0.0.1:7703 curl https://example.com

# 或者 HTTP 代理，同一个端口
https_proxy=http://127.0.0.1:7703 curl https://example.com
```

浏览器插件（SwitchyOmega 之类）、Proxifier、各种下载工具、以及 Clash/Mihomo、Loon、
Quantumult X 这些能把外部 SOCKS5 当作节点的客户端，都填 `127.0.0.1:<端口>` 即可。
自己写规则分流也是在那些客户端里做，RouteBar 不参与。

**二、Surge：本地订阅地址**（默认方式）。RouteBar 起一个本地 HTTP 服务，把整批端口
按 Surge 的策略集格式吐出来，Surge 用 `policy-path=` 拉取。完全不碰配置文件，可与
sub.store 等外部订阅共存：

```
🔰 RouteBar = select, policy-path=http://127.0.0.1:7899/<令牌>/proxies, update-interval=0
```

**三、Surge：直接写配置**。需要先有一份含 `[Proxy]` 与 `[Proxy Group]` 两个段的配置，
在「环境」页把路径指过去。RouteBar 只改写 `[Proxy]` 段和「sing-box 节点」策略组，
规则与其它策略组原样保留——但**该段是整段替换的**，里面除 RouteBar 之外的代理会消失。

后两种是为 Surge 的配置语法准备的现成接法（`名字 = socks5, 127.0.0.1, 端口`）。
换成别的客户端时它们没有意义，选「本地订阅地址」并忽略那个地址即可，或者直接用第一种。

### RouteBar 和 sing-box 的分工

这一点最容易误解：**RouteBar 不运行 sing-box**，它只写配置、并通过 `launchctl` 指挥。
真正持有 sing-box 进程的是 macOS 的 launchd。

```
你的代理客户端 ──▶ 127.0.0.1:7701… (sing-box) ──▶ Reality 出口
（Surge / Clash / 浏览器插件 / curl …）    ▲
                                          └── RouteBar 只在旁边写配置：
                                              sing-box.json、LaunchAgent plist、
                                              以及（可选）Surge 那一侧
```

因此：

- **退出 RouteBar，代理不会断。** plist 里写了 `RunAtLoad` 与 `KeepAlive`，sing-box
  开机自启、崩溃自愈，与 RouteBar 是否运行无关。
- 手动 `kill` sing-box 也没用，launchd 会立刻拉起来。要真停，用 RouteBar 的「停止服务」
  （走 `launchctl bootout`）。
- RouteBar 没运行时，少掉的是这四件事：订阅自动更新、测速、Web/命令行界面，以及
  **本地订阅端口**——用 Surge 订阅方式时它拉不到新节点（旧的仍在用缓存）。
  这就是建议打开开机自启的原因。**直接填端口的用法完全不受影响**：那些端口属于
  sing-box，RouteBar 关着也照常工作。

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

打包时会把签名换成 **ad-hoc**（`codesign -s -`），并在不是 ad-hoc 时直接报错退出。
原因是 Xcode 默认用开发证书签名，而证书里带着开发者的 Apple ID 邮箱——拿到包的人跑一次
`codesign -dvvv` 就能看到，公开发布等于白送出去，而且发出去就收不回来。证书还会过期。
两种签名对用户没有区别：都没有经过公证，都要放行一次。

`dist/` 已被 git 忽略——包是构建产物，不是源码。

## 运行时依赖

RouteBar 不自带 sing-box，也不接管 Surge 的安装。以下路径都是设置项，在应用的「环境」页配置：

- sing-box 可执行文件（默认 `/opt/homebrew/bin/sing-box`）
- sing-box 配置与日志（默认 `~/.config/sing-box/`）
- Surge 托管配置（**仅在选「写入 Surge 配置」时需要**，且必须已存在、含 `[Proxy]` 与 `[Proxy Group]` 段）
- LaunchAgent plist 与 Label（由你自己安装，决定 sing-box 如何被 launchd 拉起）

订阅地址存放在钥匙串，不写入任何配置文件。覆盖 sing-box 与 Surge 配置前都会留一份
`.routebar-backup`；新配置先经 `sing-box check` 校验，通过后才替换正式文件。

## 节点命名

这些出口在 Surge 里叫什么，由一份模板决定（「通用 → 节点命名」，也可用网页的
「节点命名」卡片或 `routebar naming`）。**只影响 Surge 那两种输出**——直接填端口用的人
不需要关心名字，端口号才是标识：

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
