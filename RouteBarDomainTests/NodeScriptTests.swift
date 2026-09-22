import Foundation
import Testing
@testable import RouteBarDomain

@Suite("节点脚本") struct NodeScriptTests {
    private func proxy(_ name: String, port: Int, type: String = "vless",
                       source: String = "JSSR", sourceIndex: Int = 0,
                       region: String = "香港", latency: Int? = nil) -> NodeScriptProxy {
        NodeScriptProxy(name: name, type: type, server: "\(port).example.com", port: 443,
                        localPort: port, source: source, sourceIndex: sourceIndex,
                        sourceUpdatedAt: Date(timeIntervalSince1970: 1_790_058_540),
                        region: region, latencyMilliseconds: latency)
    }

    private func run(_ script: String, _ proxies: [NodeScriptProxy],
                     timeout: TimeInterval = 2) throws -> NodeScriptResult {
        try NodeScript.run(script: script, proxies: proxies, timeout: timeout)
    }

    // MARK: - 基本契约

    @Test("重命名并保持端口绑定") func renamesWhileKeepingPorts() throws {
        let result = try run("""
        async function operator(proxies) {
          return proxies.map(p => ({ ...p, name: '【X】' + p.region }));
        }
        """, [proxy("香港 01", port: 7701), proxy("东京", port: 7702, region: "日本")])

        #expect(result.plan.lines.map(\.name) == ["【X】香港", "【X】日本"])
        #expect(result.plan.lines.map(\.index) == [0, 1])
    }

    @Test("普通函数和 async 函数都认") func acceptsBothSyncAndAsync() throws {
        let sync = try run("function operator(p) { return p.map(x => ({ ...x, name: 'A' })); }",
                           [proxy("n", port: 7701)])
        #expect(sync.plan.lines.map(\.name) == ["A"])
    }

    /// 脚本可以重排、丢弃，也可以让两行共用一个端口——合成「查看订阅信息」入口
    /// 靠的就是最后这一条。
    @Test("允许重排、丢弃与共用端口") func allowsReorderDropAndSharedPorts() throws {
        let result = try run("""
        async function operator(proxies) {
          const last = proxies[proxies.length - 1];
          return [
            { ...last, name: '入口' },
            { ...last, name: '末位' },
            { ...proxies[0], name: '首位' },
          ];
        }
        """, [proxy("a", port: 7701), proxy("b", port: 7702), proxy("c", port: 7703)])

        #expect(result.plan.lines.map(\.name) == ["入口", "末位", "首位"])
        #expect(result.plan.lines.map(\.index) == [2, 2, 0])
        #expect(result.warnings.contains { $0.contains("没有出现在返回值里") })
    }

    @Test("重名补后缀并告警") func deduplicatesNamesWithWarning() throws {
        let result = try run("async function operator(p) { return p.map(x => ({ ...x, name: '同名' })); }",
                             [proxy("a", port: 7701), proxy("b", port: 7702)])

        #expect(result.plan.lines.map(\.name) == ["同名", "同名-2"])
        #expect(result.warnings.contains { $0.contains("重名") })
    }

    /// 名字里的逗号和等号会把 Surge 那一行拆坏。脚本是最不可信的一份输入。
    @Test("清洗名字里的 Surge 语法字符") func sanitizesNames() throws {
        let result = try run("async function operator(p) { return [{ ...p[0], name: 'a,b=c\"d' }]; }",
                             [proxy("x", port: 7701)])

        #expect(!result.plan.lines[0].name.contains(","))
        #expect(!result.plan.lines[0].name.contains("="))
    }

    // MARK: - 入参

    @Test("入参带着真实协议、地区、延迟和来源") func exposesRichInput() throws {
        let result = try run("""
        async function operator(proxies) {
          return proxies.map(p => ({ ...p,
            name: [p.type, p.region, p.source, p.sourceIndex, p.latency, p.server, p.port].join('/') }));
        }
        """, [proxy("n", port: 7701, type: "hysteria2", source: "STOTIK",
                    sourceIndex: 2, region: "日本", latency: 137)])

        #expect(result.plan.lines[0].name == "hysteria2/日本/STOTIK/2/137/7701.example.com/443")
    }

    /// 没测过速时 latency 要是 null 而不是键不存在——`p.latency === null` 是能判的，
    /// 而 `'latency' in p` 为假时脚本作者通常想不到要去判。
    @Test("没测过速的延迟是 null") func missingLatencyIsNull() throws {
        let result = try run("""
        async function operator(p) {
          return [{ ...p[0], name: p[0].latency === null ? 'null' : 'other' }];
        }
        """, [proxy("n", port: 7701)])

        #expect(result.plan.lines[0].name == "null")
    }

    // MARK: - 沙箱

    /// 脚本能碰到网络或文件的话，「粘一段网上抄来的脚本」就成了一个能把订阅地址
    /// 发出去的漏洞。裸 JSContext 本来就没有这些，这里钉住的是「别哪天手滑加上」。
    @Test("沙箱里没有网络、定时器和模块加载") func sandboxHasNoIO() throws {
        let result = try run("""
        async function operator(p) {
          const missing = ['fetch', 'XMLHttpRequest', 'setTimeout', 'setInterval',
                           'require', 'process', 'WebSocket']
            .filter(n => typeof globalThis[n] === 'undefined');
          return [{ ...p[0], name: missing.join(',') }];
        }
        """, [proxy("n", port: 7701)])

        #expect(result.plan.lines[0].name
            == "fetch XMLHttpRequest setTimeout setInterval require process WebSocket")
    }

    /// 死循环必须能被打断，否则一个写错的脚本会一直占着一个核。
    @Test("死循环被执行时限打断") func infiniteLoopIsInterrupted() throws {
        let started = Date()
        #expect(throws: NodeScriptError.timedOut(0.3)) {
            try run("async function operator(p) { while (true) {} }", [proxy("n", port: 7701)],
                    timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    // MARK: - 报错

    @Test("语法错误") func reportsSyntaxErrors() throws {
        #expect(throws: NodeScriptError.self) {
            try run("async function operator( {{{", [proxy("n", port: 7701)])
        }
    }

    @Test("没定义 operator") func reportsMissingOperator() throws {
        #expect(throws: NodeScriptError.missingOperator) {
            try run("const x = 1;", [proxy("n", port: 7701)])
        }
    }

    @Test("operator 内部抛错时带上栈") func reportsThrownErrors() throws {
        do {
            _ = try run("async function operator() { throw new Error('boom'); }", [proxy("n", port: 7701)])
            Issue.record("应该抛错")
        } catch let error as NodeScriptError {
            guard case .thrown(let detail) = error else {
                Issue.record("类型不对：\(error)")
                return
            }
            #expect(detail.contains("boom"))
        }
    }

    @Test("返回值不是数组") func rejectsNonArrayResults() throws {
        #expect(throws: NodeScriptError.self) {
            try run("async function operator() { return 'nope'; }", [proxy("n", port: 7701)])
        }
        #expect(throws: NodeScriptError.self) {
            try run("async function operator() {}", [proxy("n", port: 7701)])
        }
    }

    /// 端口丢了就接不回真实出口。悄悄放过去的后果是「点了香港走了美国」，没有任何征兆。
    @Test("条目缺 localPort 或端口不在入参里") func rejectsBadPorts() throws {
        #expect(throws: NodeScriptError.self) {
            try run("async function operator() { return [{ name: 'a' }]; }", [proxy("n", port: 7701)])
        }
        #expect(throws: NodeScriptError.self) {
            try run("async function operator() { return [{ name: 'a', localPort: 9999 }]; }",
                    [proxy("n", port: 7701)])
        }
    }

    @Test("条目缺名字") func rejectsEmptyNames() throws {
        #expect(throws: NodeScriptError.self) {
            try run("async function operator(p) { return [{ ...p[0], name: '  ' }]; }",
                    [proxy("n", port: 7701)])
        }
    }

    // MARK: - console

    @Test("console 输出被收回来") func capturesConsoleOutput() throws {
        let result = try run("""
        async function operator(p) {
          console.log('共', p.length, '个节点');
          console.warn('提醒');
          console.log({ a: 1 });
          return p.map(x => ({ ...x, name: 'n' }));
        }
        """, [proxy("a", port: 7701)])

        #expect(result.logs == ["共 1 个节点", "[warn] 提醒", "{\"a\":1}"])
    }

    @Test("日志有上限") func capsLogVolume() throws {
        let result = try run("""
        async function operator(p) {
          for (let i = 0; i < 1000; i++) console.log(i);
          return p.map(x => ({ ...x, name: 'n' }));
        }
        """, [proxy("a", port: 7701)])

        #expect(result.logs.count <= NodeScript.logLimit + 1)
        #expect(result.logs.last?.contains("省略") == true)
    }

    // MARK: - 与内置规范化对齐

    /// 用脚本把内置规范化那一套完整复现一遍，两者输出必须逐行相同。
    ///
    /// 这条同时是两件事的证明：脚本的表达力够覆盖内置行为（否则这个功能没意义），
    /// 以及内置行为本身可以被脚本替换掉（用户想改哪一步就改哪一步）。
    @Test("脚本能复现内置规范化的输出") func scriptReproducesBuiltInNormalization() throws {
        let script = """
        async function operator(proxies) {
          const INFO = '【INFO】';
          const kinds = [
            { key: 'update', label: '更新时间', words: ['更新时间', '更新時間'] },
            { key: 'traffic', label: '剩余流量', words: ['剩余流量', '剩餘流量'] },
            { key: 'reset',   label: '下次重置', words: ['下次重置', '重置剩余'] },
            { key: 'expire',  label: '到期时间', words: ['到期时间', '到期時間', '套餐到期'] },
          ];
          const normal = [], info = [], counter = {};

          for (const p of proxies) {
            if (p.name.includes('續約專用線路') || p.name.includes('续约专用线路')) continue;
            const kind = kinds.find(k => k.words.some(w => p.name.includes(w)));
            if (kind) {
              let value;
              if (kind.key === 'update') {
                value = p.sourceUpdatedAt.slice(0, 16).replace('T', ' ');
              } else if (kind.key === 'expire') {
                const m = p.name.match(/(\\d{4})[-/.年](\\d{1,2})[-/.月](\\d{1,2})/);
                value = m ? [m[1], m[2].padStart(2, '0'), m[3].padStart(2, '0')].join('-') : 'unknown';
              } else {
                value = p.name.split(/[:：]/).slice(1).join(':').trim();
              }
              info.push({ ...p, name: `${INFO}${p.source}｜${kind.label}：${value}`,
                          _rank: p.sourceIndex, _order: kinds.indexOf(kind) });
              continue;
            }
            const key = p.source + '\\u001f' + p.region;
            counter[key] = (counter[key] || 0) + 1;
            normal.push({ ...p, name: `【${p.source}】${p.region}${String(counter[key]).padStart(2, '0')}` });
          }

          info.sort((a, b) => a._rank - b._rank || a._order - b._order);
          const out = [...normal];
          if (info.length) out.push({ ...info[0], name: INFO + '查看订阅信息' });
          return out.concat(info);
        }
        """
        let proxies = [
            proxy("[vip1] ⑮香港︱Vless", port: 7701),
            proxy("[vip1]⑱美国︱Hysteria2", port: 7702, type: "hysteria2", region: "美国"),
            proxy("剩余流量：89.98 GB", port: 7703, region: "小众"),
            proxy("續約專用線路 - user.stotik.nl", port: 7704, source: "STOTIK",
                  sourceIndex: 1, region: "小众"),
            proxy("到期時間：2027-03-30 23:42", port: 7705, source: "STOTIK",
                  sourceIndex: 1, region: "小众"),
        ]

        let scripted = try run(script, proxies)

        // 同一批节点走内置规范化。
        let subs = [SubscriptionRecord(id: UUID(), name: "JSSR",
                                       updatedAt: Date(timeIntervalSince1970: 1_790_058_540)),
                    SubscriptionRecord(id: UUID(), name: "STOTIK",
                                       updatedAt: Date(timeIntervalSince1970: 1_790_058_540))]
        let inputs = proxies.map {
            NormalizationInput(name: $0.name, sourceName: $0.source, sourceRank: $0.sourceIndex,
                               sourceUpdatedAt: $0.sourceUpdatedAt)
        }
        let builtIn = NodeNormalization.plan(inputs, timeZone: TimeZone(identifier: "Asia/Shanghai")!)

        #expect(scripted.plan.lines.map(\.name) == builtIn.lines.map(\.name))
        #expect(scripted.plan.lines.map(\.index) == builtIn.lines.map(\.index))
    }
}
