// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [--answer <key>=<value>]
// --answer selects option <value> on Captain's Call card <key> and submits its
// form, recording what the page queues for Lavish.
// Prints one JSON document:
//   { stats:[{n,label}], call:[{title,head,head_title}], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable}], empty, more, error, queued:[{prompt,data}] }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.listeners = {};
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      remove: (c) => { this.className = this.className.split(/\s+/).filter((k) => k !== c).join(" "); },
      toggle: (c, on) => { (on ?? !this.classList.contains(c)) ? this.classList.add(c) : this.classList.remove(c); },
      contains: (c) => this.className.split(/\s+/).includes(c),
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, fn) { this.listeners[type] = fn; }
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
globalThis.window = {};
globalThis.TextEncoder = TextEncoder;
const descendants = (n) => n.children.flatMap((c) => [c, ...descendants(c)]);
// The first named control's value, skipping an unchecked radio, as a browser's
// FormData reads a form.
globalThis.FormData = class {
  constructor(form) { this.form = form; }
  get(name) {
    const field = descendants(this.form).find((c) => c.name === name && (c.type !== "radio" || c.checked));
    return field ? field.value : null;
  }
};

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = row.children.find((c) => c.className.includes("bb-row__main"));
      return {
        title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
        sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
        badges: badgesOf(row),
        pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
      };
    });

const deck = byId.get("bb-call") || new Node("div");
const call = deck.children
  .filter((c) => c.className.split(/\s+/).includes("bb-decision"))
  .map((card) => {
    const head = card.querySelectorAll(".bb-decision__head")[0];
    return {
      title: card.querySelectorAll(".bb-decision__title")[0]?.textContent ?? "",
      head: head?.textContent ?? "",
      head_title: head?.title ?? "",
    };
  });

const queued = [];
const answerAt = process.argv.indexOf("--answer");
if (answerAt > 0) {
  const spec = process.argv[answerAt + 1] ?? "";
  const key = spec.slice(0, spec.indexOf("="));
  const value = spec.slice(spec.indexOf("=") + 1);
  const form = descendants(deck).find((c) => c.tagName === "form" && c.attributes["data-lavish-question"] === key);
  const option = form && descendants(form).find((c) => c.type === "radio" && c.value === value);
  if (option) {
    window.lavish = { queuePrompt: (prompt, opts) => queued.push({ prompt, data: opts.data }) };
    // The deck deals the next card after a delay; nothing here renders it.
    globalThis.setTimeout = () => {};
    option.checked = true;
    form.listeners.submit({ preventDefault() {} });
  }
}

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

process.stdout.write(
  JSON.stringify({ stats, call, underway, charted, empty, more, error: errorText, queued }) + "\n");
