const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');

class Element {
  constructor(tag = 'div') { this.tag = tag; this.children = []; this.value = ''; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
}
const elements = new Map();
const source = fs.readFileSync(path.join(__dirname, '../RouteBar/RouteBarCore/Network/WebUIScript.swift'), 'utf8')
  .split('nonisolated static let js = #"""')[1].split('/* ══════════ 事件绑定')[0];
const context = vm.createContext({
  location: { pathname: '/token/' },
  I18N: { zh: {} },
  document: {
    addEventListener() {},
    createElement: (tag) => new Element(tag),
    getElementById: (id) => {
      if (!elements.has(id)) elements.set(id, new Element());
      return elements.get(id);
    },
  },
});
vm.runInContext(source + `
  globalThis.api = { subscriptionEditor, renderNaming,
    markNamingDirty: () => { namingDirty = true; } };
`, context);
function inputs(root) {
  return [root, ...root.children.flatMap(inputs)].filter((node) => node.tag === 'input');
}
const subscription = { id: 'one', name: 'Original', note: 'Before', updateIntervalHours: 6 };
const first = inputs(context.api.subscriptionEditor(subscription, 0));
const draft = ['Draft name', 'https://example.com/private', 'Draft note', '12', '{region}'];
first.forEach((input, index) => { input.value = draft[index]; input.oninput(); });
const rebuilt = inputs(context.api.subscriptionEditor(subscription, 0));
assert.deepEqual(rebuilt.map((input) => input.value), draft, 'rerender must preserve all draft fields');

const naming = { template: 'Saved', defaultTemplate: 'Default', preview: [], placeholders: [] };
context.api.renderNaming(naming);
const template = elements.get('naming-template');
assert.equal(template.value, 'Saved');
template.value = 'Unsaved';
context.api.markNamingDirty();
context.api.renderNaming({ ...naming, template: 'Remote change' });
assert.equal(template.value, 'Unsaved', 'blurred dirty naming input must survive polling');
console.log('Web draft regressions passed');
