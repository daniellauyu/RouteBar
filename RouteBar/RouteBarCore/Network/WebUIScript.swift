import Foundation

/// Web 界面的脚本。
///
/// 和结构、样式、文案分开放；四样混在一处时，改一句文案要在六百行里找。
///
/// 一律用 `textContent` 而不是 `innerHTML` 构造节点：节点名和订阅名来自机场，
/// 是不可信输入，拼进 HTML 就是一个存储型 XSS——而这个页面上有能改配置、起停服务的接口。
enum WebUIScript {
    nonisolated static let js = #"""
    /* 令牌来自自身路径 /<token>/ —— 不内联进页面，存下来或贴出去都不会连令牌一起泄露。 */
    const TOKEN = location.pathname.split('/').filter(Boolean)[0] || '';
    const API = '/' + TOKEN + '/api';
    const $ = (id) => document.getElementById(id);

    let snapshot = null;
    let busy = false;
    let currentTab = 'overview';
    let lang = 'zh';
    let langPreference = 'auto';
    /* 正在编辑的订阅 id。轮询期间要避开它，否则 8 秒一到就把填了一半的表单刷掉。 */
    let editingId = null;
    const subscriptionDrafts = new Map();
    let namingDirty = false;
    let regionsDirty = false;
    let scriptDirty = false;
    let scriptLoaded = false;
    let scriptTimer = null;
    /* 边打字边跑时，慢的那次可能后返回。带序号，过期的响应直接丢掉，
       否则画面会闪回到几次之前的结果。 */
    let scriptSeq = 0;
    /* 上一次跑通的行。语法写到一半必然报错，这时把已有结果全清掉会让编辑器下面
       一片空白——留着上次的，只在顶上标一行「这是旧结果」。 */
    let scriptLastRows = null;
    /* 目标可达的上一次结果。只活在这一页，刷新快照不会动它。 */
    let probeResponse = null;
    let probing = false;

    /* ══════════ 文案 ══════════ */

    /* 语言由**看页面的人**当场选，不跟着 Mac 的语言走 ——
       Mac 是中文、想在英文环境下截图给别人看，是完全正常的组合。 */
    function t(key, ...args) {
      const table = I18N[lang] || I18N.zh;
      let text = table[key] !== undefined ? table[key] : (I18N.zh[key] !== undefined ? I18N.zh[key] : key);
      for (let i = 0; i < args.length; i++) text = text.split('{' + i + '}').join(args[i]);
      return text;
    }

    /* 切语言不重载页面：重载会把正在填的表单和已经跑出来的测试结果一起冲掉。 */
    function applyStrings() {
      document.documentElement.lang = lang === 'en' ? 'en' : 'zh-CN';
      document.querySelectorAll('[data-i18n]').forEach((el) => {
        el.textContent = t(el.getAttribute('data-i18n'));
      });
      document.querySelectorAll('[data-i18n-ph]').forEach((el) => {
        el.placeholder = t(el.getAttribute('data-i18n-ph'));
      });
    }

    function browserLanguage() {
      return (navigator.language || '').slice(0, 2).toLowerCase() === 'zh' ? 'zh' : 'en';
    }

    function setLang(next) {
      langPreference = next === 'zh' || next === 'en' ? next : 'auto';
      lang = langPreference === 'auto' ? browserLanguage() : langPreference;
      try { localStorage.setItem('routebar.lang', langPreference); } catch (e) {}
      const picker = $('pref-lang');
      if (picker) picker.value = langPreference;
      applyStrings();
      /* 动态渲染的那几处不带 data-i18n，得重画。 */
      if (snapshot) render(snapshot);
      renderProbeResults();
    }

    /* ══════════ 主题 ══════════ */

    /* 三态：跟随系统时**不写 data-theme**，交给 prefers-color-scheme；显式选了才写，
       这样「日间」在夜间系统上也按得住（见样式表里的注释）。 */
    function setTheme(next) {
      next = next === 'light' || next === 'dark' ? next : 'auto';
      try { localStorage.setItem('routebar.theme', next); } catch (e) {}
      if (next === 'auto') document.documentElement.removeAttribute('data-theme');
      else document.documentElement.setAttribute('data-theme', next);
      const use = document.querySelector('#pref-theme-icon use');
      if (use) use.setAttribute('href', '#i-' + (next === 'light' ? 'sun' : next === 'dark' ? 'moon' : 'appearance'));
      const value = $('pref-theme-value');
      if (value) {
        value.setAttribute('data-i18n', 'pref.theme.' + next);
        value.textContent = t('pref.theme.' + next);
      }
      document.querySelectorAll('[data-theme-option]').forEach((option) => {
        const selected = option.getAttribute('data-theme-option') === next;
        option.classList.toggle('selected', selected);
        option.setAttribute('aria-checked', selected ? 'true' : 'false');
      });
    }

    function closeThemeMenu() {
      const menu = $('pref-theme-menu');
      const trigger = $('pref-theme');
      if (menu) menu.classList.remove('open');
      if (trigger) trigger.setAttribute('aria-expanded', 'false');
    }

    function toggleThemeMenu(event) {
      if (event) event.stopPropagation();
      const menu = $('pref-theme-menu');
      const trigger = $('pref-theme');
      if (!menu || !trigger) return;
      const opening = !menu.classList.contains('open');
      menu.classList.toggle('open', opening);
      trigger.setAttribute('aria-expanded', opening ? 'true' : 'false');
    }

    function chooseTheme(next, event) {
      if (event) event.stopPropagation();
      setTheme(next);
      closeThemeMenu();
    }

    document.addEventListener('click', closeThemeMenu);
    document.addEventListener('keydown', (event) => { if (event.key === 'Escape') closeThemeMenu(); });

    /* ══════════ 标签页图标 ══════════ */

    /* 图标画在浏览器的标签栏里，不在页面里，所以跟的是**系统配色**而不是上面那个主题
       选择器：页面选「日间」时标签栏照样可能是深色的。整张图换掉，不改 SVG 里的颜色——
       favicon 在 Chrome / Safari 里当静态图片渲染，改不到它内部的样式。 */
    const systemDark = window.matchMedia('(prefers-color-scheme: dark)');

    /* 换的是整个 <link> 而不是它的 href：只改 href 时 Safari 常常不重画标签页。 */
    function syncFavicon() {
      const previous = $('favicon');
      const link = document.createElement('link');
      link.id = 'favicon';
      link.rel = 'icon';
      link.type = 'image/svg+xml';
      link.href = systemDark.matches ? FAVICONS.dark : FAVICONS.light;
      if (previous) previous.remove();
      document.head.appendChild(link);
    }

    if (systemDark.addEventListener) systemDark.addEventListener('change', syncFavicon);
    else if (systemDark.addListener) systemDark.addListener(syncFavicon);

    /* ══════════ 分页 ══════════ */

    function showTab(id) {
      currentTab = id;
      document.querySelectorAll('[data-page]').forEach((section) => {
        section.hidden = section.getAttribute('data-page') !== id;
      });
      document.querySelectorAll('nav [data-tab]').forEach((button) => {
        button.classList.toggle('on', button.getAttribute('data-tab') === id);
      });
      try { localStorage.setItem('routebar.tab', id); } catch (e) {}
    }

    /* ══════════ 基础设施 ══════════ */

    function toast(text) {
      const el = $('toast');
      el.textContent = text;
      el.classList.add('show');
      clearTimeout(el._timer);
      el._timer = setTimeout(() => el.classList.remove('show'), 2600);
    }

    /* 所有写操作都带 application/json：服务端据此拒绝跨源的简单请求。 */
    async function call(path, method = 'GET', body) {
      if (busy) return null;
      busy = true;
      const blockedButtons = [...document.querySelectorAll('button')].filter((b) =>
        !b.closest('nav') && !b.hasAttribute('data-tab') &&
        !['btn-copy-url', 'btn-copy-line'].includes(b.id) && !b.disabled);
      blockedButtons.forEach((b) => { b.disabled = true; });
      const controller = new AbortController();
      const deadline = setTimeout(() => controller.abort(), method === 'GET' ? 30000 : 600000);
      try {
        const response = await fetch(API + path, {
          method,
          signal: controller.signal,
          headers: { 'Content-Type': 'application/json' },
          body: body === undefined ? undefined : JSON.stringify(body),
        });
        const text = await response.text();
        const data = text ? JSON.parse(text) : null;
        if (!response.ok) throw new Error((data && data.error) || ('HTTP ' + response.status));
        return data;
      } catch (error) {
        toast(error.name === 'AbortError'
          ? (lang === 'en' ? 'Request timed out; the operation may still be running. Refresh its status before retrying.'
                           : '请求等待超时，操作可能仍在后台执行，请先刷新状态再重试。')
          : (error.message || t('common.requestFailed')));
        return null;
      } finally {
        clearTimeout(deadline);
        busy = false;
        blockedButtons.forEach((b) => { b.disabled = false; });
      }
    }

    async function act(path, method, body) {
      const data = await call(path, method, body);
      if (data) render(data);
    }

    function element(tag, className, text) {
      const node = document.createElement(tag);
      if (className) node.className = className;
      /* 一律走 textContent：节点名与订阅名来自机场，是不可信输入。 */
      if (text !== undefined) node.textContent = text;
      return node;
    }

    function option(value, label) {
      const node = element('option', null, label);
      node.value = value;
      return node;
    }

    /* 重建下拉时保住当前选中项：筛选条每次快照都会重画，不保的话
       8 秒一到用户刚选的「只看新加坡」就跳回「全部」。 */
    function fillSelect(select, options, fallback) {
      const previous = select.value;
      select.replaceChildren(...options.map((item) => option(item[0], item[1])));
      const values = options.map((item) => item[0]);
      select.value = values.indexOf(previous) >= 0 ? previous : fallback;
    }

    function relative(iso) {
      if (!iso) return t('sb.never');
      const seconds = (Date.now() - new Date(iso).getTime()) / 1000;
      if (seconds < 60) return t('sb.justNow');
      if (seconds < 3600) return t('sb.minutesAgo', Math.floor(seconds / 60));
      if (seconds < 86400) return t('sb.hoursAgo', Math.floor(seconds / 3600));
      return t('sb.daysAgo', Math.floor(seconds / 86400));
    }

    function latencyText(node) {
      if (node.band === 'untested') return t('lat.untested');
      if (node.band === 'failed') return t('lat.' + (node.latencyOutcome || 'connectionFailed'));
      return node.latencyMilliseconds + ' ms';
    }

    function protocolText(protocol) {
      return { ss: 'SS', vmess: 'VMess', vless: 'VLESS', trojan: 'Trojan',
               hysteria2: 'Hysteria2' }[protocol] || protocol.toUpperCase();
    }

    /* 落地地区名。服务端把中英两份都发过来了，这里只是挑一份 —— 网页自带一份
       两百多条的国家码对照表不但要维护，还会和系统的叫法不一致。 */
    function geoName(geo) {
      if (!geo) return '';
      return (lang === 'en' ? geo.nameEN : geo.nameZH) || geo.code || geo.ip;
    }

    function geoCell(geo) {
      const cell = element('span', 'flagcell');
      if (!geo) { cell.textContent = t('nd.geo.none'); return cell; }
      if (!geo.ok) { cell.textContent = t('nd.geo.failed'); return cell; }
      if (geo.flag) cell.append(element('span', 'flag', geo.flag), document.createTextNode(' '));
      cell.append(document.createTextNode(geoName(geo)));
      cell.title = geo.ip;
      return cell;
    }

    /* 落地国家和节点名对不上就标出来 —— 这正是做落地探测的原因。
       机场的命名五花八门（新加坡/狮城/SG/Singapore 都有），所以这只是提示，
       两个字段在界面上并排摆着，最终由人判断。 */
    function geoMismatch(node) {
      const geo = node.geo;
      if (!geo || !geo.ok || !geo.code) return false;
      const haystack = (node.name || '').toLowerCase();
      return ![geo.code, geo.nameZH, geo.nameEN]
        .filter(Boolean)
        .some((candidate) => haystack.includes(String(candidate).toLowerCase()));
    }

    /* ══════════ 渲染 ══════════ */

    function render(data) {
      snapshot = data;

      $('overall-dot').className = 'dot ' + data.overall;

      $('health-card').hidden = data.health.length === 0;
      $('health').replaceChildren(...data.health.map((issue) => {
        /* 认得的码用自己的文案（可以切英文），认不出的退回服务端给的中文句子 ——
           页面被缓存住、而服务端已经新增了一种结论时，走的就是这条路。 */
        const key = 'health.' + issue.code;
        const text = I18N[lang] && I18N[lang][key] ? t(key, ...(issue.args || [])) : issue.text;
        return element('div', 'health', '⚠ ' + text);
      }));

      const output = data.output;
      const serve = $('serve-state');
      serve.textContent = output.serving ? t('ov.output.serving') : (output.error || t('ov.output.stopped'));
      serve.className = 'tag ' + (output.serving ? 'ok' : 'bad');
      $('sub-url').textContent = output.subscriptionURL;
      $('policy-line').textContent = output.surgePolicyLine;

      $('svc-dot').className = 'dot ' + (data.service.running ? 'running' : 'stopped');
      $('svc-label').textContent = data.service.label +
        (data.service.failureReason ? ' — ' + data.service.failureReason : '');
      $('svc-agent').textContent = t('ov.service.agent') + ': ' + data.service.launchAgentLabel;
      $('btn-svc').textContent = data.service.running ? t('ov.service.stop') : t('ov.service.start');

      $('m-nodes').textContent = data.counts.enabledNodes;
      $('m-total').textContent = data.counts.nodes;
      $('m-dedup').textContent = data.counts.deduplicated;
      $('m-tested').textContent = data.counts.tested;
      $('m-failed').textContent = data.counts.failedLatency;

      renderNaming(data.naming);
      renderSubscriptions(data.subscriptions);
      renderNodeFilters(data);
      renderNodes(data.nodes);
      renderGeoGroups(data.nodes);
      renderProbeScope(data.nodes);
    }

    /* ---------- 节点 ---------- */

    function renderNodeFilters(data) {
      fillSelect($('nd-sub'),
        [['', t('nd.allSubs')]].concat(data.subscriptions.map((s) => [s.id, s.name])), '');

      const protocols = [...new Set(data.nodes.map((n) => n.protocolLabel))].sort();
      fillSelect($('nd-proto'),
        [['', t('nd.allProtocols')]].concat(protocols.map((p) => [p, p])), '');

      /* 地区筛选按**实测落地**，不是节点名里写的地区 —— 名字对不上正是要找的东西。 */
      const regions = [...new Set(data.nodes.filter((n) => n.geo && n.geo.ok && n.geo.code)
        .map((n) => n.geo.code))].sort();
      fillSelect($('nd-region'),
        [['', t('nd.allRegions')]].concat(regions.map((code) => {
          const sample = data.nodes.find((n) => n.geo && n.geo.code === code);
          return [code, (sample.geo.flag ? sample.geo.flag + ' ' : '') + geoName(sample.geo)];
        })), '');

      fillSelect($('nd-lat'), [
        ['', t('nd.allLatency')], ['fast', t('nd.lat.fast')], ['medium', t('nd.lat.medium')],
        ['slow', t('nd.lat.slow')], ['failed', t('nd.lat.failed')], ['untested', t('nd.lat.untested')],
      ], '');

      fillSelect($('nd-sort'), [
        ['name', t('nd.sort.name')], ['latency', t('nd.sort.latency')], ['region', t('nd.sort.region')],
      ], 'name');

      fillSelect($('sub-proto'),
        [['', t('nd.allProtocols')]].concat(
          [...new Set(data.subscriptions.flatMap((s) => s.protocols || []))].sort()
            .map((p) => [p, protocolText(p)])), '');
    }

    function filteredNodes(nodes) {
      const keyword = $('nd-search').value.trim().toLowerCase();
      const sub = $('nd-sub').value;
      const proto = $('nd-proto').value;
      const region = $('nd-region').value;
      const band = $('nd-lat').value;
      const sort = $('nd-sort').value || 'name';

      const visible = nodes.filter((node) => {
        if (keyword && !(node.name.toLowerCase().includes(keyword)
            || node.server.toLowerCase().includes(keyword))) return false;
        /* 按订阅 id 比而不是名字：两条订阅完全可以重名，按名字筛会把别人的节点一起带出来。 */
        if (sub && node.sourceID !== sub) return false;
        if (proto && node.protocolLabel !== proto) return false;
        if (region && !(node.geo && node.geo.code === region)) return false;
        if (band && node.band !== band) return false;
        return true;
      });

      return visible.sort((a, b) => {
        if (sort === 'latency') {
          /* 未测速的排最后，否则它们会以 0 ms 霸占榜首。 */
          const left = a.latencyMilliseconds === undefined ? Infinity : a.latencyMilliseconds;
          const right = b.latencyMilliseconds === undefined ? Infinity : b.latencyMilliseconds;
          if (left !== right) return left - right;
        } else if (sort === 'region') {
          const left = (a.geo && a.geo.code) || '￿';
          const right = (b.geo && b.geo.code) || '￿';
          if (left !== right) return left < right ? -1 : 1;
        }
        return a.name.localeCompare(b.name, lang === 'en' ? 'en' : 'zh-Hans');
      });
    }

    function renderNodes(nodes) {
      const container = $('nodes');
      if (!nodes.length) {
        container.replaceChildren(element('div', 'empty', t('nd.empty')));
        $('node-count').textContent = '';
        return;
      }
      /* 序号取自完整列表中的位置，筛选时保留原号而不是重新从 1 排 ——
         网页上的「4」和 `routebar test 4` 必须是同一个节点。
         服务端给的这份顺序与端口分配同源，所以不筛选时它就是顺的。 */
      const order = new Map(nodes.map((node, index) => [node.id, index + 1]));
      const visible = filteredNodes(nodes);
      $('node-count').textContent = visible.length === nodes.length
        ? t('nd.count', nodes.length)
        : t('nd.countFiltered', visible.length, nodes.length);

      if (!visible.length) {
        container.replaceChildren(element('div', 'empty', t('nd.noMatch')));
        return;
      }
      container.replaceChildren(...visible.map((node) => nodeRow(node, order.get(node.id))));
    }

    function nodeRow(node, index) {
      const item = element('div', 'item' + (node.effectiveEnabled ? '' : ' off'));
      item.append(element('span', 'idx', String(index)));

      const left = element('div', 'grow');
      const title = element('div', 'row');
      title.append(element('span', null, node.name));
      /* 机场给的名字和 RouteBar 生成的名字是两回事（后者由命名模板拼），
         并排显示才对得上策略组里看到的那个。 */
      if (node.outputName) {
        title.append(element('span', 'dim', '→'));
        const output = element('span', 'mono ellipsis', node.outputName);
        output.title = t('nd.outputHint');
        title.append(output);
      }
      if (geoMismatch(node)) {
        const flag = element('span', 'tag warn', '≠');
        flag.title = t('nd.geo.mismatch');
        title.append(flag);
      }
      left.append(title);

      const state = !node.subscriptionEnabled ? t('nd.state.subDisabled')
        : (!node.enabled ? t('nd.state.off')
        : (node.localPort ? t('nd.state.port', node.localPort) : t('nd.state.waiting')));
      left.append(element('div', 'dim ellipsis',
        [node.protocolLabel, node.sources[0], state, node.server].filter(Boolean).join(' · ')));
      item.append(left);

      item.append(geoCell(node.geo));
      item.append(element('span', 'lat ' + node.band, latencyText(node)));

      const test = element('button', 'ghost small', t('common.test'));
      test.disabled = !node.effectiveEnabled;
      test.onclick = () => act('/nodes/' + encodeURIComponent(node.id) + '/test', 'POST', {});

      const geo = element('button', 'ghost small', t('nd.geo.probe'));
      geo.disabled = !node.effectiveEnabled;
      geo.onclick = () => act('/nodes/' + encodeURIComponent(node.id) + '/geo', 'POST', {});

      const toggle = element('button', 'ghost small',
        node.enabled ? t('common.disable') : t('common.enable'));
      toggle.onclick = () => act('/nodes/' + encodeURIComponent(node.id) + '/enabled', 'POST',
        { enabled: !node.enabled });

      const actions = element('div', 'row');
      actions.append(test, geo, toggle);
      item.append(actions);
      return item;
    }

    /* ---------- 落地分组 ---------- */

    function renderGeoGroups(nodes) {
      const container = $('geo-groups');
      const probed = nodes.filter((n) => n.geo && n.geo.ok);
      if (!probed.length) {
        container.replaceChildren(element('div', 'empty', t('nt.geo.unprobed')));
        return;
      }
      const groups = new Map();
      probed.forEach((node) => {
        const key = node.geo.code || '?';
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(node);
      });
      /* 节点多的国家排前面：要找「新加坡有哪些出口」时，那一组通常也是最大的一组。 */
      const sorted = [...groups.entries()].sort((a, b) => b[1].length - a[1].length);

      const children = [];
      const mismatched = probed.filter(geoMismatch);
      if (mismatched.length) {
        children.push(element('div', 'group-head', t('nt.geo.mismatchTitle', mismatched.length)));
        children.push(element('div', 'note', t('nt.geo.mismatchHint')));
        mismatched.forEach((node) => children.push(geoRow(node, true)));
      }
      sorted.forEach(([code, list]) => {
        const sample = list[0].geo;
        const head = element('div', 'group-head');
        if (sample.flag) head.append(element('span', 'flag', sample.flag));
        head.append(element('span', null, geoName(sample)));
        head.append(element('span', 'count dim', t('nd.count', list.length)));
        children.push(head);
        list.forEach((node) => children.push(geoRow(node, false)));
      });
      container.replaceChildren(...children);
    }

    function geoRow(node, showRegion) {
      const item = element('div', 'item');
      item.append(element('div', 'grow ellipsis', node.name));
      if (showRegion) item.append(geoCell(node.geo));
      item.append(element('span', 'dim mono', node.geo.ip));
      if (node.localPort) item.append(element('span', 'tag', String(node.localPort)));
      return item;
    }

    /* ---------- 目标可达 ---------- */

    const PROBE_PRESETS = [
      ['Google', 'https://www.google.com/generate_204'],
      ['YouTube', 'https://www.youtube.com/generate_204'],
      ['ChatGPT', 'https://chatgpt.com/'],
      ['GitHub', 'https://github.com/'],
      ['Netflix', 'https://www.netflix.com/'],
    ];

    function renderPresets() {
      $('probe-presets').replaceChildren(...PROBE_PRESETS.map(([label, url]) => {
        const chip = element('button', 'chip', label);
        chip.type = 'button';
        chip.onclick = () => { $('probe-url').value = url; };
        return chip;
      }));
    }

    function renderProbeScope(nodes) {
      const regions = [...new Set(nodes.filter((n) => n.effectiveEnabled && n.geo && n.geo.ok && n.geo.code)
        .map((n) => n.geo.code))].sort();
      fillSelect($('probe-scope'),
        [['', t('nt.target.scopeAll')]].concat(regions.map((code) => {
          const sample = nodes.find((n) => n.geo && n.geo.code === code);
          return [code, t('nt.target.scopeRegion') + ' ' +
            (sample.geo.flag ? sample.geo.flag + ' ' : '') + geoName(sample.geo)];
        })), '');
    }

    async function runProbe() {
      const url = $('probe-url').value.trim();
      if (!url) { toast(t('nt.target.empty')); return; }
      if (!snapshot) return;
      if (!snapshot.service.running) { toast(t('nt.serviceOff')); return; }

      const scope = $('probe-scope').value;
      const candidates = snapshot.nodes.filter((n) => n.effectiveEnabled
        && (!scope || (n.geo && n.geo.code === scope)));
      if (!candidates.length) { toast(t('nd.noMatch')); return; }

      probing = true;
      $('probe-count').textContent = t('nt.target.running', candidates.length);
      renderProbeResults();
      /* 只把选中的 id 发过去：范围是「落地在新加坡的节点」时，
         让服务端去测全部再筛，等的是几十秒而不是几秒。 */
      const data = await call('/probe', 'POST', { url, ids: candidates.map((n) => n.id) });
      probing = false;
      if (data) { probeResponse = data; }
      renderProbeResults();
    }

    function renderProbeResults() {
      const container = $('probe-results');
      const count = $('probe-count');
      if (probing) {
        container.replaceChildren(element('div', 'empty', t('common.loading')));
        return;
      }
      if (!probeResponse) {
        container.replaceChildren(element('div', 'empty', t('nt.target.empty')));
        count.textContent = '';
        return;
      }
      const results = probeResponse.results || [];
      const reachable = results.filter((r) => r.ok).length;
      count.textContent = t('nt.reachableCount', reachable, results.length);

      container.replaceChildren(...results.map((row, index) => {
        const item = element('div', 'item' + (row.ok ? '' : ' off'));
        item.append(element('span', 'idx', String(index + 1)));
        item.append(element('div', 'grow ellipsis', row.name));
        const flag = element('span', 'flagcell');
        if (row.geoFlag) flag.append(element('span', 'flag', row.geoFlag));
        flag.append(document.createTextNode(row.geoCode ? ' ' + row.geoCode : ''));
        item.append(flag);
        if (row.localPort) item.append(element('span', 'tag', String(row.localPort)));
        item.append(element('span', 'tag ' + (row.ok ? 'ok' : 'bad'),
          row.ok ? t('nt.ok') : t('lat.' + row.outcome)));
        item.append(element('span', 'lat ' + (row.ok ? 'fast' : 'failed'),
          row.milliseconds !== undefined ? row.milliseconds + ' ms' : '–'));
        return item;
      }));
    }

    /* ---------- 命名 ---------- */

    function renderNaming(naming) {
      const input = $('naming-template');
      /* 轮询正好落在用户输入到一半时，覆盖输入框等于把人打断。聚焦时只更新说明。 */
      if (!namingDirty && document.activeElement !== input) input.value = naming.template;
      input.placeholder = naming.defaultTemplate;
      $('naming-preview').textContent = naming.preview.join(' · ');

      /* 每次都重建选项而不是只建一次：切语言不重载页面，只建一次的话
         选项文字会一直停在进来时那门语言上。 */
      const style = $('naming-style');
      style.replaceChildren(option('template', t('naming.style.template')),
                            option('normalized', t('naming.style.normalized')),
                            option('script', t('naming.style.script')));
      style.value = naming.style;
      const scripted = naming.style === 'script';
      /* 地区表在脚本模式下仍然有用：RouteBar 会把认好的地区作为 p.region 交给脚本。
         所以两块可以同时显示，不是二选一。 */
      const normalized = naming.style === 'normalized' || scripted;
      /* 规范化模式下模板不参与生成。留着能看但禁掉，免得有人改半天发现输出没变。 */
      input.disabled = normalized;
      $('btn-naming-reset').disabled = normalized;
      $('naming-help').textContent = scripted
        ? t('naming.scriptHelp')
        : normalized
          ? t('naming.normalizedHelp')
          : t('naming.help') + naming.placeholders.map((p) => p.token + ' ' + p.summary).join('、');

      $('naming-script').hidden = !scripted;
      /* 脚本按需取一次：它不在快照里（几百行跟着每秒轮询走纯属浪费，
         而且会在编辑到一半时被覆盖）。 */
      if (scripted && !scriptLoaded) { scriptLoaded = true; loadScript(); }

      $('naming-regions').hidden = !normalized;
      const table = $('naming-region-table');
      if (normalized && !regionsDirty && document.activeElement !== table) {
        table.value = formatRegionRules(naming.regionRules);
      }
    }

    /* 一行一条规则：`香港 = 香港, HONG KONG, HK`。
       用文本而不是一行行的 DOM 控件，是因为顺序就是优先级——挪一条规则的位置在文本里
       是剪切一行，换成按钮就得再做一套上移下移，而这张表本来就是整体改完一次提交的。 */
    function formatRegionRules(rules) {
      return (rules || []).map((rule) => rule.region + ' = ' + rule.keywords.join(', ')).join('\n');
    }

    function parseRegionRules(text) {
      return text.split('\n').map((line) => {
        const at = line.indexOf('=');
        if (at < 0) return null;
        const region = line.slice(0, at).trim();
        const keywords = line.slice(at + 1).split(',').map((word) => word.trim()).filter(Boolean);
        return region && keywords.length ? { region, keywords } : null;
      }).filter(Boolean);
    }

    async function saveNaming(template) {
      const data = await call('/naming', 'POST', { template, style: $('naming-style').value });
      if (data) {
        namingDirty = false;
        $('naming-template').value = data.naming.template;
        $('naming-result').hidden = true;
        render(data);
        toast(t('naming.saved'));
      }
    }

    async function saveRegions(rules) {
      const data = await call('/naming/regions', 'POST', { rules });
      if (data) {
        regionsDirty = false;
        $('naming-region-table').value = formatRegionRules(data.naming.regionRules);
        $('naming-result').hidden = true;
        render(data);
        toast(t('naming.regionsSaved', data.naming.regionRules.length));
      }
    }

    /* 试跑：服务端按传过去的模板算一遍名字，不保存任何东西。
       名字里的序号和重名补号都取决于整批节点，所以只能由服务端算，网页不自己拼。 */
    async function testNaming(template) {
      /* 带上输入框里**还没保存**的方式和地区表：试跑要回答的是「按我现在写的这套规则
         会变成什么」，用已保存的那份算等于保存前根本没法验证。 */
      const style = $('naming-style').value;
      const body = { template, style };
      if (style === 'normalized') body.regionRules = parseRegionRules($('naming-region-table').value);
      const data = await call('/naming/preview', 'POST', body);
      if (!data) return;
      const box = $('naming-result');
      const head = element('div', 'dim', data.isSample
        ? t('naming.sample') : t('naming.willBecome', data.rows.length));
      const rows = data.rows.map((row, index) => {
        const line = element('div', 'item');
        line.append(element('span', 'idx', String(index + 1)));
        line.append(element('div', 'grow ellipsis', row.name));
        line.append(element('span', 'dim', '→'));
        line.append(element('div', 'grow mono ellipsis', row.outputName));
        line.append(element('span', 'tag', String(row.localPort)));
        return line;
      });
      box.replaceChildren(head, ...rows);
      box.hidden = false;
    }

    /* ---------- 命名脚本 ---------- */

    async function loadScript() {
      const data = await call('/naming/script');
      if (!data) { scriptLoaded = false; return; }
      const box = $('naming-script-text');
      if (!scriptDirty && document.activeElement !== box) {
        box.value = data.script || '';
        box.placeholder = t('naming.scriptEmpty');
        if (box.value.trim()) runScript(true);
      }
      $('btn-script-template').dataset.template = data.template || '';
      $('script-status').textContent = t('naming.scriptTimeout', data.timeout);
    }

    async function saveScript() {
      const data = await call('/naming/script', 'POST', { script: $('naming-script-text').value });
      if (data) {
        scriptDirty = false;
        render(data);
        toast(t('naming.scriptSaved'));
      }
    }

    /* 试跑用编辑器里**还没保存**的内容，而且跑的是当前这批真实节点——
       脚本要处理的恰恰是机场那些花名和混在里面的信息节点，假数据试不出问题。 */
    async function runScript(quiet) {
      const seq = ++scriptSeq;
      const body = { script: $('naming-script-text').value };
      const data = quiet ? await quietPost('/naming/script/preview', body)
                         : await call('/naming/script/preview', 'POST', body);
      /* 过期的响应不能覆盖新结果。 */
      if (!data || seq !== scriptSeq) return;
      renderScriptResult(data);
    }

    /* 停止输入一小会儿之后自动重跑。
       不在每次击键就跑：一是没必要，二是写到一半的语句必然是语法错误，
       满屏红字比没有提示更让人分心。 */
    function scheduleScriptPreview() {
      clearTimeout(scriptTimer);
      scriptTimer = setTimeout(() => runScript(true), 700);
    }

    /* 自动预览走的是安静通道：不占 busy、不禁用按钮、失败不弹 toast。
       用 call() 的话，每敲一阵子键盘全页面的按钮就会灰一下，而且轮询会被一直挤掉。 */
    async function quietPost(path, body) {
      try {
        const response = await fetch(API + path, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
        if (!response.ok) return null;
        const text = await response.text();
        return text ? JSON.parse(text) : null;
      } catch (error) {
        return null;
      }
    }

    function renderScriptResult(data) {
      const box = $('script-result');
      const parts = [];
      const failed = Boolean(data.failure);
      const rows = failed ? (scriptLastRows && scriptLastRows.rows) : data.rows;
      const filtered = failed ? (scriptLastRows && scriptLastRows.filtered) : data.filtered;

      if (failed) {
        parts.push(element('div', 'console bad', data.failure));
        if (rows) parts.push(element('div', 'dim', t('naming.scriptStale')));
      } else {
        scriptLastRows = { rows: data.rows, filtered: data.filtered };
        /* 保留 / 被过滤 分开报数。只报「输出了几行」看不出过滤条件写歪没有——
           而过滤写歪的表现就是 Surge 里静静少几个节点，没有任何提示。 */
        const kept = element('div', 'dim');
        kept.append(element('strong', null,
          t('naming.scriptKept', data.rows.length, data.nodeCount)));
        if (data.filtered.length) {
          kept.append(document.createTextNode('   '));
          kept.append(element('span', 'tag warn',
            t('naming.scriptFiltered', data.filtered.length, data.nodeCount)));
        }
        kept.append(document.createTextNode('   ' + t('naming.scriptTook', data.milliseconds)));
        parts.push(kept);
      }
      for (const warning of data.warnings || []) {
        parts.push(element('div', 'console warn', warning));
      }
      if ((data.logs || []).length) {
        parts.push(element('div', 'console', data.logs.join('\n')));
      }

      /* 只列前若干行：脚本调通与否前几十行就看出来了，几百行 DOM 反而让页面发顿。 */
      appendScriptRows(parts, rows, true);
      if (filtered && filtered.length) {
        parts.push(element('div', 'dim', t('naming.scriptFilteredHead', filtered.length)));
        appendScriptRows(parts, filtered, false);
      }
      box.replaceChildren(...parts);
      box.hidden = false;
    }

    function appendScriptRows(parts, rows, emitted) {
      const shown = (rows || []).slice(0, 60);
      for (let i = 0; i < shown.length; i++) {
        const row = shown[i];
        const line = element('div', 'item');
        line.append(element('span', 'idx', String(i + 1)));
        line.append(element('div', 'grow ellipsis', row.name));
        if (emitted) {
          line.append(element('span', 'dim', '→'));
          line.append(element('div', 'grow mono ellipsis', row.outputName));
        } else {
          /* 被过滤的没有输出名，留一格占位，两张表的列才对得齐。 */
          line.append(element('span', 'dim', '×'));
          line.append(element('div', 'grow dim', t('naming.scriptNotEmitted')));
        }
        line.append(element('span', 'tag', String(row.localPort)));
        parts.push(line);
      }
      if (rows && rows.length > shown.length) {
        parts.push(element('div', 'dim', t('naming.scriptMore', rows.length - shown.length)));
      }
    }

    /* ---------- 订阅 ---------- */

    function renderSubscriptions(list) {
      const container = $('subs');
      const filter = $('sub-proto').value;
      const visible = filter ? list.filter((sub) => (sub.protocols || []).includes(filter)) : list;
      $('sub-count').textContent = t('nd.count', list.length);

      if (!list.length) {
        container.replaceChildren(element('div', 'empty', t('sb.empty')));
        return;
      }
      if (!visible.length) {
        container.replaceChildren(element('div', 'empty', t('sb.noMatch')));
        return;
      }
      /* 打开的编辑器所属订阅已被删除时关掉它，免得留在一个不存在的对象上。 */
      if (editingId && !list.some((s) => s.id === editingId)) editingId = null;

      container.replaceChildren(...visible.map((sub) => {
        const index = list.findIndex((item) => item.id === sub.id);
        if (sub.id === editingId) return subscriptionEditor(sub, index);

        const item = element('div', 'item' + (sub.enabled ? '' : ' off'));
        item.append(element('span', 'idx', String(index + 1)));

        const left = element('div', 'grow');
        left.append(element('div', null, sub.name));
        const meta = [t('status.' + sub.status), t('sb.nodes', sub.nodeCount), relative(sub.updatedAt),
                      t('sb.every', sub.updateIntervalHours)];
        if (sub.protocols && sub.protocols.length) {
          meta.splice(2, 0, sub.protocols.map(protocolText).join('/'));
        }
        if (sub.note) meta.push(sub.note);
        if (sub.lastError) meta.push(sub.lastError);
        left.append(element('div', 'dim ellipsis', meta.join(' · ')));
        item.append(left);

        const update = element('button', 'ghost small', t('common.update'));
        update.onclick = () => act('/subscriptions/' + sub.id + '/update', 'POST', {});

        const edit = element('button', 'ghost small', t('common.edit'));
        edit.onclick = () => { editingId = sub.id; renderSubscriptions(list); };

        const toggle = element('button', 'ghost small',
          sub.enabled ? t('common.disable') : t('common.enable'));
        toggle.onclick = () => act('/subscriptions/' + sub.id + '/enabled', 'POST',
          { enabled: !sub.enabled });

        const remove = element('button', 'danger small', t('common.delete'));
        remove.onclick = () => {
          if (confirm(t('sb.deleteConfirm', sub.name))) {
            act('/subscriptions/' + sub.id, 'DELETE', undefined);
          }
        };

        const actions = element('div', 'row');
        actions.append(update, edit, toggle, remove);
        item.append(actions);
        return item;
      }));
    }

    function labelled(text, input) {
      const wrap = element('label', 'field');
      wrap.append(element('span', 'dim', text), input);
      return wrap;
    }

    function subscriptionEditor(sub, index) {
      const draft = subscriptionDrafts.get(sub.id) || {
        name: sub.name, url: '', note: sub.note || '',
        interval: String(sub.updateIntervalHours), template: sub.nodeNameTemplate || '',
      };
      subscriptionDrafts.set(sub.id, draft);
      const box = element('div', 'item');
      const body = element('div', 'grow');
      body.append(element('div', null, t('sb.editing', sub.name)));

      const name = element('input');
      name.value = draft.name;
      name.required = true;

      const url = element('input');
      url.type = 'url';
      url.value = draft.url;
      /* 存下来的地址含机场凭据，只在钥匙串里，网页从不显示它。
         因此空值只能理解成「不改」，不能当成「清空」。 */
      url.placeholder = t('sb.urlKeepHint');

      const note = element('input');
      note.value = draft.note;

      const interval = element('input');
      interval.type = 'number';
      interval.min = '1';
      interval.max = '168';
      interval.value = draft.interval;

      const template = element('input');
      template.value = draft.template;
      for (const [key, input] of Object.entries({ name, url, note, interval, template })) {
        input.oninput = () => { draft[key] = input.value; };
      }
      template.placeholder = (snapshot && snapshot.naming.template) || t('sb.templatePlaceholder');

      const grid = element('div', 'editor');
      grid.append(labelled(t('sb.name'), name), labelled(t('sb.url'), url),
                  labelled(t('sb.note'), note), labelled(t('sb.interval'), interval),
                  labelled(t('sb.template'), template));
      body.append(grid);

      const save = element('button', 'primary small', t('common.save'));
      save.onclick = async () => {
        const payload = {
          id: sub.id,
          name: name.value.trim(),
          note: note.value.trim(),
          intervalHours: Math.min(168, Math.max(1, parseInt(interval.value, 10) || sub.updateIntervalHours)),
          /* 总是带上：空串在这里的意思是「清掉覆盖、跟随全局」，不是「不改」。 */
          nodeNameTemplate: template.value.trim(),
        };
        if (!payload.name) { toast(t('sb.nameRequired')); return; }
        const typed = url.value.trim();
        if (typed) payload.url = typed;
        const data = await call('/subscriptions', 'POST', payload);
        if (data) {
          subscriptionDrafts.delete(sub.id);
          editingId = null;
          render(data);
          toast(t('sb.saved'));
        }
      };

      const cancel = element('button', 'ghost small', t('common.cancel'));
      cancel.onclick = () => {
        subscriptionDrafts.delete(sub.id);
        editingId = null;
        renderSubscriptions(snapshot.subscriptions);
      };

      const actions = element('div', 'row');
      actions.append(save, cancel, element('span', 'dim', t('sb.saveHint')));
      body.append(actions);

      box.append(element('span', 'idx', String(index + 1)), body);
      return box;
    }

    /* ══════════ 复制 ══════════ */

    async function copy(text, label) {
      try {
        await navigator.clipboard.writeText(text);
        toast(label + ' ' + t('common.copied'));
      } catch (e) {
        toast(t('common.copyFailed'));
      }
    }

    /* ══════════ 事件绑定 ══════════ */

    $('btn-update').onclick = () => act('/update', 'POST', {});
    $('btn-regen').onclick = () => act('/regenerate', 'POST', {});
    $('btn-refresh').onclick = () => act('/service/refresh', 'POST', {});
    $('btn-svc').onclick = () =>
      act('/service/' + (snapshot && snapshot.service.running ? 'stop' : 'start'), 'POST', {});
    $('btn-copy-url').onclick = () => copy(snapshot.output.subscriptionURL, t('ov.output.title'));
    $('btn-copy-line').onclick = () => copy(snapshot.output.surgePolicyLine, 'Surge');
    $('btn-update-all').onclick = () => act('/update', 'POST', {});

    /* 测速和落地探测在概览页和节点页各有一个入口，指向同一个动作。 */
    ['btn-test-all', 'btn-test-all-2'].forEach((id) => {
      $(id).onclick = () => act('/nodes/test', 'POST', {});
    });
    ['btn-geo-all', 'btn-geo-all-2', 'btn-geo-run'].forEach((id) => {
      $(id).onclick = () => act('/nodes/geo', 'POST', {});
    });

    ['nd-search', 'nd-sub', 'nd-proto', 'nd-region', 'nd-lat', 'nd-sort'].forEach((id) => {
      const el = $(id);
      const handler = () => { if (snapshot) renderNodes(snapshot.nodes); };
      el.oninput = handler;
      el.onchange = handler;
    });
    $('sub-proto').onchange = () => { if (snapshot) renderSubscriptions(snapshot.subscriptions); };

    $('btn-probe').onclick = runProbe;
    $('probe-url').onkeydown = (event) => { if (event.key === 'Enter') runProbe(); };

    $('btn-naming-test').onclick = () => testNaming($('naming-template').value.trim());
    $('btn-naming-save').onclick = () => saveNaming($('naming-template').value.trim());
    $('btn-naming-reset').onclick = () => saveNaming(snapshot ? snapshot.naming.defaultTemplate : '');
    $('naming-template').onkeydown = (event) => {
      if (event.key === 'Enter') testNaming($('naming-template').value.trim());
    };
    /* 模板一改，上一次的试跑结果就不再对应输入框里的内容了，留着只会看错。 */
    $('naming-template').oninput = () => { namingDirty = true; $('naming-result').hidden = true; };
    /* 切换方式立即保存：它不像模板那样要先看一眼结果，而两种方式各自的输入
       （模板 / 地区表）也只有切过去之后才编辑得了。 */
    $('naming-style').onchange = () => saveNaming($('naming-template').value.trim());
    $('naming-region-table').oninput = () => { regionsDirty = true; $('naming-result').hidden = true; };
    $('naming-script-text').oninput = () => { scriptDirty = true; scheduleScriptPreview(); };
    $('btn-script-run').onclick = () => runScript(false);
    $('btn-script-save').onclick = () => saveScript();
    $('btn-script-template').onclick = (event) => {
      $('naming-script-text').value = event.currentTarget.dataset.template || '';
      scriptDirty = true;
      scheduleScriptPreview();
    };
    /* 编辑器里按 Tab 应该缩进，而不是跳到下一个控件——写 JS 时前者是刚需。 */
    $('naming-script-text').onkeydown = (event) => {
      if (event.key !== 'Tab') return;
      event.preventDefault();
      const box = event.currentTarget;
      const at = box.selectionStart;
      box.value = box.value.slice(0, at) + '  ' + box.value.slice(box.selectionEnd);
      box.selectionStart = box.selectionEnd = at + 2;
      scriptDirty = true;
      scheduleScriptPreview();
    };
    $('btn-regions-save').onclick = () => saveRegions(parseRegionRules($('naming-region-table').value));
    $('btn-regions-reset').onclick = () => {
      if (!snapshot) return;
      $('naming-region-table').value = formatRegionRules(snapshot.naming.defaultRegionRules);
      regionsDirty = true;
    };

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
        toast(t('sb.added'));
      }
    };

    /* ══════════ 启动 ══════════ */

    async function refresh() {
      const data = await call('/state');
      if (data) render(data);
    }

    (function start() {
      /* 读不到 localStorage（无痕模式、禁了存储）就退回默认，不该因此崩掉。 */
      let savedLang = null, savedTheme = null, savedTab = null;
      try {
        savedLang = localStorage.getItem('routebar.lang');
        savedTheme = localStorage.getItem('routebar.theme');
        savedTab = localStorage.getItem('routebar.tab');
      } catch (e) {}
      setTheme(savedTheme || 'auto');
      syncFavicon();
      setLang(savedLang || 'auto');
      showTab(savedTab || 'overview');
      renderPresets();
      renderProbeResults();
      refresh();
      /* 定时轮询，好让菜单栏应用里做的改动、以及后台的定时更新都反映到页面上。
         编辑器开着或正在跑测试时跳过：重绘会把填了一半的表单、以及测试进度一起丢掉。 */
      setInterval(() => { if (!busy && !editingId && !probing) refresh(); }, 8000);
    })();
    """#
}
