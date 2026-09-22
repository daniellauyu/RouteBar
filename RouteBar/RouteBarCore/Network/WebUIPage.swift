import Foundation

/// 内嵌的 Web 界面。
///
/// 整页塞在字符串里，不走 bundle 资源：这样它跟着二进制走，不存在「资源没打进去导致
/// 运行时 404」这一类只在打包后才暴露的问题，也免去为 SwiftPM 与 Xcode 各配一次
/// resource 规则。页面没有任何外部依赖——没有 CDN、没有字体、没有图片。
///
/// 结构、样式、文案、脚本各占一个文件（`WebUIStyle` / `WebUIStrings` / `WebUIScript`）。
/// 四样混在一处时，改一句文案要在六百行里找，而样式又比结构长得多。
///
/// 令牌不内联进页面，而是由脚本从自身 URL（`/<token>/`）里读出来。内联的话，
/// 任何把 HTML 存下来或贴出去的动作都会连令牌一起泄露。
enum WebUIPage {
    /// 整页 HTML。
    ///
    /// 用 `static let` 而不是计算属性：页面是常量，而计算属性会在**每次请求**上重新拼一遍
    /// 六百行字符串，还要把文案表重新做一次 JSON 序列化。Surge 拉策略集的频率不低，
    /// 这份开销白花。同时标 `nonisolated`——默认隔离下它会被推断成 main actor，
    /// 而调用它的是 HTTP 路由所在的后台执行域。
    nonisolated static let html: String = {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <title>RouteBar</title>
        \(favicon)
        <style>\(WebUIStyle.css)</style>
        </head>
        <body>
        \(iconSprite)

        <header>
          <div class="brand">
            <svg class="brand-logo" viewBox="0 0 24 24" aria-hidden="true"><use href="#i-logo"/></svg>
            <b>RouteBar</b>
            <span class="dot" id="overall-dot"></span>
            <small data-i18n="brand.sub"></small>
          </div>
          <nav>
            \(tab("overview", icon: "gauge", key: "nav.overview"))
            \(tab("nodes", icon: "nodes", key: "nav.nodes"))
            \(tab("subs", icon: "layers", key: "nav.subs"))
            \(tab("nettest", icon: "globe", key: "nav.nettest"))
          </nav>
          <div class="prefs">
            <div class="pref-menu" id="pref-theme-menu">
              <span class="sr-only" data-i18n="pref.theme.label"></span>
              <button type="button" class="pref-control pref-menu-trigger" id="pref-theme"
                      aria-haspopup="menu" aria-expanded="false" onclick="toggleThemeMenu(event)">
                <svg class="ic" id="pref-theme-icon" viewBox="0 0 24 24" aria-hidden="true"><use href="#i-appearance"/></svg>
                <span id="pref-theme-value" data-i18n="pref.theme.auto"></span>
                <svg class="ic pref-chevron" viewBox="0 0 24 24" aria-hidden="true"><use href="#i-chevron"/></svg>
              </button>
              <div class="pref-menu-list" role="menu" aria-labelledby="pref-theme">
                \(themeOption("auto", icon: "appearance"))
                \(themeOption("light", icon: "sun"))
                \(themeOption("dark", icon: "moon"))
              </div>
            </div>
            <label class="pref-control">
              <span class="sr-only" data-i18n="pref.lang.label"></span>
              <svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><use href="#i-language"/></svg>
              <select id="pref-lang" onchange="setLang(this.value)">
                <option value="auto" data-i18n="pref.lang.auto"></option>
                <option value="zh" data-i18n="pref.lang.zh"></option>
                <option value="en" data-i18n="pref.lang.en"></option>
              </select>
            </label>
          </div>
        </header>

        <main>

        <!-- ══════════ 概览 ══════════ -->
        <section data-page="overview">
          <div class="card" id="health-card" hidden>
            <div class="card-head"><h2 data-i18n="health.title"></h2></div>
            <div class="card-body" id="health"></div>
          </div>

          <div class="card">
            <div class="card-head">
              <span class="dot" id="svc-dot"></span>
              <h2 data-i18n="ov.service.title"></h2>
              <span class="count" id="svc-label"></span>
              <div class="toolbar">
                <button class="ghost small" id="btn-svc"></button>
                <button class="ghost small" id="btn-refresh" data-i18n="common.refresh"></button>
              </div>
            </div>
            <div class="card-body">
              <div class="metrics">
                <div class="metric"><b id="m-nodes">–</b><span data-i18n="ov.metric.enabled"></span></div>
                <div class="metric"><b id="m-total">–</b><span data-i18n="ov.metric.total"></span></div>
                <div class="metric"><b id="m-dedup">–</b><span data-i18n="ov.metric.dedup"></span></div>
                <div class="metric"><b id="m-tested">–</b><span data-i18n="ov.metric.tested"></span></div>
                <div class="metric"><b id="m-failed">–</b><span data-i18n="ov.metric.failed"></span></div>
              </div>
              <div class="row wrap" style="margin-top:16px">
                <span class="dim mono" id="svc-agent"></span>
              </div>
              <div class="note" data-i18n="ov.service.hint"></div>
            </div>
          </div>

          <div class="card">
            <div class="card-head">
              <h2 data-i18n="ov.test.title"></h2>
              <div class="toolbar">
                <button class="ghost" id="btn-test-all" data-i18n="ov.test.all"></button>
                <button class="ghost" id="btn-geo-all" data-i18n="ov.test.geo"></button>
                <button class="ghost" id="btn-update" data-i18n="ov.actions.update"></button>
                <button class="primary" id="btn-regen" data-i18n="ov.actions.regen"></button>
              </div>
            </div>
            <div class="card-body"><div class="dim" data-i18n="ov.test.desc"></div></div>
          </div>

          <div class="card">
            <div class="card-head">
              <h2 data-i18n="ov.output.title"></h2>
              <span class="tag" id="serve-state"></span>
            </div>
            <div class="card-body">
              <div class="mono" id="sub-url"></div>
              <div class="dim" style="margin:12px 0 5px" data-i18n="ov.output.surgeHint"></div>
              <div class="mono scroll" id="policy-line" style="white-space:nowrap"></div>
              <div class="row" style="margin-top:13px">
                <button class="ghost small" id="btn-copy-url" data-i18n="ov.output.copyUrl"></button>
                <button class="ghost small" id="btn-copy-line" data-i18n="ov.output.copyLine"></button>
              </div>
              <div class="note" data-i18n="ov.output.otherHint"></div>
            </div>
          </div>
        </section>

        <!-- ══════════ 节点 ══════════ -->
        <section data-page="nodes" hidden>
          <div class="card">
            <div class="card-head">
              <h2 data-i18n="nav.nodes"></h2>
              <span class="count" id="node-count"></span>
              <div class="toolbar">
                <button class="ghost small" id="btn-test-all-2" data-i18n="ov.test.all"></button>
                <button class="ghost small" id="btn-geo-all-2" data-i18n="ov.test.geo"></button>
              </div>
            </div>
            <div class="card-body">
              <div class="filters">
                <input id="nd-search" data-i18n-ph="nd.search">
                <select id="nd-sub"></select>
                <select id="nd-proto"></select>
                <select id="nd-region"></select>
                <select id="nd-lat"></select>
                <select id="nd-sort"></select>
              </div>
            </div>
            <div class="card-body tight" id="nodes"></div>
          </div>
        </section>

        <!-- ══════════ 订阅 ══════════ -->
        <section data-page="subs" hidden>
          <div class="card">
            <div class="card-head">
              <h2 data-i18n="sb.title"></h2>
              <span class="count" id="sub-count"></span>
              <div class="toolbar">
                <select id="sub-proto" style="min-width:130px"></select>
                <button class="ghost small" id="btn-update-all" data-i18n="sb.updateAll"></button>
              </div>
            </div>
            <div class="card-body">
              <form class="add" id="add-form">
                <input id="add-name" data-i18n-ph="sb.name" required>
                <input id="add-url" data-i18n-ph="sb.urlPlaceholder" required type="url">
                <button class="primary" type="submit" data-i18n="sb.add"></button>
              </form>
              <div class="note" data-i18n="sb.credentialHint"></div>
            </div>
            <div class="card-body tight" id="subs"></div>
          </div>

          <div class="card">
            <div class="card-head">
              <h2 data-i18n="naming.title"></h2>
              <span class="count" id="naming-preview"></span>
            </div>
            <div class="card-body">
              <div class="row wrap">
                <select id="naming-style" style="width:auto;flex:0 0 auto;min-width:118px"></select>
                <input id="naming-template" class="grow">
                <button class="ghost" id="btn-naming-test" data-i18n="naming.test"></button>
                <button class="primary" id="btn-naming-save" data-i18n="naming.save"></button>
                <button class="ghost" id="btn-naming-reset" data-i18n="naming.reset"></button>
              </div>
              <div class="note" id="naming-help"></div>
              <div class="note" data-i18n="naming.hint"></div>
              <div id="naming-result" hidden style="margin-top:10px"></div>
              <!-- 地区表只在规范化模式下出现：模板模式根本不读它，摆在那里只会让人以为改了有用。 -->
              <!-- 脚本编辑器：只在脚本模式下出现。 -->
              <div id="naming-script" hidden style="margin-top:14px">
                <div class="note" data-i18n="naming.scriptHint" style="margin-bottom:6px"></div>
                <textarea id="naming-script-text" class="code" rows="18" spellcheck="false"
                          autocapitalize="off" autocorrect="off"></textarea>
                <div class="row wrap" style="margin-top:8px">
                  <button class="ghost" id="btn-script-run" data-i18n="naming.scriptRun"></button>
                  <button class="primary" id="btn-script-save" data-i18n="naming.scriptSave"></button>
                  <button class="ghost" id="btn-script-template" data-i18n="naming.scriptTemplate"></button>
                  <span class="count" id="script-status"></span>
                </div>
                <div id="script-result" hidden style="margin-top:10px"></div>
              </div>
              <div id="naming-regions" hidden style="margin-top:14px">
                <div class="note" data-i18n="naming.regionsHint" style="margin-bottom:6px"></div>
                <textarea id="naming-region-table" rows="12" spellcheck="false"></textarea>
                <div class="row wrap" style="margin-top:8px">
                  <button class="primary" id="btn-regions-save" data-i18n="naming.regionsSave"></button>
                  <button class="ghost" id="btn-regions-reset" data-i18n="naming.regionsReset"></button>
                </div>
              </div>
            </div>
          </div>
        </section>

        <!-- ══════════ 网络测试 ══════════ -->
        <section data-page="nettest" hidden>
          <div class="card">
            <div class="card-head">
              <h2 data-i18n="nt.geo.title"></h2>
              <div class="toolbar">
                <button class="primary" id="btn-geo-run" data-i18n="nt.geo.run"></button>
              </div>
            </div>
            <div class="card-body">
              <div class="dim" data-i18n="nt.geo.desc"></div>
              <div class="note" data-i18n="nt.geo.privacy"></div>
            </div>
            <div class="card-body tight" id="geo-groups"></div>
          </div>

          <div class="card">
            <div class="card-head">
              <h2 data-i18n="nt.target.title"></h2>
              <span class="count" id="probe-count"></span>
            </div>
            <div class="card-body">
              <div class="dim" style="margin-bottom:13px" data-i18n="nt.target.desc"></div>
              <div class="chips" id="probe-presets"></div>
              <div class="row wrap" style="margin-top:12px;align-items:flex-end">
                <label class="field grow">
                  <span class="dim" data-i18n="nt.target.url"></span>
                  <input id="probe-url" placeholder="https://www.google.com/generate_204">
                </label>
                <label class="field">
                  <span class="dim" data-i18n="nt.target.scope"></span>
                  <select id="probe-scope" style="width:auto;min-width:180px"></select>
                </label>
                <button class="primary" id="btn-probe" data-i18n="nt.target.run"></button>
              </div>
              <div class="note" data-i18n="nt.target.note"></div>
            </div>
            <div class="card-body tight" id="probe-results"></div>
          </div>
        </section>

        </main>
        <div id="toast"></div>

        <script>
        const I18N = \(WebUIStrings.js);
        const FAVICONS = \(faviconJS);
        \(WebUIScript.js)
        </script>
        </body>
        </html>
        """
    }()

    private nonisolated static func tab(_ id: String, icon: String, key: String) -> String {
        """
        <button type="button" data-tab="\(id)" onclick="showTab('\(id)')">
              <svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><use href="#i-\(icon)"/></svg>
              <span data-i18n="\(key)"></span>
            </button>
        """
    }

    private nonisolated static func themeOption(_ mode: String, icon: String) -> String {
        """
        <button type="button" role="menuitemradio" data-theme-option="\(mode)"
                        onclick="chooseTheme('\(mode)',event)">
                  <svg class="ic menu-check" viewBox="0 0 24 24" aria-hidden="true"><use href="#i-check"/></svg>
                  <svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><use href="#i-\(icon)"/></svg>
                  <span data-i18n="pref.theme.\(mode)"></span>
                </button>
        """
    }

    /// 内联 SVG 图标表。
    ///
    /// 用 `<use>` 引用同一份定义，而不是每处重画一遍：图标在 tab 和菜单里各出现一次，
    /// 复制粘贴的那份迟早会和另一份长得不一样。也不用图标字体——那要么额外加载一个文件
    /// （这台机器可能正好上不了网），要么把一整套字形塞进页面。
    private nonisolated static let iconSprite = """
    <svg width="0" height="0" style="position:absolute" aria-hidden="true">
      <defs>
        <g id="i-gauge"><path d="M12 14l4-4"/><path d="M4 18a9 9 0 1116 0"/></g>
        <g id="i-nodes"><circle cx="5" cy="18" r="2"/><circle cx="19" cy="18" r="2"/><circle cx="12" cy="5" r="2"/><path d="M10.5 6.7L6.5 16m11 0l-4-9.3"/></g>
        <g id="i-layers"><path d="M12 3l9 5-9 5-9-5 9-5z"/><path d="M3 13l9 5 9-5"/></g>
        <g id="i-globe"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a15 15 0 010 18a15 15 0 010-18"/></g>
        <g id="i-appearance"><circle cx="12" cy="12" r="8"/><path d="M12 4v16"/></g>
        <g id="i-sun"><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M4.9 4.9l1.4 1.4m11.4 11.4l1.4 1.4M19.1 4.9l-1.4 1.4M6.3 17.7l-1.4 1.4"/></g>
        <g id="i-moon"><path d="M20 14.5A8.5 8.5 0 019.5 4a8.5 8.5 0 1010.5 10.5z"/></g>
        <g id="i-language"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a15 15 0 010 18a15 15 0 010-18"/></g>
        <g id="i-check"><path d="M5 12.5l4.5 4.5L19 7.5"/></g>
        <g id="i-chevron"><path d="M6 9.5l6 6 6-6"/></g>
        <!-- 品牌标记：三个节点汇聚成一条出口，与 App 图标同形。
             黑线走 currentColor，跟着页面文字色，夜间模式下自动翻白；
             箭头固定用品牌蓝，那是它的身份，不该跟着主题变。 -->
        <g id="i-logo">
          <g fill="none" stroke="currentColor" stroke-width="1.9"
             stroke-linecap="round" stroke-linejoin="round">
            <path d="M4.6 3.6h5.2c2.8 0 3.1 3.9 5.1 8.4"/>
            <path d="M4.6 12h10.3"/>
            <path d="M4.6 20.4h5.2c2.8 0 3.1-3.9 5.1-8.4"/>
          </g>
          <g fill="currentColor" stroke="none">
            <circle cx="3.5" cy="3.6" r="1.95"/>
            <circle cx="3.5" cy="12" r="1.95"/>
            <circle cx="3.5" cy="20.4" r="1.95"/>
          </g>
          <g fill="none" stroke="#16A9E8" stroke-width="1.9"
             stroke-linecap="round" stroke-linejoin="round">
            <path d="M14.9 12c3.4 0 4.7-1.9 5.4-4.6"/>
            <path d="M17.4 7.3h3v3"/>
          </g>
        </g>
      </defs>
    </svg>
    """

    /// 标签页图标。
    ///
    /// 内联成 data URI 而不是指向一个 `/favicon.ico` 路由：整页不依赖任何外部资源是
    /// 这个界面的既有约束，多开一条路由还要过令牌校验（浏览器请求 favicon 时不带令牌，
    /// 只会拿到 404）。
    ///
    /// 深浅两张分开出，由脚本按**系统配色**换整张图；SVG 内部写 `prefers-color-scheme`
    /// 是不管用的——只有 Firefox 会按标签栏配色重算，Chrome 与 Safari 把 favicon 当静态
    /// 图片渲染，那条媒体查询恒不命中，写死的黑线在深色标签栏里就是一团看不见的东西。
    private nonisolated static func faviconURI(ink: String) -> String {
        "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E"
            + "%3Cg fill='none' stroke='\(ink)' stroke-width='1.9' stroke-linecap='round' stroke-linejoin='round'%3E"
            + "%3Cpath d='M4.6 3.6h5.2c2.8 0 3.1 3.9 5.1 8.4'/%3E"
            + "%3Cpath d='M4.6 12h10.3'/%3E"
            + "%3Cpath d='M4.6 20.4h5.2c2.8 0 3.1-3.9 5.1-8.4'/%3E%3C/g%3E"
            + "%3Cg fill='\(ink)'%3E"
            + "%3Ccircle cx='3.5' cy='3.6' r='1.95'/%3E"
            + "%3Ccircle cx='3.5' cy='12' r='1.95'/%3E"
            + "%3Ccircle cx='3.5' cy='20.4' r='1.95'/%3E%3C/g%3E"
            + "%3Cg fill='none' stroke='%2316A9E8' stroke-width='1.9' stroke-linecap='round' stroke-linejoin='round'%3E"
            + "%3Cpath d='M14.9 12c3.4 0 4.7-1.9 5.4-4.6'/%3E"
            + "%3Cpath d='M17.4 7.3h3v3'/%3E%3C/g%3E%3C/svg%3E"
    }

    /// 浅色标签栏配深墨线，深色标签栏配浅墨线；箭头两张都保持品牌蓝，那是它的身份。
    private nonisolated static let faviconLight = faviconURI(ink: "%23111")
    private nonisolated static let faviconDark = faviconURI(ink: "%23f5f6f8")

    /// 首屏先挂浅色那张，脚本一跑起来立刻换成对的那张。带 `id` 是为了让脚本找得到它。
    private nonisolated static let favicon =
        "<link rel=\"icon\" id=\"favicon\" type=\"image/svg+xml\" href=\"\(faviconLight)\">"

    /// 两张图一并交给脚本，省得在 JS 里把同一个标记再画一遍。
    private nonisolated static let faviconJS =
        "{light:\"\(faviconLight)\",dark:\"\(faviconDark)\"}"
}
