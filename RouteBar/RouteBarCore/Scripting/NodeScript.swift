import Foundation
import JavaScriptCore

/// 交给脚本的一个节点。
///
/// 字段比 Surge 那一行能看到的多：`type` 是**真实上游协议**（Surge 只知道这是个 socks5），
/// `region` 是 RouteBar 按地区表已经认好的结果。多给这些是为了让脚本不必自己重写一遍
/// 协议解析和地区识别——那两件事 RouteBar 本来就做过了，让脚本重做一遍只会多一处出错的地方。
public struct NodeScriptProxy: Sendable, Equatable {
    /// 机场给的原始名。
    public var name: String
    /// 上游协议：vless / trojan / ss / vmess / hysteria2。
    public var type: String
    public var server: String
    public var port: Int
    /// RouteBar 分配的本机 SOCKS5 端口。**脚本必须把它原样带回来**——它是这条记录与
    /// 真实出口之间唯一的绑定，丢了就没法把名字放回到正确的端口上。
    public var localPort: Int
    /// 来源订阅名。节点没有来源时是空串。
    public var source: String
    /// 来源订阅在列表里的位置，0 起。
    public var sourceIndex: Int
    public var sourceUpdatedAt: Date?
    /// RouteBar 按地区表认出的地区，认不出是「小众」。
    public var region: String
    /// 最近一次测速的毫秒数，没测过是 nil。
    public var latencyMilliseconds: Int?

    public nonisolated init(name: String, type: String, server: String, port: Int, localPort: Int,
                            source: String, sourceIndex: Int, sourceUpdatedAt: Date?,
                            region: String, latencyMilliseconds: Int?) {
        self.name = name
        self.type = type
        self.server = server
        self.port = port
        self.localPort = localPort
        self.source = source
        self.sourceIndex = sourceIndex
        self.sourceUpdatedAt = sourceUpdatedAt
        self.region = region
        self.latencyMilliseconds = latencyMilliseconds
    }

    nonisolated var jsObject: [String: Any] {
        var object: [String: Any] = [
            "name": name, "type": type, "server": server, "port": port,
            "localPort": localPort, "source": source, "sourceIndex": sourceIndex,
            "region": region,
        ]
        // 取不到的值给 NSNull 而不是干脆不放这个键：`p.latency === null` 是能判的，
        // 而 `'latency' in p` 为假时脚本作者通常想不到要去判。
        object["sourceUpdatedAt"] = sourceUpdatedAt.map(NodeScript.iso8601) ?? NSNull()
        object["latency"] = latencyMilliseconds ?? NSNull()
        return object
    }
}

/// 脚本跑完之后的产物。
public struct NodeScriptResult: Sendable {
    /// 直接可以交给 `ConfigurationGenerator` 铺策略行的规划。
    public let plan: NormalizationPlan
    /// 脚本里 `console.log/warn/error` 打出来的东西，按顺序。
    public let logs: [String]
    /// 不致命但值得说一声的问题：重名被补了后缀、某些端口脚本没带回来。
    public let warnings: [String]
    public let duration: TimeInterval

    public nonisolated init(plan: NormalizationPlan, logs: [String],
                            warnings: [String], duration: TimeInterval) {
        self.plan = plan
        self.logs = logs
        self.warnings = warnings
        self.duration = duration
    }
}

public enum NodeScriptError: Error, LocalizedError, Equatable {
    case empty
    /// 脚本本身没跑起来（语法错、顶层抛错）。带 JS 报的位置。
    case evaluation(String)
    /// 没定义 operator 函数。
    case missingOperator
    /// operator 内部抛出来的。
    case thrown(String)
    case timedOut(TimeInterval)
    /// 返回值不是数组。
    case notAnArray(String)
    /// 某一项缺 name 或 localPort，或者 localPort 不在输入里。
    case badEntry(String)
    /// 微任务排干了但 operator 还没给出结果——沙箱里没有网络和定时器，正常不该发生。
    case didNotSettle

    public var errorDescription: String? {
        switch self {
        case .empty: "脚本是空的"
        case .evaluation(let detail): "脚本没能加载：\(detail)"
        case .missingOperator: "脚本里没有定义 operator 函数"
        case .thrown(let detail): "operator 抛出异常：\(detail)"
        case .timedOut(let limit): "脚本超过 \(String(format: "%.1f", limit)) 秒还没跑完，已中断"
        case .notAnArray(let kind): "operator 要返回数组，实际返回的是 \(kind)"
        case .badEntry(let detail): "返回的条目有问题：\(detail)"
        case .didNotSettle: "operator 没有给出结果。沙箱里没有网络和定时器，它不应该等待外部输入"
        }
    }
}

/// 跑用户写的 `operator` 脚本，把一批节点重命名、过滤、重排。
///
/// 为什么值得内置一个 JS 引擎：地区表那种数据化的配置只能覆盖「地区怎么认」这一层，
/// 而「按来源+地区分别编号」「订阅信息归类排序」「合成一条入口」这些是流程，
/// 配置化下去会一路长成一个残缺的解释器——不如直接给一个完整的。
///
/// 沙箱是 `JSContext` 自带的：裸上下文里没有 `fetch`、`XMLHttpRequest`、`setTimeout`、
/// `require`、`process`，只有 ECMAScript 内置对象。所以脚本碰不到网络、文件和时钟，
/// 唯一要防的是算力——死循环由执行时限兜。
public enum NodeScript {
    /// 默认时限。纯字符串计算，几百个节点远用不到这个数；给到 2 秒是留给
    /// 写得很糙的正则回溯，而不是留给等待。
    public nonisolated static let defaultTimeout: TimeInterval = 2

    /// 收多少行 `console` 输出。
    ///
    /// 脚本里不小心在循环里打一行日志，几百个节点就是几百行；再多的话网页那边渲染会卡，
    /// 而且前几十行通常已经说明问题了。
    public nonisolated static let logLimit = 200

    /// 新建脚本时给的骨架。照着它改比对着空白框想象要快得多。
    public nonisolated static let template = """
    // 每次生成 Surge 策略列表时都会跑一遍。
    //
    // proxies: 数组，每项 { name, type, server, port, localPort, source,
    //                      sourceIndex, sourceUpdatedAt, region, latency }
    //   name       机场原始名        type     真实协议 vless/trojan/ss/vmess/hysteria2
    //   localPort  本机 SOCKS5 端口   region   RouteBar 已认好的地区
    //   latency    最近一次测速毫秒，没测过是 null
    //   sourceUpdatedAt  来源订阅上次更新成功的时刻，**UTC 的 ISO 串**。
    //                    想显示本地时间要走 new Date(...)，直接 slice 会差几个时区
    //
    // 返回：数组，每项至少要有 name 和 localPort。localPort 必须来自入参，
    //       它是名字与真实出口之间唯一的绑定。顺序即 Surge 里的顺序。
    //       不返回的节点就不会出现在 Surge 里。
    //
    // 可以用 console.log 打日志，会显示在下面。

    async function operator(proxies, targetPlatform, context) {
      const counter = {};
      return proxies.map((p) => {
        const key = p.source + p.region;
        counter[key] = (counter[key] || 0) + 1;
        const index = String(counter[key]).padStart(2, '0');
        return { ...p, name: `【${p.source}】${p.region}${index}` };
      });
    }
    """

    nonisolated static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// 跑一遍脚本。
    ///
    /// 同步执行，调用方负责别在主线程上跑大批节点。返回的 `plan` 与 `proxies` **逐位对齐**，
    /// 和 `NodeNormalization.plan` 的契约一致，所以两条路径对 `ConfigurationGenerator`
    /// 来说没有区别。
    public nonisolated static func run(script: String,
                                       proxies: [NodeScriptProxy],
                                       targetPlatform: String = "Surge",
                                       timeout: TimeInterval = defaultTimeout) throws -> NodeScriptResult {
        let source = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw NodeScriptError.empty }

        let started = Date()
        guard let context = JSContext() else { throw NodeScriptError.evaluation("无法创建 JS 上下文") }
        let collector = LogCollector()
        install(console: collector, in: context)
        applyTimeLimit(timeout, to: context)

        // 脚本原文放在最前面，后面才是驱动代码——这样 JS 报的行号与用户看到的行号一致。
        context.setObject(proxies.map(\.jsObject), forKeyedSubscript: "__rb_proxies" as NSString)
        context.setObject(targetPlatform, forKeyedSubscript: "__rb_platform" as NSString)
        context.setObject([String: Any](), forKeyedSubscript: "__rb_context" as NSString)

        var thrown: JSValue?
        context.exceptionHandler = { _, exception in thrown = exception }
        context.evaluateScript(source + "\n" + driver)

        if let thrown {
            let text = describe(thrown)
            // 时限到了之后 JSC 也走异常这条路，靠耗时区分：脚本自己抛错是立刻返回的。
            if Date().timeIntervalSince(started) >= timeout { throw NodeScriptError.timedOut(timeout) }
            throw NodeScriptError.evaluation(text)
        }

        guard bool(context, "__rb_done") else { throw NodeScriptError.didNotSettle }
        if let message = string(context, "__rb_err") {
            throw message == missingOperatorMarker
                ? NodeScriptError.missingOperator
                : NodeScriptError.thrown(message)
        }

        let output = context.objectForKeyedSubscript("__rb_out")
        let plan = try plan(from: output, proxies: proxies, collector: collector)
        return NodeScriptResult(plan: plan, logs: collector.logs,
                                warnings: collector.warnings, duration: Date().timeIntervalSince(started))
    }
}

// MARK: - 驱动与沙箱

extension NodeScript {
    /// 没定义 operator 时约定的标记，用它把这种情况和真正的抛错分开。
    fileprivate nonisolated static let missingOperatorMarker = "__RB_NO_OPERATOR__"

    /// 接在用户脚本后面的驱动代码。
    ///
    /// 必须放在**后面**：JS 报的行号是从整段文本头部算的，用户脚本在前，报出来的行号
    /// 才和他在编辑器里看到的一致。前面那个分号是防用户脚本最后一行没写分号时粘连。
    ///
    /// 用 `Promise.resolve(...)` 包一层是为了同时吃下 `async function` 和普通函数——
    /// 两种写法都常见，要求用户必须写 async 只会平添一类「为什么我的脚本没生效」。
    fileprivate nonisolated static let driver = """
    ;(function () {
      globalThis.__rb_done = false;
      globalThis.__rb_out = null;
      globalThis.__rb_err = null;
      if (typeof operator !== 'function') {
        __rb_err = '\(missingOperatorMarker)'; __rb_done = true; return;
      }
      try {
        Promise.resolve(operator(__rb_proxies, __rb_platform, __rb_context))
          .then(function (value) { __rb_out = value; __rb_done = true; })
          .catch(function (error) { __rb_err = __rb_describe(error); __rb_done = true; });
      } catch (error) {
        __rb_err = __rb_describe(error); __rb_done = true;
      }
    })();
    """

    /// 收集脚本打出来的东西。
    ///
    /// 只在跑脚本的那个线程上被碰：`evaluateScript` 是同步的，`console.log` 的回调
    /// 也在同一个栈里执行，跑完才读。没有跨线程访问，所以不加锁。
    fileprivate final class LogCollector: @unchecked Sendable {
        var logs: [String] = []
        var warnings: [String] = []

        static let limit = NodeScript.logLimit

        func append(_ level: String, _ message: String) {
            guard logs.count < Self.limit else {
                if logs.count == Self.limit { logs.append("…日志超过 \(Self.limit) 行，后面的省略了") }
                return
            }
            logs.append(level.isEmpty ? message : "[\(level)] \(message)")
        }
    }

    /// 把 `console` 换成往 Swift 这边送的版本。
    ///
    /// 裸 `JSContext` 自带的 `console.log` 写到进程的 stderr——对一个菜单栏应用等于扔了。
    /// 脚本调不通时最想看的就是它打了什么，所以必须收回来。
    fileprivate nonisolated static func install(console collector: LogCollector, in context: JSContext) {
        let sink: @convention(block) (String, String) -> Void = { [weak collector] level, message in
            collector?.append(level, message)
        }
        context.setObject(sink, forKeyedSubscript: "__rb_log" as NSString)
        // 参数拼接放在 JS 里做：Swift 侧拿不到 JS 的可变参数，而对象要转成
        // 人能看的文本，JSON.stringify 比 String() 有用得多。
        context.evaluateScript("""
        globalThis.__rb_text = function (value) {
          if (typeof value === 'string') return value;
          if (value instanceof Error) return String(value.stack || value);
          try { return JSON.stringify(value); } catch (e) { return String(value); }
        };
        /* JSC 的 error.stack 只有调用帧，不像 V8 那样以 "Error: 消息" 开头——
           只取 stack 会把最关键的那句消息丢掉。两个都要。 */
        globalThis.__rb_describe = function (error) {
          var text = String(error);
          if (error && error.stack) text += '\\n' + String(error.stack);
          return text;
        };
        globalThis.console = ['log', 'info', 'warn', 'error', 'debug'].reduce(function (out, level) {
          out[level] = function () {
            __rb_log(level === 'log' ? '' : level,
                     Array.prototype.map.call(arguments, __rb_text).join(' '));
          };
          return out;
        }, {});
        """)
    }

    /// 给上下文装执行时限，防死循环。
    ///
    /// `JSContextGroupSetExecutionTimeLimit` 只在 JSContextRefPrivate.h 里，不是公开 API，
    /// 所以走 `dlsym` 取。取不到就跳过——那种情况下写出死循环的脚本会一直占着一个核，
    /// 但这是系统更新拿掉符号才会发生的事，宁可少一层保护也不要整个功能用不了。
    ///
    /// 为什么非要这个 SPI：JS 是同步跑完的，外面没有任何办法从别的线程打断它。
    /// 换成「另起线程 + 超时不等了」的话，那个线程会永远转下去。
    fileprivate nonisolated static func applyTimeLimit(_ timeout: TimeInterval, to context: JSContext) {
        typealias SetLimit = @convention(c) (
            JSContextGroupRef, Double,
            (@convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool)?,
            UnsafeMutableRawPointer?) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "JSContextGroupSetExecutionTimeLimit"),
              let group = JSContextGetGroup(context.jsGlobalContextRef) else { return }
        unsafeBitCast(symbol, to: SetLimit.self)(group, timeout, { _, _ in true }, nil)
    }

    /// JSC 的 `stack` 只有调用帧，不含消息本身，所以两个都要——只取 stack 的话
    /// 报出来的是一串函数名，最关键的那句「哪里错了」反而没了。
    fileprivate nonisolated static func describe(_ value: JSValue) -> String {
        let message = value.toString() ?? "未知错误"
        let stack = value.objectForKeyedSubscript("stack")
        guard let stack, !stack.isUndefined, !stack.isNull,
              let frames = stack.toString(), !frames.isEmpty else { return message }
        return "\(message)\n\(frames)"
    }

    fileprivate nonisolated static func bool(_ context: JSContext, _ key: String) -> Bool {
        context.objectForKeyedSubscript(key)?.toBool() ?? false
    }

    fileprivate nonisolated static func string(_ context: JSContext, _ key: String) -> String? {
        guard let value = context.objectForKeyedSubscript(key),
              !value.isUndefined, !value.isNull,
              let text = value.toString(), !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - 校验返回值

extension NodeScript {
    /// 把脚本返回的数组变成规划，顺便挑出所有说不通的地方。
    ///
    /// 校验必须严：脚本写错时最糟的结果不是报错，而是**悄悄少几个节点**或者
    /// **名字接到了别的端口上**——前者在 Surge 里只表现为某个组短了几项，
    /// 后者表现为「点了香港结果走了美国」，两种都不会有任何提示。
    fileprivate nonisolated static func plan(from output: JSValue?,
                                             proxies: [NodeScriptProxy],
                                             collector: LogCollector) throws -> NormalizationPlan {
        guard let output, !output.isUndefined, !output.isNull else {
            throw NodeScriptError.notAnArray("undefined —— operator 没有 return")
        }
        guard output.isArray, let items = output.toArray() else {
            throw NodeScriptError.notAnArray(kind(of: output))
        }

        // 端口是名字与真实出口之间唯一的绑定，所以认端口而不认下标：脚本可以随意增删重排，
        // 只要把 localPort 带回来就接得上。
        var indexByPort: [Int: Int] = [:]
        for (index, proxy) in proxies.enumerated() where indexByPort[proxy.localPort] == nil {
            indexByPort[proxy.localPort] = index
        }

        var lines: [NormalizationPlan.Line] = []
        var names = proxies.map { "（脚本未输出）\($0.name)" }
        var used: Set<String> = []
        var duplicates = 0

        for (offset, item) in items.enumerated() {
            guard let entry = item as? [String: Any] else {
                throw NodeScriptError.badEntry("第 \(offset + 1) 项不是对象，是 \(type(of: item))")
            }
            guard let rawName = entry["name"] as? String,
                  case let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                throw NodeScriptError.badEntry("第 \(offset + 1) 项的 name 缺失或是空的")
            }
            guard let port = (entry["localPort"] as? NSNumber)?.intValue else {
                throw NodeScriptError.badEntry("第 \(offset + 1) 项「\(name)」没带 localPort。"
                    + "它必须从入参里原样带回来，否则接不回真实出口")
            }
            guard let index = indexByPort[port] else {
                throw NodeScriptError.badEntry("第 \(offset + 1) 项「\(name)」的 localPort=\(port) "
                    + "不在入参里。只能用传进来的端口，不能自己编")
            }

            // 重名在 Surge 里是后一条覆盖前一条、前面的静默消失，所以补后缀而不是丢掉。
            var candidate = NodeNaming.sanitize(name, index: offset + 1)
            if used.contains(candidate) {
                duplicates += 1
                var attempt = 1
                repeat {
                    attempt += 1
                    candidate = "\(NodeNaming.sanitize(name, index: offset + 1))-\(attempt)"
                } while used.contains(candidate)
            }
            used.insert(candidate)
            names[index] = candidate
            lines.append(NormalizationPlan.Line(name: candidate, index: index))
        }

        if duplicates > 0 {
            collector.warnings.append("有 \(duplicates) 个重名，已补后缀。"
                + "Surge 里重名的行只有最后一条生效，前面的会静默消失")
        }
        let dropped = proxies.count - Set(lines.map(\.index)).count
        if dropped > 0 {
            collector.warnings.append("\(dropped) 个节点没有出现在返回值里，不会进 Surge")
        }
        return NormalizationPlan(names: names, lines: lines)
    }

    fileprivate nonisolated static func kind(of value: JSValue) -> String {
        if value.isString { return "字符串" }
        if value.isNumber { return "数字" }
        if value.isBoolean { return "布尔值" }
        if value.isObject { return "对象（不是数组）" }
        return value.toString() ?? "未知类型"
    }
}
