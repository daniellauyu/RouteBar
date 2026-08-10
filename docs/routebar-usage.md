# 日常使用与排查

安装、首次配置、以及「怎么用这些端口」在 [README](../README.md) 里。这一篇讲装好之后的事：
东西都放在哪、出问题从哪查、以及怎么彻底卸掉。

## 文件都在哪

RouteBar 只往四个地方写东西，全部在你的用户目录下，没有任何系统级安装。

| 位置 | 内容 | 谁写的 |
|---|---|---|
| `~/Library/Application Support/RouteBar/state.json` | 订阅元数据与节点（**不含订阅地址**） | RouteBar |
| `~/Library/Application Support/RouteBar/settings.json` | 路径、输出方式、订阅端口与令牌、节点命名模板 | RouteBar |
| `~/Library/Application Support/RouteBar/sing-box.json`<br>`~/…/surge-proxies.conf` | 最近一次生成结果的副本，用来对照「装进去的到底是什么」 | RouteBar |
| `~/Library/Application Support/RouteBar/bin/sing-box` | 只在**没有 Homebrew**、由「一键完成」下载安装时才有。有 brew 的机器上这个目录不存在 | RouteBar 下载 |
| `~/.config/sing-box/surge-vless.json` | 真正在跑的 sing-box 配置 | RouteBar 生成，sing-box 读取 |
| `~/.config/sing-box/surge-vless{,-error}.log` | sing-box 自己的输出 | sing-box |
| `~/Library/LaunchAgents/<Label>.plist` | 让 launchd 拉起 sing-box | RouteBar 生成，launchd 读取 |
| 钥匙串，服务名 `com.liuyude.RouteBar.subscriptions` | **订阅地址**（含机场凭据） | RouteBar |

上面除最后一行外的路径都能在「环境」页改，默认值随 bundle identifier 派生。

两条与安全有关的约定：

- **订阅地址只进钥匙串**，不进 `state.json`。那份文件会被 Time Machine 备份、被同步、
  被随手打开看，而订阅 URL 里的 token 等价于账号密码。
- 覆盖 sing-box 配置、Surge 配置或 LaunchAgent 之前，原文件都会留一份同名的
  **`.routebar-backup`**。想手工回滚就去找它。

`update.log` 在 v1.1.0 之后不再产生（运行日志改为内存缓冲 + 系统统一日志）。
如果你的目录里还有一个，那是旧版本留下的，可以直接删。

## 三个入口做的是同一件事

窗口、网页（`http://127.0.0.1:<端口>/<令牌>/`）、命令行 `scripts/routebar` 调用的是
**同一组方法**，所以行为不会分叉——包括改动后 500ms 合并重装、测速用哪个端点。
挑手边顺的那个用即可，具体命令见 README 的「命令行」一节。

网页与命令行都依赖本地服务，因此要求「通用 → 输出到 Surge」选了包含订阅地址的方式，
且 RouteBar 正在运行。

## 排查

先看概览页的**自检**区：能自动判断出来的问题都列在那里。下面按症状给出更细的路径。

### 装不上 sing-box：没有 Homebrew，也到不了 GitHub

这不是边缘情况，而是这个应用最典型的处境——装它就是因为直连不通，而配好之前一个可用
出口都没有。「一键完成」的两条自动路径（brew、GitHub Release）此时都会失败，失败信息里
会给出下面这套步骤，**从另一台已经装好的 Mac 上拷一份过来**：

```sh
# 在已经装好的那台机器上，找到它
which sing-box                       # 通常是 /opt/homebrew/bin/sing-box

# 用 AirDrop / U 盘 / scp 传到这台机器之后，在这台机器上：
mkdir -p ~/Library/Application\ Support/RouteBar/bin
mv ~/Downloads/sing-box ~/Library/Application\ Support/RouteBar/bin/
chmod +x ~/Library/Application\ Support/RouteBar/bin/sing-box
xattr -dr com.apple.quarantine ~/Library/Application\ Support/RouteBar/bin/sing-box
```

然后回到「环境」页，把「sing-box 可执行文件」改成这个路径并保存。

**这一步不能用「重新检测」代替**：那颗按钮只认 Homebrew 与系统的几个固定前缀
（`/opt/homebrew/bin`、`/usr/local/bin`、`/usr/bin`），找不到上面这个位置的文件。

两台机器的芯片要一致：Apple 芯片上拷来的二进制在 Intel Mac 上跑不了，反之亦然。
放进 `Application Support/RouteBar/bin/` 的好处是卸载 RouteBar 时会跟着一起删掉；
放别处也行，路径填对即可。

> 为什么不加个国内镜像自动下载：sing-box 的 Release 不提供官方 checksum，二进制本身
> 只有 ad-hoc 签名（没有 Developer ID 可以钉），所以从第三方加速站拿到的东西**没有办法
> 验真**。而这是要看你全部流量的代理内核，被掉包的后果比装不上严重得多。

### 代理连不上，但 RouteBar 显示一切正常

按链路顺序排除，**从最外面开始**：

1. **是不是客户端没指对端口。** 节点页每行都写着自己的本地端口。直接验一下：
   ```sh
   curl -x socks5h://127.0.0.1:7701 -sS -o /dev/null -w '%{http_code}\n' https://www.gstatic.com/generate_204
   ```
   返回 `204` 说明这个节点本身通，问题在客户端配置。**注意是 `socks5h` 不是 `socks5`**，
   见下一条。
2. **sing-box 在跑吗**：`launchctl print gui/$(id -u)/<Label> | grep state`，或看「服务」页。
3. **节点本身失效**：节点页点「测试全部」。整批全红多半是订阅过期或机场出问题，
   个别红是那个节点的事。
4. **看 sing-box 的错误日志**（「服务」页，或 `~/.config/sing-box/surge-vless-error.log`）。
   握手失败、Reality 参数不对都会写在这里。

### 代理能连，但某些网站打不开

多半是**域名在本机解析**的。SOCKS5 有两种用法：`socks5` 由客户端解析域名再把 IP 交给代理，
`socks5h` 把域名原样交给代理去解析。前者拿到的是本地 DNS 的答案，被污染的域名会连到
错误的地址上，表现为握手失败或连上了打不开。

- curl / 环境变量：写 `socks5h://127.0.0.1:<端口>`。
- 客户端里有「远程解析 DNS」「Proxy DNS」之类的开关：打开它。
- HTTP 代理方式没有这个问题，域名本来就交给代理解析。

同一个端口两种协议都收，实在拿不准就先用 HTTP 代理试一次，能通就说明是 DNS 的事。

### 节点比订阅里少

**预期行为**：只解析 VLESS Reality 链接，ss / trojan / vmess 会被静默跳过。
另外多个订阅里的同一节点（按服务器 + 端口 + UUID + 公钥 + shortID 的指纹判断）会合并成一个，
概览页的「去重」指标显示合并掉了多少。

### Surge 里看不到节点 / 还是旧的

- **用订阅地址方式**：Surge 会缓存上一次拉到的列表。RouteBar 没运行时那个端口是关的，
  Surge 拉不到新的但旧的仍能用。确认 RouteBar 在跑，然后在 Surge 里手动刷新策略集。
- **用写入配置方式**：确认「环境」页的 Surge 配置路径指对了，且那份配置**正在被 Surge 使用**
  （改错一份没在用的配置是最常见的情况）。
- **名字全变了**：检查是不是改过节点命名模板。策略组里手工引用过旧名字的地方需要一并更新，
  见 README 的「节点命名」。

### 服务起不来

- **配置校验失败**：安装前会先跑 `sing-box check`，失败时正式配置一个字节都不会动。
  错误内容在运行日志里。可以自己复现：
  ```sh
  sing-box check -c ~/.config/sing-box/surge-vless.json
  ```
- **LaunchAgent 不对**：「环境」页会显示它是缺失、过期、还是别人创建的。三种都有对应按钮。
- **plist 在但 launchd 不认**（报 `Could not find service "..." in domain for user gui: 501`）：
  文件还在 `~/Library/LaunchAgents/`，只是这个登录会话没把它加载进来。点「启动」即可——
  RouteBar 会自己 `launchctl bootstrap` 一次再拉起服务，不需要去终端敲命令。
- **改了路径但没重新生成 plist**：plist 里的二进制与配置路径是生成时写死的，
  改完设置要在「环境」页重新生成一次。

### 本地服务起不来（网页和命令行连不上）

最常见的是**端口被占用**，此时「服务」页会直接显示「端口 7899 已被占用，请在设置里换一个」。
查是谁占着：

```sh
lsof -nP -iTCP:7899 -sTCP:LISTEN
```

如果占用者也是 RouteBar，说明**同时跑了两个实例**（比如 Xcode 里一个、`/Applications` 里一个）。
菜单栏面板右上角的版本号与 `DEBUG` 标记可以区分它们，悬停还能看到各自的 bundle 路径。

### 所有节点测速都失败，但 Surge 里同样的节点是通的

先看失败得有多快：**整批在一秒内全变红**基本不是节点的问题——真的连不上会各自等到超时。
按 v1.10.2 之前的版本，最常见的原因是 App Transport Security 拦掉了明文的测速端点
（默认的 `http://www.gstatic.com/generate_204` 就是明文），URLSession 直接返回 -1022，
界面上只显示成「连接失败」。升级到 1.10.2 即可，或在设置里换成 `https://` 的端点。

要确认是不是这一类，看系统日志里的原始错误码：

```sh
log show --last 10m --predicate 'subsystem BEGINSWITH "com.liuyude.RouteBar"' | grep 测速
```

节点本身能不能用，可以拿本机端口直接验（端口号在「节点」页每一行上）：

```sh
curl -x socks5h://127.0.0.1:7701 -o /dev/null -w '%{http_code} %{time_total}\n' \
    http://www.gstatic.com/generate_204
```

这条通、而 RouteBar 里显示失败，说明问题在 RouteBar 一侧而不是节点。

### 测速数字看着不对

- 测的是 **Surge/客户端 → 本地 sing-box → Reality 节点 → 测试站点**的端到端往返，
  天然包含多段握手，**不能套用直连节点常见的 100/200 ms 阈值**。RouteBar 用的分档是
  600 / 1000 ms。
- 换测速端点后所有数字会整体平移，**不要和换之前的比**。运行日志会记录每次用了哪个端点。
- 测速要经本地端口，所以 sing-box 必须在跑。

### 想看更早的日志

应用内的运行日志只保留最近 1000 条且重启清空，但同一批事件会镜像到系统统一日志：

```sh
log show --last 2h --predicate 'subsystem BEGINSWITH "com.liuyude.RouteBar"'
```

## 完全卸载

RouteBar 没有安装器，也就没有卸载器。四步清干净：

```sh
# 1. 停掉并卸载 sing-box 服务（Label 见「环境」页，默认由 bundle id 派生）
LABEL="com.liuyude.RouteBar.sing-box"
launchctl bootout "gui/$(id -u)/$LABEL"
rm -f ~/Library/LaunchAgents/"$LABEL".plist

# 2. 删掉应用数据（订阅元数据、节点、设置、生成副本，以及一键下载的那份 sing-box）
rm -rf ~/Library/Application\ Support/RouteBar

# 3. 删掉钥匙串里的订阅地址（每条订阅一条，重复执行到报「找不到」为止）
security delete-generic-password -s com.liuyude.RouteBar.subscriptions

# 4. 删掉应用本身
rm -rf /Applications/RouteBar.app
```

`~/.config/sing-box/` 下的配置与日志是给 sing-box 用的，按需自行删除；
sing-box 本体用 `brew uninstall sing-box` 卸载——如果它是「一键完成」在没有 brew 的机器上
下载的，第 2 步已经连它一起删掉了（「环境」页的 sing-box 路径指到
`Application Support/RouteBar/bin/` 就是这种情况）。Surge 那边：用订阅地址方式的话，
把策略组里那行 `policy-path=` 删掉即可；用写入配置方式的话，`[Proxy]` 段里的
RouteBar 代理需要手工清理，同目录下的 `.routebar-backup` 是覆盖前的原始版本。
