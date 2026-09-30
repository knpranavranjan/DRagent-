/* ==========================================================================
   OPHIRA — tiny DOM helpers and the icon set
   --------------------------------------------------------------------------
   Inline SVG only. No emoji as icons: they render differently per platform,
   cannot be themed by token, and look unserious in a clinical record.
   Icons are from the Lucide set (ISC licence), inlined so the app works
   with no network -- the Pi has none in deployment.
   ========================================================================== */

export function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "html") el.innerHTML = v;
    else if (k.startsWith("on") && typeof v === "function") {
      el.addEventListener(k.slice(2).toLowerCase(), v);
    } else el.setAttribute(k, v === true ? "" : String(v));
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

export const $  = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

/* --- icons ---------------------------------------------------------------- */

const P = (d, extra = "") =>
  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
        stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}${extra}</svg>`;

export const ICON = {
  eye:      P(`<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/>`),
  check:    P(`<path d="m20 6-11 11-5-5"/>`),
  alert:    P(`<path d="M12 9v4"/><path d="M12 17h.01"/><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z"/>`),
  info:     P(`<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>`),
  arrowR:   P(`<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>`),
  arrowL:   P(`<path d="M19 12H5"/><path d="m12 19-7-7 7-7"/>`),
  user:     P(`<path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>`),
  clipboard:P(`<rect width="8" height="4" x="8" y="2" rx="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/>`),
  shield:   P(`<path d="M20 13c0 5-3.5 7.5-7.7 9a2 2 0 0 1-.6 0C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.2-2.7a1 1 0 0 1 1.5 0C14.5 3.8 17 5 19 5a1 1 0 0 1 1 1Z"/>`),
  activity: P(`<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>`),
  camera:   P(`<path d="M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3l-2.5-3Z"/><circle cx="12" cy="13" r="3"/>`),
  file:     P(`<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/>`),
  save:     P(`<path d="M15.2 3a2 2 0 0 1 1.4.6l3.8 3.8a2 2 0 0 1 .6 1.4V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z"/><path d="M17 21v-8H7v8"/><path d="M7 3v5h8"/>`),
  clock:    P(`<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>`),
  moon:     P(`<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>`),
  sun:      P(`<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M6.3 17.7l-1.4 1.4M19.1 4.9l-1.4 1.4"/>`),
  lock:     P(`<rect width="18" height="11" x="3" y="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>`),
  siren:    P(`<path d="M7 18v-6a5 5 0 1 1 10 0v6"/><path d="M5 21h14"/><path d="M12 2v1M4.9 5.6l.7.7M19.1 5.6l-.7.7"/>`),
};

export function icon(name, cls) {
  const span = document.createElement("span");
  span.innerHTML = ICON[name] || ICON.info;
  const svg = span.firstElementChild;
  if (cls) svg.setAttribute("class", cls);
  return svg;
}

/* --- toasts --------------------------------------------------------------- */

let toastHost = null;

export function toast(message, kind = "info", ms = 4000) {
  if (!toastHost) {
    toastHost = h("div", { class: "toasts", role: "status", "aria-live": "polite" });
    document.body.append(toastHost);
  }
  const t = h("div", { class: `toast toast--${kind}` },
    icon(kind === "ok" ? "check" : kind === "danger" ? "alert" : "info"),
    h("span", {}, message)
  );
  toastHost.append(t);
  setTimeout(() => t.remove(), ms);
}

/* --- form primitives ------------------------------------------------------ */

export function field({ label, required, help, error, control, id }) {
  return h("div", { class: "field", "data-invalid": error ? "true" : null },
    h("label", { class: "field__label", for: id },
      label, required ? h("span", { class: "field__req", "aria-hidden": "true" }, "*") : null,
      required ? h("span", { class: "sr-only" }, " (required)") : null
    ),
    help ? h("p", { class: "field__help", id: `${id}-help` }, help) : null,
    control,
    error ? h("p", { class: "field__error", id: `${id}-err`, role: "alert" },
      icon("alert"), h("span", {}, error)) : null
  );
}

export function textInput({ id, value, onInput, type = "text", mode, variant, placeholder, error, autocomplete }) {
  return h("input", {
    class: `input ${variant ? `input--${variant}` : ""}`,
    id, type, value: value ?? "",
    inputmode: mode, placeholder, autocomplete: autocomplete || "off",
    "aria-invalid": error ? "true" : null,
    "aria-describedby": error ? `${id}-err` : null,
    onInput: (e) => onInput(e.target.value),
  });
}

export function select({ id, value, options, onChange, placeholder, error }) {
  return h("select", {
      class: "select", id,
      "aria-invalid": error ? "true" : null,
      "aria-describedby": error ? `${id}-err` : null,
      onChange: (e) => onChange(e.target.value),
    },
    placeholder ? h("option", { value: "", selected: !value }, placeholder) : null,
    options.map((o) =>
      h("option", { value: o.value, selected: value === o.value }, o.label))
  );
}

/** Yes / No segmented control. Tri-state: null means unanswered. */
export function yesNo({ name, value, onChange, error }) {
  const opt = (v, label) =>
    h("label", { class: "choice choice--radio" },
      h("input", {
        type: "radio", name, checked: value === v,
        "aria-invalid": error ? "true" : null,
        onChange: () => onChange(v),
      }),
      h("span", { class: "choice__box" }, icon("check")),
      h("span", {}, label)
    );
  return h("div", { class: "seg", role: "group" }, opt(true, "Yes"), opt(false, "No"));
}

export function checkGroup({ name, values, options, onChange, flagged = false, stack = false }) {
  return h("div", { class: `choices ${stack ? "choices--stack" : ""}`, role: "group" },
    options.map((o) => {
      const isFlag = flagged && o.flag;
      return h("label", { class: `choice ${isFlag ? "choice--flag" : ""}` },
        h("input", {
          type: "checkbox", name, checked: values.includes(o.value),
          onChange: (e) => {
            const next = e.target.checked
              ? [...new Set([...values, o.value])]
              : values.filter((v) => v !== o.value);
            onChange(next);
          },
        }),
        h("span", { class: "choice__box" }, icon("check")),
        h("span", {}, o.label),
        isFlag ? h("span", { class: "choice__flagmark" }, "Urgent") : null
      );
    })
  );
}

export function radioGroup({ name, value, options, onChange, stack = false }) {
  return h("div", { class: `choices ${stack ? "choices--stack" : ""}`, role: "radiogroup" },
    options.map((o) =>
      h("label", { class: "choice choice--radio" },
        h("input", {
          type: "radio", name, checked: value === o.value,
          onChange: () => onChange(o.value),
        }),
        h("span", { class: "choice__box" }, icon("check")),
        h("span", {}, o.label)
      ))
  );
}

export function alert({ kind = "info", title, text, items }) {
  return h("div", { class: `alert alert--${kind}`, role: kind === "urgent" ? "alert" : null },
    icon(kind === "urgent" ? "siren" : kind === "ok" ? "check" : kind === "warn" ? "alert" : "info"),
    h("div", { class: "alert__body" },
      title ? h("p", { class: "alert__title" }, title) : null,
      text  ? h("p", { class: "alert__text" }, text)   : null,
      items && items.length
        ? h("ul", {}, items.map((i) => h("li", {}, i)))
        : null
    )
  );
}

export function card(title, hint, ...body) {
  return h("div", { class: "card" },
    title ? h("h2", { class: "card__title" }, title) : null,
    hint  ? h("p",  { class: "card__hint" }, hint)   : null,
    ...body
  );
}
