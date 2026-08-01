import Foundation

/// 内嵌的 Web 界面。
///
/// 整页塞在一个字符串里，不走 bundle 资源：这样它跟着二进制走，不存在「资源没打进去
/// 导致运行时 404」这一类只在打包后才暴露的问题，也免去为 SwiftPM 与 Xcode 各配一次
/// resource 规则。页面本身没有任何外部依赖——没有 CDN、没有字体、没有图片。
///
/// 令牌不内联进页面，而是由脚本从自身 URL（`/<token>/`）里读出来。内联的话，
/// 任何把 HTML 存下来或贴出去的动作都会连令牌一起泄露。
enum WebUIPage {
    static let html = #"""
    <!doctype html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="referrer" content="no-referrer">
    <title>RouteBar</title>
    <style>
      :root {
        --bg: #f5f5f7; --card: #ffffff; --text: #1d1d1f; --dim: #6e6e73;
        --line: rgba(0,0,0,.09); --accent: #0a84ff;
        --ok: #34c759; --warn: #ff9f0a; --bad: #ff3b30; --mid: #ffcc00;
        --shadow: 0 1px 3px rgba(0,0,0,.06);
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #1c1c1e; --card: #2c2c2e; --text: #f5f5f7; --dim: #98989d;
          --line: rgba(255,255,255,.12); --shadow: none;
        }
      }
      * { box-sizing: border-box; }
      body {
        margin: 0; background: var(--bg); color: var(--text);
        font: 14px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
      }
      .wrap { max-width: 900px; margin: 0 auto; padding: 24px 20px 60px; }
      h1 { font-size: 20px; margin: 0; font-weight: 600; }
      h2 { font-size: 15px; margin: 0 0 12px; font-weight: 600; }
      .card {
        background: var(--card); border: 1px solid var(--line); border-radius: 12px;
        padding: 16px; margin-bottom: 16px; box-shadow: var(--shadow);
      }
      .row { display: flex; align-items: center; gap: 12px; }
      .between { justify-content: space-between; }
      .grow { flex: 1; min-width: 0; }
      .dim { color: var(--dim); font-size: 12px; }
      .mono {
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        font-size: 12px; word-break: break-all;
      }
      button {
        font: inherit; font-size: 13px; padding: 5px 12px; border-radius: 7px;
        border: 1px solid var(--line); background: var(--card); color: var(--text);
        cursor: pointer; white-space: nowrap;
      }
      button:hover:not(:disabled) { border-color: var(--accent); color: var(--accent); }
      button:disabled { opacity: .4; cursor: default; }
      button.primary { background: var(--accent); color: #fff; border-color: transparent; }
      button.primary:hover:not(:disabled) { color: #fff; opacity: .9; }
      button.danger:hover:not(:disabled) { border-color: var(--bad); color: var(--bad); }
      input, select {
        font: inherit; font-size: 13px; padding: 6px 9px; border-radius: 7px;
        border: 1px solid var(--line); background: var(--bg); color: var(--text); width: 100%;
      }
      .dot { width: 9px; height: 9px; border-radius: 50%; flex: none; }
      .running { background: var(--ok); } .stopped { background: var(--dim); }
      .needsAttention { background: var(--warn); } .failed { background: var(--bad); }
      .item { padding: 11px 0; border-top: 1px solid var(--line); }
      .item:first-of-type { border-top: none; }
      .tag {
        font-size: 11px; padding: 2px 7px; border-radius: 5px;
        background: var(--bg); color: var(--dim); border: 1px solid var(--line);
      }
      .lat { font-variant-numeric: tabular-nums; font-size: 12px; }
      .lat.fast { color: var(--ok); } .lat.medium { color: var(--warn); }
      .lat.slow { color: var(--bad); } .lat.failed { color: var(--bad); }
      .lat.untested { color: var(--dim); }
      .off { opacity: .45; }
      .idx {
        flex: none; width: 26px; text-align: right; color: var(--dim);
        font-size: 12px; font-variant-numeric: tabular-nums;
      }
      .health { color: var(--warn); font-size: 13px; padding: 3px 0; }
      .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(84px, 1fr)); gap: 12px; }
      .metric b { display: block; font-size: 20px; font-weight: 600; font-variant-numeric: tabular-nums; }
      .scroll { overflow-x: auto; }
      #toast {
        position: fixed; left: 50%; bottom: 26px; transform: translateX(-50%);
        background: var(--text); color: var(--bg); padding: 9px 18px; border-radius: 9px;
        font-size: 13px; opacity: 0; pointer-events: none; transition: opacity .2s; max-width: 80vw;
      }
      #toast.show { opacity: .95; }
      form.add { display: grid; grid-template-columns: 1fr 1fr auto; gap: 8px; margin-top: 12px; }
      @media (max-width: 620px) { form.add { grid-template-columns: 1fr; } }
    </style>
    </head>
    <body>
    <div class="wrap">

      <div class="row between" style="margin-bottom:18px">
        <div class="row">
          <span class="dot" id="overall-dot"></span>
          <div>
            <h1>RouteBar</h1>
            <div class="dim" id="summary">正在加载…</div>
          </div>
        </div>
        <div class="row">
          <button id="btn-update">更新订阅</button>
          <button id="btn-regen" class="primary">重新生成</button>
        </div>
      </div>

      <div class="card" id="health-card" hidden>
        <h2>待处理</h2>
        <div id="health"></div>
      </div>

      <div class="card" id="sub-card" hidden>
        <div class="row between" style="margin-bottom:10px">
          <h2 style="margin:0">本地订阅地址</h2>
          <span class="tag" id="serve-state"></span>
        </div>
        <div class="mono" id="sub-url" style="padding:8px 0"></div>
        <div class="dim" style="margin:8px 0 6px">在 Surge 策略组里这样用：</div>
        <div class="mono scroll" id="policy-line" style="padding-bottom:10px;white-space:nowrap"></div>
        <div class="row">
          <button id="btn-copy-url">复制地址</button>
          <button id="btn-copy-line">复制策略组行</button>
        </div>
      </div>

      <div class="card">
        <div class="row between">
          <div class="row">
            <span class="dot" id="svc-dot"></span>
            <div>
              <div id="svc-label" style="font-weight:500">sing-box</div>
              <div class="dim mono" id="svc-agent"></div>
            </div>
          </div>
          <div class="row">
            <button id="btn-svc"></button>
            <button id="btn-refresh">刷新</button>
          </div>
        </div>
        <div class="grid" style="margin-top:16px">
          <div class="metric"><b id="m-nodes">–</b><span class="dim">启用节点</span></div>
          <div class="metric"><b id="m-total">–</b><span class="dim">去重后</span></div>
          <div class="metric"><b id="m-dedup">–</b><span class="dim">已去重</span></div>
          <div class="metric"><b id="m-tested">–</b><span class="dim">已测速</span></div>
          <div class="metric"><b id="m-failed">–</b><span class="dim">测速失败</span></div>
        </div>
      </div>

      <div class="card">
        <h2>订阅</h2>
        <div id="subs"></div>
        <form class="add" id="add-form">
          <input id="add-name" placeholder="名称" required>
          <input id="add-url" placeholder="订阅地址（https://…）" required type="url">
          <button class="primary" type="submit">添加</button>
        </form>
      </div>

      <div class="card">
        <div class="row between" style="margin-bottom:12px">
          <h2 style="margin:0">节点 <span class="dim" id="node-count"></span></h2>
          <div class="row">
            <input id="filter" placeholder="筛选…" style="width:150px">
            <button id="btn-test">全部测速</button>
          </div>
        </div>
        <div id="nodes"></div>
      </div>

    </div>
    <div id="toast"></div>

    <script>
    // 令牌来自自身路径 /<token>/ —— 不内联进页面，存下来或贴出去都不会连令牌一起泄露。
    const TOKEN = location.pathname.split('/').filter(Boolean)[0] || '';
    const API = '/' + TOKEN + '/api';
    const $ = (id) => document.getElementById(id);
    let snapshot = null, busy = false;

    function toast(text) {
      const el = $('toast');
      el.textContent = text;
      el.classList.add('show');
      clearTimeout(el._timer);
      el._timer = setTimeout(() => el.classList.remove('show'), 2600);
    }

    // 所有写操作都带 application/json：服务端据此拒绝跨源的简单请求。
    async function call(path, method = 'GET', body) {
      if (busy) return null;
      busy = true;
      document.querySelectorAll('button').forEach((b) => { b.disabled = true; });
      try {
        const response = await fetch(API + path, {
          method,
          headers: { 'Content-Type': 'application/json' },
          body: body === undefined ? undefined : JSON.stringify(body),
        });
        const text = await response.text();
        const data = text ? JSON.parse(text) : null;
        if (!response.ok) throw new Error((data && data.error) || ('HTTP ' + response.status));
        return data;
      } catch (error) {
        toast(error.message || '请求失败');
        return null;
      } finally {
        busy = false;
        document.querySelectorAll('button').forEach((b) => { b.disabled = false; });
      }
    }

    async function act(path, method, body) {
      const data = await call(path, method, body);
      if (data) render(data);
    }

    function relative(iso) {
      if (!iso) return '从未更新';
      const seconds = (Date.now() - new Date(iso).getTime()) / 1000;
      if (seconds < 60) return '刚刚';
      if (seconds < 3600) return Math.floor(seconds / 60) + ' 分钟前';
      if (seconds < 86400) return Math.floor(seconds / 3600) + ' 小时前';
      return Math.floor(seconds / 86400) + ' 天前';
    }

    function latencyText(node) {
      if (node.band === 'untested') return '未测速';
      if (node.band === 'failed') return node.latencyLabel || '失败';
      return node.latencyMilliseconds + ' ms';
    }

    function element(tag, className, text) {
      const node = document.createElement(tag);
      if (className) node.className = className;
      // 一律走 textContent：节点名与订阅名来自机场，是不可信输入。
      if (text !== undefined) node.textContent = text;
      return node;
    }

    function render(data) {
      snapshot = data;

      $('overall-dot').className = 'dot ' + data.overall;
      $('summary').textContent = data.summary;

      $('health-card').hidden = data.health.length === 0;
      const health = $('health');
      health.replaceChildren(...data.health.map((line) => element('div', 'health', '⚠ ' + line)));

      const output = data.output;
      $('sub-card').hidden = !output.servesSubscription;
      $('serve-state').textContent = output.serving ? '服务中' : (output.error || '未启动');
      $('sub-url').textContent = output.subscriptionURL;
      $('policy-line').textContent = output.surgePolicyLine;

      $('svc-dot').className = 'dot ' + (data.service.running ? 'running' : 'stopped');
      $('svc-label').textContent = 'sing-box ' + data.service.label +
        (data.service.failureReason ? ' — ' + data.service.failureReason : '');
      $('svc-agent').textContent = data.service.launchAgentLabel;
      $('btn-svc').textContent = data.service.running ? '停止' : '启动';

      $('m-nodes').textContent = data.counts.enabledNodes;
      $('m-total').textContent = data.counts.nodes;
      $('m-dedup').textContent = data.counts.deduplicated;
      $('m-tested').textContent = data.counts.tested;
      $('m-failed').textContent = data.counts.failedLatency;

      renderSubscriptions(data.subscriptions);
      renderNodes(data.nodes);
    }

    function renderSubscriptions(list) {
      const container = $('subs');
      if (!list.length) {
        container.replaceChildren(element('div', 'dim', '还没有订阅，在下面添加一个。'));
        return;
      }
      container.replaceChildren(...list.map((sub, index) => {
        const item = element('div', 'item row between' + (sub.enabled ? '' : ' off'));
        item.append(element('span', 'idx', String(index + 1)));
        const left = element('div', 'grow');
        left.append(element('div', null, sub.name));
        const meta = [sub.statusLabel, sub.nodeCount + ' 个节点', relative(sub.updatedAt)];
        if (sub.lastError) meta.push(sub.lastError);
        left.append(element('div', 'dim', meta.join(' · ')));
        const right = element('div', 'row');

        const toggle = element('button', null, sub.enabled ? '停用' : '启用');
        toggle.onclick = () => act('/subscriptions/' + sub.id + '/enabled', 'POST', { enabled: !sub.enabled });

        const update = element('button', null, '更新');
        update.onclick = () => act('/subscriptions/' + sub.id + '/update', 'POST', {});

        const remove = element('button', 'danger', '删除');
        remove.onclick = () => {
          if (confirm('删除订阅「' + sub.name + '」？')) {
            act('/subscriptions/' + sub.id, 'DELETE', undefined);
          }
        };

        right.append(update, toggle, remove);
        item.append(left, right);
        return item;
      }));
    }

    function renderNodes(nodes) {
      const keyword = $('filter').value.trim().toLowerCase();
      // 序号取自完整列表中的位置，筛选时保留原号而不是重新从 1 排。
      // 重排的话网页上的「4」和 `routebar test 4` 就不是同一个节点——
      // 序号要指向节点本身，不能只是行号。
      const order = new Map(nodes.map((node, index) => [node.id, index + 1]));
      const visible = keyword
        ? nodes.filter((n) => n.name.toLowerCase().includes(keyword) || n.server.toLowerCase().includes(keyword))
        : nodes;
      $('node-count').textContent = keyword ? visible.length + ' / ' + nodes.length : nodes.length;

      const container = $('nodes');
      if (!visible.length) {
        container.replaceChildren(element('div', 'dim', nodes.length ? '没有匹配的节点。' : '还没有节点，先添加并更新订阅。'));
        return;
      }
      container.replaceChildren(...visible.map((node) => {
        const item = element('div', 'item row between' + (node.enabled ? '' : ' off'));
        item.append(element('span', 'idx', String(order.get(node.id))));
        const left = element('div', 'grow');
        left.append(element('div', null, node.name));
        const meta = element('div', 'dim');
        meta.textContent = node.server + (node.localPort ? ' · 本地 ' + node.localPort : '');
        left.append(meta);

        const right = element('div', 'row');
        right.append(element('span', 'lat ' + node.band, latencyText(node)));

        const toggle = element('button', null, node.enabled ? '停用' : '启用');
        toggle.onclick = () => act('/nodes/' + encodeURIComponent(node.id) + '/enabled', 'POST', { enabled: !node.enabled });

        const test = element('button', null, '测速');
        test.disabled = !node.enabled;
        test.onclick = () => act('/nodes/' + encodeURIComponent(node.id) + '/test', 'POST', {});

        right.append(test, toggle);
        item.append(left, right);
        return item;
      }));
    }

    async function copy(text, label) {
      try {
        await navigator.clipboard.writeText(text);
        toast(label + '已复制');
      } catch {
        toast('复制失败，请手动选中');
      }
    }

    $('btn-update').onclick = () => act('/update', 'POST', {});
    $('btn-regen').onclick = () => act('/regenerate', 'POST', {});
    $('btn-test').onclick = () => act('/nodes/test', 'POST', {});
    $('btn-refresh').onclick = () => act('/service/refresh', 'POST', {});
    $('btn-svc').onclick = () =>
      act('/service/' + (snapshot && snapshot.service.running ? 'stop' : 'start'), 'POST', {});
    $('btn-copy-url').onclick = () => copy(snapshot.output.subscriptionURL, '订阅地址');
    $('btn-copy-line').onclick = () => copy(snapshot.output.surgePolicyLine, '策略组行');
    $('filter').oninput = () => { if (snapshot) renderNodes(snapshot.nodes); };

    $('add-form').onsubmit = async (event) => {
      event.preventDefault();
      const name = $('add-name').value.trim();
      const url = $('add-url').value.trim();
      if (!name || !url) return;
      const data = await call('/subscriptions', 'POST', { name, url, intervalHours: 6 });
      if (data) {
        $('add-name').value = '';
        $('add-url').value = '';
        render(data);
        toast('已添加，正在拉取节点…');
      }
    };

    async function refresh() {
      const data = await call('/state');
      if (data) render(data);
    }

    refresh();
    // 定时轮询，好让菜单栏应用里做的改动、以及后台的定时更新都能反映到页面上。
    setInterval(() => { if (!busy) refresh(); }, 8000);
    </script>
    </body>
    </html>
    """#
}
