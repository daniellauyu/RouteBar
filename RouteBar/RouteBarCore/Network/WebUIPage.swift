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
    nonisolated static let html = #"""
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
      .editor {
        display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin: 12px 0;
      }
      .field { display: flex; flex-direction: column; gap: 4px; }
      @media (max-width: 620px) {
        form.add, .editor { grid-template-columns: 1fr; }
      }
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
          <div class="metric"><b id="m-nodes">–</b><span class="dim">启用条目</span></div>
          <div class="metric"><b id="m-total">–</b><span class="dim">全部条目</span></div>
          <div class="metric"><b id="m-dedup">–</b><span class="dim">重复连接</span></div>
          <div class="metric"><b id="m-tested">–</b><span class="dim">已测速</span></div>
          <div class="metric"><b id="m-failed">–</b><span class="dim">测速失败</span></div>
        </div>
      </div>

      <div class="card">
        <div class="row between" style="margin-bottom:10px">
          <h2 style="margin:0">节点命名</h2>
          <span class="dim" id="naming-preview"></span>
        </div>
        <div class="row">
          <input id="naming-template" class="grow" placeholder="RouteBar {index} - {name}">
          <button id="btn-naming-test">测试</button>
          <button class="primary" id="btn-naming-save">保存</button>
          <button id="btn-naming-reset">恢复默认</button>
        </div>
        <div class="dim" id="naming-help" style="margin-top:8px"></div>
        <div class="dim" style="margin-top:4px">
          「测试」只按输入框里的模板试跑一遍，不保存。单条订阅可以在下面「编辑」里另设模板。
        </div>
        <div id="naming-result" hidden style="margin-top:10px"></div>
      </div>

      <div class="card">
        <div class="row between" style="margin-bottom:12px">
          <h2 style="margin:0">订阅</h2>
          <select id="sub-protocol-filter" style="width:120px"><option value="">全部协议</option></select>
        </div>
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
    // 正在编辑的订阅 id。轮询期间要避开它，否则 8 秒一到就把用户填了一半的表单刷掉。
    let editingId = null;

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
      // 本地服务是唯一的输出方式，这张卡片无条件显示
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

      renderNaming(data.naming);
      renderSubscriptions(data.subscriptions);
      renderNodes(data.nodes);
    }

    function renderNaming(naming) {
      const input = $('naming-template');
      // 轮询正好落在用户输入到一半时，覆盖输入框等于把人打断。聚焦时只更新说明。
      if (document.activeElement !== input) input.value = naming.template;
      input.placeholder = naming.defaultTemplate;
      $('naming-preview').textContent = naming.preview.join(' · ');
      $('naming-help').textContent =
        '可用占位符：' + naming.placeholders.map((p) => p.token + ' ' + p.summary).join('、');
    }

    function protocolText(protocol) {
      return { ss: 'SS', vmess: 'VMess', vless: 'VLESS', trojan: 'Trojan',
               hysteria2: 'Hysteria2' }[protocol] || protocol.toUpperCase();
    }

    function renderSubscriptions(list) {
      const container = $('subs');
      const picker = $('sub-protocol-filter');
      const selected = picker.value;
      const protocols = [...new Set(list.flatMap((sub) => sub.protocols || []))].sort();
      picker.replaceChildren(element('option', null, '全部协议'),
        ...protocols.map((protocol) => {
          const option = element('option', null, protocolText(protocol));
          option.value = protocol;
          return option;
        }));
      picker.firstChild.value = '';
      picker.value = protocols.includes(selected) ? selected : '';
      const visible = picker.value ? list.filter((sub) => (sub.protocols || []).includes(picker.value)) : list;
      if (!list.length) {
        container.replaceChildren(element('div', 'dim', '还没有订阅，在下面添加一个。'));
        return;
      }
      if (!visible.length) {
        container.replaceChildren(element('div', 'dim', '没有包含该协议的订阅。'));
        return;
      }
      // 打开的编辑器所属订阅已被删除时，关掉它，免得留在一个不存在的对象上。
      if (editingId && !list.some((s) => s.id === editingId)) editingId = null;

      container.replaceChildren(...visible.map((sub) => {
        const index = list.findIndex((item) => item.id === sub.id);
        if (sub.id === editingId) return subscriptionEditor(sub, index);

        const item = element('div', 'item row between' + (sub.enabled ? '' : ' off'));
        item.append(element('span', 'idx', String(index + 1)));
        const left = element('div', 'grow');
        left.append(element('div', null, sub.name));
        const meta = [sub.statusLabel, sub.nodeCount + ' 个节点', relative(sub.updatedAt),
                      '每 ' + sub.updateIntervalHours + ' 小时'];
        if (sub.protocols && sub.protocols.length) meta.splice(2, 0,
          sub.protocols.map(protocolText).join('/'));
        if (sub.note) meta.push(sub.note);
        if (sub.lastError) meta.push(sub.lastError);
        left.append(element('div', 'dim', meta.join(' · ')));
        const right = element('div', 'row');

        const edit = element('button', null, '编辑');
        edit.onclick = () => { editingId = sub.id; renderSubscriptions(list); };

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

        right.append(update, edit, toggle, remove);
        item.append(left, right);
        return item;
      }));
    }

    function labelled(text, input) {
      const wrap = element('label', 'field');
      wrap.append(element('span', 'dim', text), input);
      return wrap;
    }

    function subscriptionEditor(sub, index) {
      const box = element('div', 'item');
      const head = element('div', 'row');
      head.append(element('span', 'idx', String(index + 1)),
                  element('div', 'grow', '编辑「' + sub.name + '」'));
      box.append(head);

      const name = element('input');
      name.value = sub.name;
      name.required = true;

      const url = element('input');
      url.type = 'url';
      // 存下来的地址含机场凭据，只在钥匙串里，网页从不显示它。
      // 因此空值只能理解成「不改」，不能当成「清空」。
      url.placeholder = '留空则保持当前地址不变';

      const note = element('input');
      note.value = sub.note || '';
      note.placeholder = '可选';

      const interval = element('input');
      interval.type = 'number';
      interval.min = '1';
      interval.max = '168';
      interval.value = String(sub.updateIntervalHours);

      const template = element('input');
      template.value = sub.nodeNameTemplate || '';
      template.placeholder = (snapshot && snapshot.naming.template) || '留空跟随全局';

      const grid = element('div', 'editor');
      grid.append(labelled('名称', name), labelled('订阅地址', url),
                  labelled('备注', note), labelled('更新间隔（小时）', interval),
                  labelled('节点命名（留空跟随全局）', template));
      box.append(grid);

      const save = element('button', 'primary', '保存');
      save.onclick = async () => {
        const payload = {
          id: sub.id,
          name: name.value.trim(),
          note: note.value.trim(),
          intervalHours: Math.min(168, Math.max(1, parseInt(interval.value, 10) || sub.updateIntervalHours)),
          // 总是带上：空串在这里的意思是「清掉覆盖、跟随全局」，不是「不改」。
          nodeNameTemplate: template.value.trim(),
        };
        if (!payload.name) { toast('名称不能为空'); return; }
        const typed = url.value.trim();
        if (typed) payload.url = typed;
        const data = await call('/subscriptions', 'POST', payload);
        if (data) {
          editingId = null;
          render(data);
          toast('已保存，正在重新拉取节点…');
        }
      };

      const cancel = element('button', null, '取消');
      cancel.onclick = () => { editingId = null; renderSubscriptions(snapshot.subscriptions); };

      const actions = element('div', 'row');
      actions.append(save, cancel);
      actions.append(element('span', 'dim', '保存后会立即重新拉取这条订阅的节点。'));
      box.append(actions);
      return box;
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
        const item = element('div', 'item row between' + (node.effectiveEnabled ? '' : ' off'));
        item.append(element('span', 'idx', String(order.get(node.id))));
        const left = element('div', 'grow');
        const title = element('div', 'row');
        title.append(element('span', null, node.name));
        // 机场给的名字和 RouteBar 生成的名字是两回事（后者由命名模板拼），并排显示才对得上。
        if (node.outputName) {
          title.append(element('span', 'dim', '→'), element('span', 'mono', node.outputName));
        }
        left.append(title);
        const meta = element('div', 'dim');
        // 协议是上游的，本地端口是 RouteBar 造出来的壳——两者并列才说得清这一行是什么。
        const state = !node.subscriptionEnabled ? '订阅已停用' : (!node.enabled ? '已关闭' :
          (node.localPort ? '本地 ' + node.localPort : '等待配置'));
        meta.textContent = node.protocolLabel + ' · ' + (node.sources[0] || '未知来源') +
          ' · ' + state + ' · ' + node.server;
        left.append(meta);

        const right = element('div', 'row');
        right.append(element('span', 'lat ' + node.band, latencyText(node)));

        const toggle = element('button', null, node.enabled ? '停用' : '启用');
        toggle.onclick = () => act('/nodes/' + encodeURIComponent(node.id) + '/enabled', 'POST', { enabled: !node.enabled });

        const test = element('button', null, '测速');
        test.disabled = !node.effectiveEnabled;
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
    $('sub-protocol-filter').onchange = () => { if (snapshot) renderSubscriptions(snapshot.subscriptions); };

    async function saveNaming(template) {
      const data = await call('/naming', 'POST', { template });
      if (data) {
        $('naming-result').hidden = true;
        render(data);
        toast('已保存，输出的节点名已按新规则重新生成');
      }
    }

    // 试跑：服务端按传过去的模板算一遍名字，不保存任何东西。
    // 名字里的序号和重名补号都取决于整批节点，所以只能由服务端算，网页不自己拼。
    async function testNaming(template) {
      const data = await call('/naming/preview', 'POST', { template });
      if (!data) return;
      const box = $('naming-result');
      const head = element('div', 'dim', data.isSample
        ? '当前没有启用节点，下面是示例：'
        : data.rows.length + ' 个启用节点会变成：');
      const rows = data.rows.map((row, index) => {
        const line = element('div', 'item row');
        line.append(element('span', 'idx', String(index + 1)));
        line.append(element('div', 'grow', row.name));
        line.append(element('span', 'dim', '→'));
        line.append(element('div', 'grow mono', row.outputName));
        line.append(element('span', 'dim', String(row.localPort)));
        return line;
      });
      box.replaceChildren(head, ...rows);
      box.hidden = false;
    }

    $('btn-naming-test').onclick = () => testNaming($('naming-template').value.trim());
    $('btn-naming-save').onclick = () => saveNaming($('naming-template').value.trim());
    $('btn-naming-reset').onclick = () => saveNaming(snapshot ? snapshot.naming.defaultTemplate : '');
    $('naming-template').onkeydown = (event) => {
      if (event.key === 'Enter') testNaming($('naming-template').value.trim());
    };
    // 模板一改，上一次的试跑结果就不再对应输入框里的内容了，留着只会看错。
    $('naming-template').oninput = () => { $('naming-result').hidden = true; };

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
    // 编辑器开着时跳过——重绘会把填了一半的表单连同光标位置一起丢掉。
    setInterval(() => { if (!busy && !editingId) refresh(); }, 8000);
    </script>
    </body>
    </html>
    """#
}
