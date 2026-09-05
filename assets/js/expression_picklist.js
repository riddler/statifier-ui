// The picklist mode for StatifierUI.Live.ExpressionInput.
//
// ADR-0009 ships this package's JavaScript as source, so this file imports
// nothing and the host's own bundler compiles it.
//
// **This hook knows nothing about the expression language.** It does not know
// how an operator is spelled, how a string is quoted, what separates the
// members of a list, or which operators go with which kind of value. Every one
// of those is measured on the server by round-tripping through
// `Predicator.Simple.to_source/1` and handed over on the element:
//
//   an <option>'s value      the COMPLETE expression source choosing it produces
//   data-source              the same, on a button
//   data-source-template     that source with the value replaced by a stand-in
//   data-sentinel            the stand-in's own spelling, to substitute for
//   data-wrap-prefix/suffix  what surrounds a typed value (a string's quotes)
//   data-escapes             [[from, to], ...] the writer's own escaping
//   data-list-open/-separator/-close   how the writer punctuates a list
//
// So the hook only ever copies or splices strings the server wrote, and the
// source text stays the single representation of the condition. A picklist
// holding clause rows of its own would be a second one.
//
// Writing works exactly as the completion popup's does: the string goes into
// the same named <input> the text mode edits, and a bubbling `input` event
// makes the host's own form change event fire. The server re-renders the rows
// from the new source, and one thing does have to be put back afterwards - see
// `resync` for the control whose patch LiveView deliberately skips.

export const StatifierUIExpressionPicklist = {
  mounted() {
    // The mode is the viewer's, not the server's: a re-render from the host
    // must not drag an author back out of the mode they picked. The server
    // decides only the first one.
    this.mode = this.el.getAttribute("data-mode");

    this.onChange = (event) => this.changed(event);
    this.onClick = (event) => this.clicked(event);
    this.onKeyDown = (event) => this.keydown(event);

    // Delegated, so the listeners survive every patch that replaces the rows.
    this.el.addEventListener("change", this.onChange);
    this.el.addEventListener("click", this.onClick);
    this.el.addEventListener("keydown", this.onKeyDown);

    this.el.setAttribute("data-picklist-hook", "attached");
    this.apply();
    this.resync();
  },

  updated() {
    this.el.setAttribute("data-picklist-hook", "attached");
    this.apply();
    this.resync();
    this.restoreFocus();
  },

  destroyed() {
    this.el.removeEventListener("change", this.onChange);
    this.el.removeEventListener("click", this.onClick);
    this.el.removeEventListener("keydown", this.onKeyDown);
  },

  // -- modes ---------------------------------------------------------------

  picklist() {
    return this.el.querySelector(".statifier-ui-expression-picklist");
  },

  text() {
    return this.el.querySelector(".statifier-ui-expression-text");
  },

  // A source string that left the subset takes the picklist with it: the rows
  // are simply not rendered, and text is the only mode there is.
  apply() {
    const picklist = this.picklist();
    if (!picklist) this.mode = "text";

    const showPicklist = this.mode === "picklist" && !!picklist;

    if (picklist) picklist.hidden = !showPicklist;
    const text = this.text();
    if (text) text.hidden = showPicklist;

    this.el.setAttribute("data-mode", showPicklist ? "picklist" : "text");

    this.el.querySelectorAll("[data-action^='switch-']").forEach((button) => {
      const wants = button.getAttribute("data-action") === "switch-picklist";
      button.setAttribute("aria-pressed", String(wants === showPicklist));
    });
  },

  switchTo(mode) {
    this.mode = mode;
    this.apply();
    this.focusFirst();
  },

  // Keyboard parity: switching modes leaves the caret somewhere useful rather
  // than on a button that just hid what it was pointing at.
  focusFirst() {
    const pane = this.mode === "picklist" ? this.picklist() : this.text();
    const target = pane && pane.querySelector("select, input");
    if (target) target.focus();
  },

  // -- interaction ---------------------------------------------------------

  changed(event) {
    const control = event.target.closest("[data-role]");
    if (!control || !this.el.contains(control)) return;

    this.remember(control);
    this.write(this.sourceFor(control));
  },

  clicked(event) {
    const button = event.target.closest("[data-action]");
    if (!button || !this.el.contains(button)) return;

    const action = button.getAttribute("data-action");

    if (action === "switch-text") return this.switchTo("text");
    if (action === "switch-picklist") return this.switchTo("picklist");

    // add-clause and remove-clause each carry the whole source they produce,
    // so adding a row is writing a longer expression rather than pushing onto
    // a list held here.
    event.preventDefault();
    this.write(button.getAttribute("data-source"));
  },

  keydown(event) {
    if (event.key !== "Enter") return;

    const control = event.target.closest("[data-value-kind='text']");
    if (!control || !this.el.contains(control)) return;

    // Enter inside the host's form would submit it. A value field commits
    // instead, which is what a `change` would have done on blur.
    event.preventDefault();
    this.remember(control);
    this.write(this.sourceFor(control));
  },

  // -- the source string ---------------------------------------------------

  sourceFor(control) {
    const kind = control.getAttribute("data-value-kind");

    if (kind === "text") return this.splice(control, this.wrap(control, control.value));
    if (kind === "multiselect") return this.splice(control, this.list(control));

    // Everything else chooses rather than composes: the option's value is
    // already the complete source.
    return control.value;
  },

  splice(control, replacement) {
    const template = control.getAttribute("data-source-template");
    const sentinel = control.getAttribute("data-sentinel");
    if (!template || !sentinel) return null;

    return template.replace(sentinel, () => replacement);
  },

  wrap(control, raw) {
    const prefix = control.getAttribute("data-wrap-prefix") || "";
    const suffix = control.getAttribute("data-wrap-suffix") || "";

    return prefix + this.escape(control, raw) + suffix;
  },

  escape(control, raw) {
    let escaped = raw;

    for (const [from, to] of readEscapes(control)) {
      escaped = escaped.split(from).join(to);
    }

    return escaped;
  },

  list(control) {
    const open = control.getAttribute("data-list-open") || "";
    const separator = control.getAttribute("data-list-separator") || "";
    const close = control.getAttribute("data-list-close") || "";
    const chosen = Array.from(control.selectedOptions).map((option) => option.value);

    return open + chosen.join(separator) + close;
  },

  write(source) {
    if (typeof source !== "string") return;

    const input = this.el.querySelector("[data-expression-source]");
    if (!input) return;

    input.value = source;

    // The host's form owns the change event, exactly as it does for a typed
    // character and for a completion.
    input.dispatchEvent(new Event("input", { bubbles: true }));
  },

  // -- the selection across a patch ----------------------------------------

  // LiveView refuses to patch a `<select>` that has focus unless it can tell
  // the option list changed, and for these controls it usually cannot: the
  // operator row offers every operator over the same remainder, so picking a
  // different one leaves the SET of option values identical and only moves
  // which one is marked. The patch is skipped, the `selected` attributes stay
  // where they were, and the control keeps painting the operator the author
  // replaced - the hook's own `restoreFocus` is what leaves it focused, so
  // this lands on exactly the control the author just used.
  //
  // Reading the marked option back would not help, because in that case the
  // attributes are the stale thing. What is never stale is the source: it
  // arrives on the named input, and an option's value IS the whole source
  // choosing it produces, so the option to select is the one that spells what
  // the server just rendered. No new vocabulary, and nothing to keep in sync
  // between patches.
  resync() {
    const input = this.el.querySelector("[data-expression-source]");
    if (!input) return;

    // The attribute is the server's value; the property may hold text the
    // author is still typing, which is the text mode's business, not a row's.
    const source = input.getAttribute("value");
    if (source === null) return;

    // A multi-select is left alone: its options carry list fragments rather
    // than whole sources, and LiveView skips it while focused precisely so an
    // author's part-made selection survives the round trip.
    this.el.querySelectorAll("select[data-role]:not([multiple])").forEach((select) => {
      const match = Array.from(select.options).find((option) => option.value === source);

      if (match && !match.selected) match.selected = true;
    });
  },

  // -- focus across a patch ------------------------------------------------

  remember(control) {
    const row = control.closest("[data-clause-index]");

    this.focused = {
      role: control.getAttribute("data-role"),
      index: row ? row.getAttribute("data-clause-index") : null,
    };
  },

  restoreFocus() {
    if (!this.focused) return;

    const { role, index } = this.focused;
    const scope =
      index === null
        ? this.el
        : this.el.querySelector(`[data-clause-index="${index}"]`) || this.el;
    const target = scope.querySelector(`[data-role="${role}"]`);

    if (target) target.focus();
    this.focused = null;
  },
};

function readEscapes(control) {
  try {
    const raw = control.getAttribute("data-escapes");
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed : [];
  } catch (_error) {
    // An unescaped quote makes a source string the author can still fix in
    // text mode. A thrown exception makes a dead field.
    return [];
  }
}

export default StatifierUIExpressionPicklist;
