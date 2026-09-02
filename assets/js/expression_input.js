// The completion popup for StatifierUI.Live.ExpressionInput.
//
// ADR-0009 ships this package's JavaScript as source: the host's own bundler
// compiles it, and this file imports nothing so there is no dependency graph
// for it to compile. The editor pane's CodeMirror 6 (also ADR-0009) is a
// different surface with different needs; a one-line expression field does not
// need a code editor, and pulling one in here would make every host that wants
// completion on a text input pay for one.
//
// Everything the hook needs arrives on the element:
//
//   data-completions  a JSON array of {label, insert, kind, detail}
//   data-vocabulary   "true" when the grammar half of that array resolved
//
// The hook never talks to the server. It writes into the input and dispatches
// a bubbling `input` event, which is how the host's own `phx-change` form sees
// a completion and a keystroke as the same thing.

const MAX_VISIBLE = 8;

// A predicator path is dotted, so the token under the caret runs back through
// letters, digits, underscores and dots. Anything else - a space, an operator,
// a bracket - ends it.
const TOKEN = /[A-Za-z0-9_.]*$/;

export const StatifierUIExpressionInput = {
  mounted() {
    this.completions = readCompletions(this.el);
    this.index = 0;
    this.open = false;
    this.inserting = false;

    // The native <datalist> is the no-JavaScript affordance. With the hook
    // running it would be a second, less capable list over the same data, so
    // the upgrade replaces it rather than sitting beside it.
    this.datalistId = this.el.getAttribute("list");
    this.el.removeAttribute("list");

    // The popup lives on <body>, not inside the hook element: LiveView patches
    // the DOM it rendered, and a node it did not render inside a patched
    // container is a node it may remove between keystrokes.
    this.popup = document.createElement("ul");
    this.popup.className = "statifier-ui-expression-popup";
    this.popup.setAttribute("role", "listbox");
    this.popup.hidden = true;
    document.body.appendChild(this.popup);

    this.onInput = () => this.refresh();
    this.onKeyDown = (event) => this.keydown(event);
    this.onBlur = () => this.hide();
    this.onPointerDown = (event) => this.pick(event);

    this.el.addEventListener("input", this.onInput);
    this.el.addEventListener("click", this.onInput);
    this.el.addEventListener("keydown", this.onKeyDown);
    this.el.addEventListener("blur", this.onBlur);
    // pointerdown, not click: `blur` fires first on a click and would hide the
    // popup out from under it.
    this.popup.addEventListener("pointerdown", this.onPointerDown);

    this.el.setAttribute("data-hook", "attached");
  },

  updated() {
    // The server can re-render the field with a different candidate set.
    this.completions = readCompletions(this.el);
    this.el.removeAttribute("list");
    this.el.setAttribute("data-hook", "attached");
    if (this.open) this.refresh();
  },

  destroyed() {
    this.el.removeEventListener("input", this.onInput);
    this.el.removeEventListener("click", this.onInput);
    this.el.removeEventListener("keydown", this.onKeyDown);
    this.el.removeEventListener("blur", this.onBlur);
    if (this.popup) this.popup.remove();
    if (this.datalistId) this.el.setAttribute("list", this.datalistId);
  },

  // -- the list ------------------------------------------------------------

  prefix() {
    const caret = this.el.selectionStart ?? this.el.value.length;
    const match = this.el.value.slice(0, caret).match(TOKEN);
    return match ? match[0] : "";
  },

  matches() {
    const prefix = this.prefix().toLowerCase();
    if (prefix === "") return [];

    return this.completions
      .filter((entry) => entry.insert.toLowerCase().startsWith(prefix))
      .slice(0, MAX_VISIBLE);
  },

  refresh() {
    // The insert below dispatches a bubbling `input` event, which this hook's
    // own listener hears. Without this guard the completion just written in
    // becomes the prefix of a fresh popup offering the same entry back.
    if (this.inserting) return this.hide();

    const matches = this.matches();
    if (matches.length === 0) return this.hide();

    this.visible = matches;
    this.index = Math.min(this.index, matches.length - 1);
    this.render();
    this.place();
    this.popup.hidden = false;
    this.open = true;
    this.el.setAttribute("aria-expanded", "true");
  },

  render() {
    this.popup.replaceChildren(
      ...this.visible.map((entry, i) => {
        const item = document.createElement("li");
        item.className = "statifier-ui-expression-option";
        item.setAttribute("role", "option");
        item.setAttribute("data-kind", entry.kind);
        item.setAttribute("data-index", String(i));
        item.setAttribute("aria-selected", String(i === this.index));
        if (i === this.index) item.classList.add("is-selected");

        const label = document.createElement("span");
        label.className = "statifier-ui-expression-option-label";
        label.textContent = entry.label;
        item.appendChild(label);

        const kind = document.createElement("span");
        kind.className = "statifier-ui-expression-option-kind";
        kind.textContent = entry.kind;
        item.appendChild(kind);

        if (entry.detail) {
          const detail = document.createElement("span");
          detail.className = "statifier-ui-expression-option-detail";
          detail.textContent = entry.detail;
          item.appendChild(detail);
        }

        return item;
      })
    );
  },

  place() {
    const box = this.el.getBoundingClientRect();
    this.popup.style.position = "absolute";
    this.popup.style.top = `${box.bottom + window.scrollY}px`;
    this.popup.style.left = `${box.left + window.scrollX}px`;
    this.popup.style.minWidth = `${box.width}px`;
  },

  hide() {
    if (!this.popup) return;
    this.popup.hidden = true;
    this.open = false;
    this.index = 0;
    this.el.setAttribute("aria-expanded", "false");
  },

  // -- interaction ---------------------------------------------------------

  keydown(event) {
    if (!this.open) return;

    switch (event.key) {
      case "ArrowDown":
        event.preventDefault();
        this.move(1);
        break;
      case "ArrowUp":
        event.preventDefault();
        this.move(-1);
        break;
      case "Enter":
      case "Tab":
        event.preventDefault();
        this.insert(this.visible[this.index]);
        break;
      case "Escape":
        event.preventDefault();
        this.hide();
        break;
      default:
        break;
    }
  },

  move(delta) {
    const count = this.visible.length;
    this.index = (this.index + delta + count) % count;
    this.render();
  },

  pick(event) {
    const item = event.target.closest("[data-index]");
    if (!item) return;
    event.preventDefault();
    this.insert(this.visible[Number(item.getAttribute("data-index"))]);
  },

  insert(entry) {
    if (!entry) return;

    const caret = this.el.selectionStart ?? this.el.value.length;
    const start = caret - this.prefix().length;
    const before = this.el.value.slice(0, start);
    const after = this.el.value.slice(caret);

    this.el.value = before + entry.insert + after;
    const position = start + entry.insert.length;
    this.el.setSelectionRange(position, position);
    this.el.focus();

    // The host's form owns the change event, so the completion has to look
    // like typing. Without this the server never learns the field changed.
    this.inserting = true;
    this.el.dispatchEvent(new Event("input", { bubbles: true }));
    this.inserting = false;

    this.hide();
  },
};

function readCompletions(el) {
  try {
    const raw = el.getAttribute("data-completions");
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed : [];
  } catch (_error) {
    // A field that offers nothing is a worse field, not a broken page.
    return [];
  }
}

export default StatifierUIExpressionInput;
