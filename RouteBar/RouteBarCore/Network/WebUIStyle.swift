import Foundation

/// Web 界面的样式。
///
/// 和页面结构拆开：这份东西比结构还长，混在一个字符串里改哪一处都要先翻半天。
///
/// 不引任何框架、不加载任何外部资源。页面由 RouteBar 自己吐出来，而会用到它的机器
/// 常常正处在「网络不通所以才装代理」的状态——CDN 一挂整个控制台就变成没样式的表格。
enum WebUIStyle {
    nonisolated static let css = """
    :root {
      color-scheme: light dark;
      --bg:#f4f5f7; --card:#fff; --surface:#f8f8fa; --ink:#17191d; --sub:#6d7178;
      --line:#e5e7eb; --hover:#f4f6f8; --tint:#1769e0; --tint-soft:#eaf2ff;
      --danger:#c92a36; --danger-soft:#fff0f1;
      --ok:#218447; --warn:#b8730f; --bad:#c92a36;
      --radius:16px; --shadow:0 1px 2px rgba(20,28,40,.04),0 12px 36px rgba(20,28,40,.07);
    }
    /* 夜间那套色写两遍，覆盖三种状态：
       - 跟随系统（没有 data-theme）：靠 prefers-color-scheme
       - 显式选了夜间：data-theme="dark"，系统是白天也要暗
       - 显式选了日间：data-theme="light"，系统是夜间也要亮 ——
         所以上面那条必须排除掉它，否则「日间」在夜间系统上按不住 */
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
        --bg:#0d0e11; --card:#191b20; --surface:#22252b; --ink:#f5f6f8; --sub:#9ca1aa;
        --line:#30343b; --hover:#24272d; --tint:#5ca0ff; --tint-soft:#152d4e;
        --danger:#ff6961; --danger-soft:#3b1d21;
        --ok:#4bd47b; --warn:#f0b429; --bad:#ff6961;
        --shadow:0 1px 2px rgba(0,0,0,.35),0 14px 42px rgba(0,0,0,.24);
      }
    }
    :root[data-theme="dark"] {
      --bg:#0d0e11; --card:#191b20; --surface:#22252b; --ink:#f5f6f8; --sub:#9ca1aa;
      --line:#30343b; --hover:#24272d; --tint:#5ca0ff; --tint-soft:#152d4e;
      --danger:#ff6961; --danger-soft:#3b1d21;
      --ok:#4bd47b; --warn:#f0b429; --bad:#ff6961;
      --shadow:0 1px 2px rgba(0,0,0,.35),0 14px 42px rgba(0,0,0,.24);
    }

    * { box-sizing:border-box; }
    body {
      margin:0; min-height:100vh; background:var(--bg); color:var(--ink);
      font:15px/1.6 -apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC","Segoe UI",sans-serif;
      -webkit-font-smoothing:antialiased;
    }
    button, select, input { font:inherit; }
    :focus-visible { outline:3px solid color-mix(in srgb,var(--tint) 32%,transparent); outline-offset:2px; }
    .sr-only {
      position:absolute; width:1px; height:1px; padding:0; margin:-1px;
      overflow:hidden; clip:rect(0,0,0,0); white-space:nowrap; border:0;
    }
    [hidden] { display:none !important; }

    /* ---------- 顶栏 ---------- */
    header {
      position:sticky; top:0; z-index:20;
      background:color-mix(in srgb,var(--card) 88%,transparent);
      backdrop-filter:blur(18px) saturate(1.35);
      border-bottom:1px solid color-mix(in srgb,var(--line) 82%,transparent);
      padding:0 26px; display:flex; align-items:center; gap:22px; flex-wrap:wrap;
    }
    /* 图标与文字一律横排。`align-items:center` 而不是 baseline——
       基线对齐会把没有文字基线的 SVG 顶到奇怪的位置。 */
    .brand { display:flex; align-items:center; gap:9px; padding:11px 0; white-space:nowrap; }
    .brand-logo { width:26px; height:26px; flex:none; display:block; }
    .brand b { font-size:16px; font-weight:650; letter-spacing:.2px; }
    .brand small { color:var(--sub); font-size:12px; }

    nav { display:flex; gap:2px; }
    /* `display:inline-flex` 这一句不能少：`.ic` 是 `display:block`，
       少了它图标会变成块级元素、把文字挤到自己下面去——tab 就成了上图下字。 */
    nav button {
      display:inline-flex; align-items:center; gap:7px;
      border:0; background:transparent; color:var(--sub); cursor:pointer;
      padding:16px 13px; font-size:14px; font-weight:500;
      border-bottom:2px solid transparent; transition:color .15s;
    }
    nav button:hover { color:var(--ink); }
    nav button.on { color:var(--tint); border-bottom-color:var(--tint); }

    /* 右上角偏好控件。语言用原生 select，主题是自绘菜单（三态要带图标与选中标记）。 */
    .prefs { margin-left:auto; display:flex; gap:8px; align-items:center; }
    .pref-control {
      position:relative; display:inline-flex; align-items:center; min-height:34px;
      padding-left:10px; color:var(--sub); border:1px solid var(--line); border-radius:10px;
      background:var(--surface); transition:border-color .15s,background .15s;
    }
    .pref-control:hover { border-color:color-mix(in srgb,var(--sub) 60%,var(--line)); background:var(--hover); }
    .pref-control:focus-within { border-color:var(--tint); }
    .pref-control select {
      width:auto; min-height:32px; padding:4px 8px; font-size:13px; line-height:1;
      background:transparent; border:0; color:var(--ink); cursor:pointer; outline:0;
    }
    .pref-menu { position:relative; }
    .pref-menu-trigger {
      gap:7px; padding:4px 9px 4px 10px; min-width:104px; justify-content:flex-start;
      color:var(--ink); cursor:pointer; font-size:13px; line-height:1;
    }
    .pref-chevron { margin-left:auto; transition:transform .16s; }
    .pref-menu.open .pref-chevron { transform:rotate(180deg); }
    .pref-menu-list {
      display:none; position:absolute; z-index:40; top:calc(100% + 7px); right:0;
      min-width:152px; padding:6px; border:1px solid var(--line); border-radius:12px;
      background:var(--card); box-shadow:0 14px 38px rgba(20,28,40,.18);
    }
    .pref-menu.open .pref-menu-list { display:block; }
    .pref-menu-list button {
      display:flex; align-items:center; gap:8px; width:100%; min-height:36px; padding:6px 9px;
      border:0; border-radius:8px; background:transparent; color:var(--ink);
      font-size:14px; text-align:left; white-space:nowrap; cursor:pointer;
    }
    .pref-menu-list button:hover, .pref-menu-list button:focus-visible { background:var(--hover); }
    .pref-menu-list button.selected { color:var(--tint); background:var(--tint-soft); }
    .pref-menu-list .menu-check { visibility:hidden; }
    .pref-menu-list button.selected .menu-check { visibility:visible; }

    /* 图标一律 currentColor 描边，跟着文字色走；写死颜色的话夜间会是一片黑。 */
    .ic {
      display:block; width:16px; height:16px; flex:none; stroke:currentColor; fill:none;
      stroke-width:1.8; stroke-linecap:round; stroke-linejoin:round;
    }

    main { max-width:1080px; margin:0 auto; padding:26px 26px 80px; }

    /* ---------- 卡片 ---------- */
    .card {
      background:var(--card); border:1px solid color-mix(in srgb,var(--line) 78%,transparent);
      border-radius:var(--radius); box-shadow:var(--shadow); margin-bottom:16px; overflow:hidden;
    }
    .card-head {
      padding:15px 19px; border-bottom:1px solid var(--line);
      display:flex; align-items:center; gap:11px; flex-wrap:wrap;
    }
    .card-head h2 { font-size:15px; font-weight:600; margin:0; }
    .card-head .count { color:var(--sub); font-size:13px; }
    .card-body { padding:19px; }
    .card-body.tight { padding:6px 19px; }
    .toolbar { display:flex; gap:8px; flex-wrap:wrap; margin-left:auto; align-items:center; }

    /* ---------- 按钮 ---------- */
    button.primary, button.ghost, button.danger {
      display:inline-flex; align-items:center; justify-content:center; gap:6px;
      min-height:34px; line-height:1; border-radius:9px; font-size:13.5px; cursor:pointer;
      padding:8px 13px; font-weight:500; border:1px solid transparent; white-space:nowrap;
      transition:background .15s,border-color .15s,color .15s;
    }
    button.primary { background:var(--tint); color:#fff; }
    button.primary:hover:not(:disabled) { filter:brightness(1.08); }
    button.ghost { background:var(--surface); color:var(--ink); border-color:var(--line); }
    button.ghost:hover:not(:disabled) { background:var(--hover); border-color:color-mix(in srgb,var(--sub) 50%,var(--line)); }
    button.danger { background:transparent; color:var(--danger); border-color:transparent; }
    button.danger:hover:not(:disabled) { background:var(--danger-soft); }
    button.small { min-height:28px; padding:5px 10px; font-size:12.5px; }
    button:disabled { opacity:.42; cursor:default; }

    input, select {
      min-height:34px; padding:7px 10px; border-radius:9px; font-size:13.5px;
      border:1px solid var(--line); background:var(--surface); color:var(--ink); width:100%;
    }
    input:focus, select:focus { outline:0; border-color:var(--tint); background:var(--card); }
    select { cursor:pointer; }

    /* ---------- 通用排版 ---------- */
    .row { display:flex; align-items:center; gap:11px; }
    .between { justify-content:space-between; }
    .grow { flex:1; min-width:0; }
    .wrap { flex-wrap:wrap; }
    .dim { color:var(--sub); font-size:12.5px; }
    .ellipsis { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .mono {
      font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12.5px; word-break:break-all;
    }
    .scroll { overflow-x:auto; }
    .dot { width:9px; height:9px; border-radius:50%; flex:none; display:inline-block; }
    .dot.running { background:var(--ok); } .dot.stopped { background:var(--sub); }
    .dot.needsAttention { background:var(--warn); } .dot.failed { background:var(--bad); }
    .tag {
      font-size:11.5px; padding:2px 7px; border-radius:6px; white-space:nowrap;
      background:var(--surface); color:var(--sub); border:1px solid var(--line);
    }
    .tag.ok { color:var(--ok); border-color:color-mix(in srgb,var(--ok) 40%,var(--line)); }
    .tag.bad { color:var(--bad); border-color:color-mix(in srgb,var(--bad) 40%,var(--line)); }
    .tag.warn { color:var(--warn); border-color:color-mix(in srgb,var(--warn) 45%,var(--line)); }

    .item { padding:11px 0; border-top:1px solid var(--line); display:flex; align-items:center; gap:11px; }
    .item:first-child { border-top:0; }
    .item.off { opacity:.45; }
    .idx {
      flex:none; width:28px; text-align:right; color:var(--sub);
      font-size:12px; font-variant-numeric:tabular-nums;
    }
    .lat { font-variant-numeric:tabular-nums; font-size:12.5px; white-space:nowrap; }
    .lat.fast { color:var(--ok); } .lat.medium { color:var(--warn); }
    .lat.slow, .lat.failed { color:var(--bad); } .lat.untested { color:var(--sub); }
    .flagcell { flex:none; min-width:74px; font-size:12.5px; color:var(--sub); white-space:nowrap; }
    .flag { font-size:15px; }

    .metrics { display:grid; grid-template-columns:repeat(auto-fit,minmax(92px,1fr)); gap:14px; }
    .metric b { display:block; font-size:22px; font-weight:600; font-variant-numeric:tabular-nums; }
    .metric span { color:var(--sub); font-size:12.5px; }

    .health { color:var(--warn); font-size:13.5px; padding:4px 0; }
    .empty { color:var(--sub); font-size:13.5px; padding:22px 0; text-align:center; }
    .note { color:var(--sub); font-size:12.5px; margin-top:9px; }

    .filters { display:flex; gap:9px; flex-wrap:wrap; align-items:center; }
    .filters input { width:auto; flex:1 1 190px; min-width:150px; }
    .filters select { width:auto; flex:0 0 auto; min-width:118px; }

    .field { display:flex; flex-direction:column; gap:4px; }
    .editor { display:grid; grid-template-columns:1fr 1fr; gap:10px; margin:12px 0; }
    form.add { display:grid; grid-template-columns:1fr 1.6fr auto; gap:8px; }

    .chips { display:flex; gap:7px; flex-wrap:wrap; }
    .chip {
      border:1px solid var(--line); background:var(--surface); color:var(--sub);
      border-radius:999px; padding:5px 12px; font-size:12.5px; cursor:pointer;
    }
    .chip:hover { background:var(--hover); color:var(--ink); }

    .group-head {
      display:flex; align-items:center; gap:8px; padding:13px 0 5px;
      font-size:13px; font-weight:600; color:var(--sub); border-top:1px solid var(--line);
    }
    .group-head:first-child { border-top:0; padding-top:4px; }

    #toast {
      position:fixed; left:50%; bottom:26px; transform:translateX(-50%);
      background:var(--ink); color:var(--bg); padding:9px 18px; border-radius:9px;
      font-size:13px; opacity:0; pointer-events:none; transition:opacity .2s;
      max-width:80vw; z-index:60;
    }
    #toast.show { opacity:.95; }

    @media (max-width:720px) {
      header { padding:0 16px; gap:12px; }
      nav { order:3; width:100%; overflow-x:auto; }
      nav button { padding:12px 11px; }
      .prefs { margin-left:auto; }
      main { padding:18px 16px 60px; }
      .editor, form.add { grid-template-columns:1fr; }
      .flagcell { min-width:0; }
    }
    """
}
