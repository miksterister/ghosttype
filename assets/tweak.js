/* tweak.js — dev-only live token panel. Auto-discovers every custom property declared on
   :root, renders a control per token, persists to localStorage, and exports the result as a
   :root{} block you can paste back into the stylesheet.

   Drop in during development:  <script src="tweak.js"></script>   (last tag in <body>)
   Hide it for screenshots:     ?tweak=0
   Delete before shipping.      ponytail: no build step, no deps, no framework binding. */
(() => {
  const KEY = "tweak:" + location.pathname;
  const root = document.documentElement;
  const overrides = JSON.parse(localStorage.getItem(KEY) || "{}");

  // Apply saved tweaks first so a reload keeps them, even when the panel is hidden.
  for (const [k, v] of Object.entries(overrides)) root.style.setProperty(k, v);
  if (new URLSearchParams(location.search).get("tweak") === "0") return;

  const names = [];
  for (const sheet of document.styleSheets) {
    let rules;
    try {
      rules = sheet.cssRules;
    } catch {
      continue; // cross-origin sheet, can't read it
    }
    for (const rule of rules || []) {
      if (rule.type !== 1 || !/(^|,)\s*(:root|html)\s*(,|$)/.test(rule.selectorText || "")) continue;
      for (const prop of rule.style) {
        if (prop.startsWith("--") && !names.includes(prop)) names.push(prop);
      }
    }
  }
  for (const n of Object.keys(overrides)) if (!names.includes(n)) names.push(n);
  if (!names.length) {
    console.warn("[tweak] no custom properties found on :root — declare your tokens there first");
    return;
  }

  const read = (n) => getComputedStyle(root).getPropertyValue(n).trim();

  // Any CSS color → #rrggbb, via the browser's own parser. Returns null for non-colors.
  const probe = document.createElement("span");
  probe.style.cssText = "position:absolute;visibility:hidden";
  const toHex = (v) => {
    probe.style.color = "";
    probe.style.color = v;
    if (!probe.style.color) return null;
    document.body.appendChild(probe);
    const m = getComputedStyle(probe).color.match(/[\d.]+/g);
    probe.remove();
    // alpha is dropped — <input type=color> has no alpha channel
    return m ? "#" + m.slice(0, 3).map((c) => (+c).toString(16).padStart(2, "0")).join("") : null;
  };

  const NUM = /^(-?[\d.]+)(px|rem|em|%|vh|vw|ch|s|ms|deg)?$/;

  const host = document.createElement("div");
  host.dataset.tweak = "";
  // Shadow DOM so the page's own CSS (resets, input styles, * selectors) can't mangle the panel.
  const sh = host.attachShadow({ mode: "open" });
  sh.innerHTML = `<style>
    :host{all:initial}
    .fab,.panel{position:fixed;right:16px;z-index:2147483647;
      font:12px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;color:#f5f5f4}
    .fab{bottom:16px;width:36px;height:36px;border-radius:50%;border:1px solid #44403c;
      background:#1c1917;cursor:pointer;font-size:15px}
    .panel{bottom:60px;width:296px;max-height:min(70vh,620px);display:none;flex-direction:column;
      background:#1c1917;border:1px solid #44403c;border-radius:10px;
      box-shadow:0 12px 32px rgb(0 0 0/.45)}
    .panel[open]{display:flex}
    .rows{overflow-y:auto;padding:8px 10px}
    .row{display:flex;gap:6px;align-items:center;padding:3px 0}
    .row label{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#d6d3d1}
    .row .n{width:42px;flex:none;color:#a8a29e;font-size:10px;text-align:right}
    input{width:104px;flex:none;font:inherit;box-sizing:border-box}
    input[type=text]{background:#0c0a09;color:#f5f5f4;border:1px solid #44403c;border-radius:4px;padding:2px 4px}
    input[type=color]{height:22px;padding:0;border:1px solid #44403c;background:none}
    .bar{display:flex;gap:6px;padding:8px 10px;border-top:1px solid #292524}
    .bar button{flex:1;padding:5px;border-radius:6px;border:1px solid #44403c;background:#292524;
      color:#f5f5f4;font:inherit;cursor:pointer}
    .bar button:hover{background:#44403c}
    textarea{width:100%;height:110px;margin:0 0 8px;background:#0c0a09;color:#f5f5f4;
      border:1px solid #44403c;border-radius:4px;font:inherit}
    @media print{:host{display:none}}
  </style>
  <button class="fab" title="Tweak tokens">⚙</button>
  <div class="panel"><div class="rows"></div>
    <div class="bar"><button data-act="copy">Copy CSS</button><button data-act="reset">Reset</button></div>
  </div>`;

  const panel = sh.querySelector(".panel");
  const rows = sh.querySelector(".rows");
  sh.querySelector(".fab").onclick = () => panel.toggleAttribute("open");

  const set = (name, value) => {
    overrides[name] = value;
    root.style.setProperty(name, value);
    localStorage.setItem(KEY, JSON.stringify(overrides));
  };

  for (const name of names) {
    const value = read(name);
    const row = document.createElement("div");
    row.className = "row";
    row.innerHTML = `<label title="${name}">${name.slice(2)}</label>`;
    const hex = toHex(value);
    const num = value.match(NUM);
    let input;

    if (hex) {
      input = Object.assign(document.createElement("input"), { type: "color", value: hex });
      input.oninput = () => set(name, input.value);
    } else if (num) {
      const n = parseFloat(num[1]);
      const unit = num[2] || "";
      const step = ["px", "ms", "%", "deg", "vh", "vw"].includes(unit) ? 1 : n < 10 ? 0.05 : 1;
      input = Object.assign(document.createElement("input"), {
        type: "range", value: String(n), step: String(step),
        min: String(Math.min(0, n)), max: String(Math.max(n * 3, step * 20) || 100),
      });
      const out = document.createElement("span");
      out.className = "n";
      out.textContent = value;
      input.oninput = () => {
        out.textContent = input.value + unit;
        set(name, input.value + unit);
      };
      row.append(input, out);
    } else {
      input = Object.assign(document.createElement("input"), { type: "text", value });
      input.onchange = () => set(name, input.value);
    }
    if (!input.parentNode) row.append(input);
    rows.append(row);
  }

  sh.querySelector(".bar").onclick = (e) => {
    const act = e.target.dataset.act;
    if (act === "reset") {
      localStorage.removeItem(KEY);
      location.reload();
    }
    if (act === "copy") {
      const css = ":root {\n" + Object.entries(overrides).map(([k, v]) => `  ${k}: ${v};`).join("\n") + "\n}";
      const ta = document.createElement("textarea");
      ta.value = css;
      panel.prepend(ta);
      ta.select();
      navigator.clipboard?.writeText(css).catch(() => {}); // falls back to the selected textarea
      e.target.textContent = "Copied ✓";
      setTimeout(() => {
        e.target.textContent = "Copy CSS";
        ta.remove();
      }, 4000);
    }
  };

  document.body.append(host);
})();
