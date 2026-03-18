// dom_extract.js — 简化 DOM 提取，给交互元素分配索引
// 通过 page.evaluate() 注入，返回 { text, selectorMap }
(() => {
  const INTERACTIVE_TAGS = new Set([
    'a', 'button', 'input', 'select', 'textarea', 'details', 'summary', 'option'
  ]);
  const INTERACTIVE_ROLES = new Set([
    'button', 'link', 'menuitem', 'tab', 'switch', 'combobox',
    'textbox', 'listbox', 'option', 'checkbox', 'radio'
  ]);
  const SKIP_TAGS = new Set([
    'script', 'style', 'link', 'meta', 'noscript', 'template', 'svg', 'path'
  ]);
  const KEEP_ATTRS = new Set([
    'type', 'name', 'placeholder', 'value', 'role', 'aria-label',
    'aria-expanded', 'aria-checked', 'checked', 'href', 'title',
    'data-state', 'for', 'target', 'contenteditable', 'alt'
  ]);

  let idx = 0;
  const selectorMap = {};

  function isVisible(el) {
    if (!el.offsetParent && el.tagName !== 'BODY' && el.tagName !== 'HTML') {
      const st = getComputedStyle(el);
      if (st.display === 'none' || st.visibility === 'hidden') return false;
      if (st.position !== 'fixed' && st.position !== 'sticky') return false;
    }
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  function isInteractive(el) {
    const tag = el.tagName.toLowerCase();
    if (INTERACTIVE_TAGS.has(tag)) return true;
    const role = (el.getAttribute('role') || '').toLowerCase();
    if (INTERACTIVE_ROLES.has(role)) return true;
    if (el.hasAttribute('contenteditable') && el.getAttribute('contenteditable') !== 'false') return true;
    if (el.onclick || el.hasAttribute('onclick')) return true;
    const cursor = getComputedStyle(el).cursor;
    if (cursor === 'pointer') return true;
    return false;
  }

  function getAttrs(el) {
    const result = {};
    for (const attr of el.attributes) {
      if (KEEP_ATTRS.has(attr.name)) {
        result[attr.name] = attr.value;
      }
    }
    // checkbox/radio checked 状态从 DOM property 读
    if (el.type === 'checkbox' || el.type === 'radio') {
      result.checked = el.checked ? 'true' : 'false';
    }
    return result;
  }

  function directText(el) {
    let t = '';
    for (const c of el.childNodes) {
      if (c.nodeType === 3) t += c.textContent;
    }
    return t.trim().substring(0, 80);
  }

  function processNode(node, depth) {
    if (node.nodeType === 3) {
      const t = node.textContent.trim();
      if (t) return '  '.repeat(depth) + t.substring(0, 120) + '\n';
      return '';
    }
    if (node.nodeType !== 1) return '';
    const tag = node.tagName.toLowerCase();
    if (SKIP_TAGS.has(tag)) return '';
    if (!isVisible(node)) return '';

    let out = '';
    const interactive = isInteractive(node);

    if (interactive) {
      const i = idx++;
      node.setAttribute('data-pa-idx', String(i));
      selectorMap[i] = buildSelector(node);
      const attrs = getAttrs(node);
      const attrStr = Object.entries(attrs)
        .map(([k, v]) => v ? `${k}="${v}"` : k)
        .join(' ');
      const text = directText(node);
      const pad = '  '.repeat(depth);
      out += `${pad}[${i}]<${tag}${attrStr ? ' ' + attrStr : ''}>${text ? text + ' ' : ''}/>\n`;
      // 递归子节点（但跳过已经提取的文本）
      for (const child of node.childNodes) {
        if (child.nodeType === 1) {
          out += processNode(child, depth + 1);
        }
      }
    } else {
      // 非交互元素：递归子节点
      for (const child of node.childNodes) {
        out += processNode(child, depth);
      }
    }
    return out;
  }

  function buildSelector(el) {
    // 构建 CSS selector 用于后备定位
    if (el.id) return '#' + CSS.escape(el.id);
    const tag = el.tagName.toLowerCase();
    const parts = [tag];
    if (el.name) parts.push(`[name="${CSS.escape(el.name)}"]`);
    if (el.type && (tag === 'input' || tag === 'button'))
      parts.push(`[type="${el.type}"]`);
    if (el.className && typeof el.className === 'string') {
      const cls = el.className.trim().split(/\s+/).slice(0, 2);
      for (const c of cls) parts.push('.' + CSS.escape(c));
    }
    return parts.join('');
  }

  // 重置索引
  idx = 0;
  const text = processNode(document.body, 0);
  return { text: text.substring(0, 30000), selectorMap, totalElements: idx };
})();
