// Noodle's document-local compatibility layer for the WebMCP draft API.
// Installed in the page world before website scripts. No native capabilities
// are exposed here; the signed Browser broker remains the agent access boundary.
(() => {
  "use strict";
  if (globalThis.__noodleWebMCP) return;
  const maxTools = 256;
  const maxBytes = 1048576;
  // randomUUID is secure-context-only; unavailable pages still need to report
  // an explicit unsupported status through the CLI.
  const uuid = () => Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, "0")).join("");
  let documentID = uuid();
  const origin = location.origin;
  const registered = new Map();
  const forms = new Map();
  const descriptors = new WeakMap();
  const handles = new Map();
  const activeForms = new Map();
  const humanSubmit = Symbol("human submission required");
  const navigationStarted = Symbol("form navigation started");
  let context;
  let native = false;

  function fault(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
  }
  function copy(value) {
    const json = JSON.stringify(value);
    if (json === undefined) throw fault("INVALID_JSON", "The value is not JSON serializable.");
    if (new TextEncoder().encode(json).length > maxBytes) throw fault("TOO_LARGE", "WebMCP data exceeds 1 MiB.");
    return JSON.parse(json);
  }
  function eligibility() {
    if (!isSecureContext || !["http:", "https:"].includes(location.protocol) || origin === "null") {
      return "WebMCP requires HTTPS or a secure loopback HTTP document.";
    }
    if (document.domain && document.domain !== location.hostname) return "Relaxed document.domain is unsupported.";
    try {
      if (top.location.origin !== origin) return "Cross-origin frame tools are not supported by this compatibility layer.";
      let win = window;
      while (win !== top) {
        const frame = win.frameElement;
        const directives = (frame?.getAttribute("allow") || "").split(";");
        for (const value of directives) {
          const tokens = value.trim().split(/\s+/);
          if (tokens[0] !== "tools") continue;
          if (tokens.includes("'none'")) return "WebMCP is disabled by the frame policy.";
          if (tokens.length > 1 && !tokens.some(t => ["*", "'self'", "'src'", origin].includes(t))) {
            return "WebMCP is disabled by the frame policy.";
          }
        }
        win = win.parent;
      }
    } catch (_) { return "Cross-origin or sandboxed frame tools are unsupported."; }
    const policy = document.permissionsPolicy || document.featurePolicy;
    if (policy?.features?.().includes("tools") && !policy.allowsFeature("tools")) return "WebMCP is disabled by Permissions Policy.";
    return null;
  }
  function assertEligible() {
    const reason = eligibility();
    if (reason) throw fault("UNSUPPORTED_CONTEXT", reason);
  }
  const isObject = value => value !== null && typeof value === "object" && !Array.isArray(value);
  function equal(a, b) {
    if (a === b) return true;
    if (!a || !b || typeof a !== "object" || typeof b !== "object" || Array.isArray(a) !== Array.isArray(b)) return false;
    const keys = Object.keys(a);
    return keys.length === Object.keys(b).length && keys.every(k => Object.hasOwn(b, k) && equal(a[k], b[k]));
  }

  // A bounded JSON Schema subset. Unsupported validation keywords fail
  // explicitly instead of pretending the arguments were checked.
  function validate(value, schema, root = schema, path = "$", depth = 0) {
    if (depth > 64) throw fault("UNSUPPORTED_SCHEMA", "Schema nesting exceeds 64 levels.");
    const invalid = message => { throw fault("INVALID_ARGUMENTS", `${path}: ${message}`); };
    if (schema === true) return;
    if (schema === false) invalid("value is not allowed");
    if (!isObject(schema)) throw fault("UNSUPPORTED_SCHEMA", "Expected a JSON Schema object or boolean.");
    const supported = new Set(["$ref", "$defs", "definitions", "$schema", "$id", "$comment", "title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly", "format", "contentEncoding", "contentMediaType", "type", "enum", "const", "properties", "required", "additionalProperties", "minProperties", "maxProperties", "items", "minItems", "maxItems", "uniqueItems", "minLength", "maxLength", "pattern", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "allOf", "anyOf", "oneOf", "not"]);
    for (const key of Object.keys(schema)) if (!supported.has(key)) throw fault("UNSUPPORTED_SCHEMA", `Unsupported JSON Schema keyword: ${key}`);
    const check = (v, s, p = path) => validate(v, s, root, p, depth + 1);
    if (schema.$ref !== undefined) {
      if (typeof schema.$ref !== "string" || !schema.$ref.startsWith("#/")) throw fault("UNSUPPORTED_SCHEMA", "Only local JSON Schema references are supported.");
      let target = root;
      for (const token of schema.$ref.slice(2).split("/")) {
        const key = token.replace(/~1/g, "/").replace(/~0/g, "~");
        if (!isObject(target) || !Object.hasOwn(target, key)) throw fault("UNSUPPORTED_SCHEMA", "Unresolved JSON Schema reference.");
        target = target[key];
      }
      check(value, target);
    }
    if (schema.type !== undefined) {
      const types = Array.isArray(schema.type) ? schema.type : [schema.type];
      const matches = type => ({ null: value === null, object: isObject(value), array: Array.isArray(value), string: typeof value === "string", boolean: typeof value === "boolean", number: typeof value === "number" && Number.isFinite(value), integer: Number.isInteger(value) })[type];
      if (!types.some(matches)) invalid(`expected ${types.join(" or ")}`);
    }
    if (schema.enum && !schema.enum.some(v => equal(value, v))) invalid("value is outside the allowed enum");
    if (Object.hasOwn(schema, "const") && !equal(value, schema.const)) invalid("value does not match const");
    for (const s of schema.allOf || []) check(value, s);
    const passes = s => { try { check(value, s); return true; } catch (e) { if (e.code !== "INVALID_ARGUMENTS") throw e; return false; } };
    if (schema.anyOf && !schema.anyOf.some(passes)) invalid("no anyOf alternative matches");
    if (schema.oneOf && schema.oneOf.filter(passes).length !== 1) invalid("exactly one oneOf alternative must match");
    if (schema.not && passes(schema.not)) invalid("matches a forbidden schema");
    if (isObject(value)) {
      for (const key of schema.required || []) if (!Object.hasOwn(value, key)) invalid(`missing required property ${key}`);
      const keys = Object.keys(value);
      if (keys.length < (schema.minProperties ?? 0) || keys.length > (schema.maxProperties ?? Infinity)) invalid("property count is outside its bounds");
      for (const key of keys) {
        if (schema.properties && Object.hasOwn(schema.properties, key)) check(value[key], schema.properties[key], `${path}.${key}`);
        else if (schema.additionalProperties !== undefined) check(value[key], schema.additionalProperties, `${path}.${key}`);
      }
    }
    if (Array.isArray(value)) {
      if (value.length < (schema.minItems ?? 0) || value.length > (schema.maxItems ?? Infinity)) invalid("array length is outside its bounds");
      if (schema.uniqueItems && value.some((v, i) => value.slice(0, i).some(other => equal(v, other)))) invalid("array items must be unique");
      if (schema.items !== undefined) value.forEach((v, i) => check(v, schema.items, `${path}[${i}]`));
    }
    if (typeof value === "string") {
      const length = Array.from(value).length;
      if (length < (schema.minLength ?? 0) || length > (schema.maxLength ?? Infinity)) invalid("string length is outside its bounds");
      if (schema.pattern !== undefined && !new RegExp(schema.pattern, "u").test(value)) invalid("string does not match pattern");
    }
    if (typeof value === "number") {
      if (value < (schema.minimum ?? -Infinity) || value > (schema.maximum ?? Infinity) || value <= (schema.exclusiveMinimum ?? -Infinity) || value >= (schema.exclusiveMaximum ?? Infinity)) invalid("number is outside its bounds");
      if (schema.multipleOf !== undefined && Math.abs(value / schema.multipleOf - Math.round(value / schema.multipleOf)) > 1e-10) invalid("number is not an allowed multiple");
    }
  }

  function changed() { context?.dispatchEvent(new Event("toolchange")); }
  function descriptor(record) {
    const value = Object.freeze({ ...copy(record.metadata), origin, window });
    descriptors.set(value, record);
    return value;
  }
  function nameValid(name) { return typeof name === "string" && /^[a-zA-Z0-9_.-]{1,128}$/.test(name); }
  function controls(form) {
    return Array.from(form.elements).filter(e => e.name && !e.matches(":disabled") && ["INPUT", "SELECT", "TEXTAREA"].includes(e.tagName) && !["submit", "reset", "button", "image", "hidden"].includes(e.type));
  }
  function formMetadata(form) {
    const properties = Object.create(null), required = new Set();
    const fields = controls(form);
    if (fields.length > 512) throw fault("TOO_LARGE", "A WebMCP form exceeds 512 controls.");
    for (const field of fields) {
      let schema = { type: "string" };
      if (field.type === "checkbox") schema.type = "boolean";
      if (["number", "range"].includes(field.type)) {
        schema.type = "number";
        if (field.min !== "") schema.minimum = Number(field.min);
        if (field.max !== "") schema.maximum = Number(field.max);
      }
      if (field.type === "radio") {
        schema.enum = fields.filter(e => e.type === "radio" && e.name === field.name).map(e => e.value);
      } else if (field.tagName === "SELECT") {
        const values = Array.from(field.options).filter(o => !o.disabled && !o.closest("optgroup[disabled]")).map(o => o.value);
        schema = field.multiple ? { type: "array", items: { type: "string", enum: values }, uniqueItems: true } : { type: "string", enum: values };
      }
      const description = field.getAttribute("toolparamdescription") || Array.from(field.labels || []).map(l => l.textContent.trim()).join(" ") || field.getAttribute("aria-description");
      if (description) schema.description = description;
      if (schema.type === "string" && field.minLength >= 0) schema.minLength = field.minLength;
      if (schema.type === "string" && field.maxLength >= 0) schema.maxLength = field.maxLength;
      properties[field.name] = schema;
      if (field.required) required.add(field.name);
    }
    return { name: form.getAttribute("toolname"), description: form.getAttribute("tooldescription"),
      inputSchema: { type: "object", properties, required: Array.from(required), additionalProperties: false } };
  }
  function syncForms() {
    let didChange = false;
    const seen = new Set();
    for (const form of document.querySelectorAll("form[toolname][tooldescription]")) {
      if (!nameValid(form.getAttribute("toolname")) || !form.getAttribute("tooldescription")?.trim()) continue;
      seen.add(form);
      const metadata = formMetadata(form);
      const signature = JSON.stringify([metadata, form.getAttribute("action"), form.getAttribute("method"), form.hasAttribute("toolautosubmit")]);
      const previous = forms.get(form);
      if (!previous || previous.signature !== signature) {
        forms.set(form, { id: uuid(), kind: "declarative", metadata, form, signature });
        didChange = true;
      }
    }
    for (const form of forms.keys()) if (!seen.has(form)) {
      forms.delete(form); activeForms.get(form)?.(); didChange = true;
    }
    if (didChange) changed();
  }
  function records() {
    syncForms();
    const result = [...registered.values(), ...forms.values()];
    if (result.length > maxTools) throw fault("TOO_LARGE", "This document exposes more than 256 tools.");
    return result.sort((a, b) => a.metadata.name.localeCompare(b.metadata.name));
  }
  function current(record) {
    syncForms();
    return record.kind === "imperative" ? registered.get(record.metadata.name) === record : forms.get(record.form) === record && record.form.isConnected;
  }
  function fireToolEvent(type, name) {
    for (const target of [window, context]) {
      const event = new Event(type);
      Object.defineProperty(event, "toolName", { value: name });
      target.dispatchEvent(event);
    }
  }
  function prepareForm(record, args) {
    const fields = controls(record.form);
    for (const [name, value] of Object.entries(args)) {
      const group = fields.filter(e => e.name === name);
      if (group.some(e => e.type === "file")) throw fault("UNSUPPORTED_FORM", "Use browser upload for file controls before invoking a tool; file paths cannot be passed as tool arguments.");
      if (group.length > 1 && !group.every(e => e.type === "radio")) throw fault("UNSUPPORTED_FORM", `Repeated field ${name} is unsupported.`);
      for (const field of group) {
        if (field.readOnly) throw fault("INVALID_ARGUMENTS", `Field ${name} is read-only.`);
        if (field.type === "checkbox") field.checked = value;
        else if (field.type === "radio") field.checked = field.value === value;
        else if (field.tagName === "SELECT" && field.multiple) { for (const option of field.options) option.selected = value.includes(option.value); }
        else {
          const prototype = field.tagName === "SELECT" ? HTMLSelectElement.prototype : field.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          Object.getOwnPropertyDescriptor(prototype, "value").set.call(field, String(value));
        }
        field.dispatchEvent(new Event("input", { bubbles: true }));
        field.dispatchEvent(new Event("change", { bubbles: true }));
      }
    }
    fireToolEvent("toolactivated", record.metadata.name);
    if (!record.form.checkValidity()) throw fault("INVALID_ARGUMENTS", "The form rejected one or more field values. Inspect the form before retrying.");
  }
  function executeForm(record, args, signal, manualReturn) {
    const form = record.form;
    if (activeForms.has(form)) throw fault("TOOL_BUSY", "This form already has an active tool call. Submit or reset it before calling again.");
    prepareForm(record, args);
    const automatic = form.hasAttribute("toolautosubmit");
    return new Promise((resolve, reject) => {
      const cleanup = () => {
        form.removeEventListener("submit", submit, true);
        form.removeEventListener("reset", reset);
        signal?.removeEventListener("abort", aborted);
        activeForms.delete(form);
      };
      const reset = () => { cleanup(); fireToolEvent("toolcancel", record.metadata.name); reject(fault("CANCELLED", "The form was reset.")); };
      const aborted = () => { cleanup(); fireToolEvent("toolcancel", record.metadata.name); reject(signal.reason || fault("CANCELLED", "Tool execution cancelled.")); };
      const submit = event => {
        let response, responded = false;
        Object.defineProperties(event, {
          agentInvoked: { value: true },
          respondWith: { value: value => {
            if (!event.defaultPrevented) throw new DOMException("Call preventDefault before respondWith.", "InvalidStateError");
            if (responded || event.eventPhase === Event.NONE) throw new DOMException("respondWith must be called once during submission.", "InvalidStateError");
            responded = true; response = Promise.resolve(value);
            response.catch(() => {}); // The submission task observes rejection.
          } }
        });
        // Real user events can run microtask checkpoints between listeners.
        // Wait for dispatch to finish before observing respondWith/preventDefault.
        setTimeout(() => {
          cleanup();
          if (responded) response.then(resolve, reject);
          else if (event.defaultPrevented) resolve(null);
          else resolve(navigationStarted);
        }, 0);
      };
      form.addEventListener("submit", submit, true);
      form.addEventListener("reset", reset);
      signal?.addEventListener("abort", aborted, { once: true });
      activeForms.set(form, () => { cleanup(); reject(fault("CANCELLED", "The form or its document was removed.")); });
      if (signal?.aborted) { aborted(); return; }
      if (automatic) HTMLFormElement.prototype.requestSubmit.call(form);
      else {
        const submitter = Array.from(form.elements).find(e => ["submit", "image"].includes(e.type) && !e.matches(":disabled"));
        submitter?.focus({ preventScroll: true });
        // The CLI returns a handoff state instead of blocking or opening a
        // window. Keep submit/reset listeners so a later human submit is marked.
        if (manualReturn) resolve(humanSubmit);
      }
    });
  }
  async function execute(record, args, signal, manualReturn = false) {
    assertEligible();
    if (!current(record)) throw fault("STALE_TOOL", "The tool changed or was removed. List tools again.");
    if (!isObject(args)) throw fault("INVALID_ARGUMENTS", "Tool arguments must be a JSON object.");
    args = copy(args);
    validate(args, record.metadata.inputSchema);
    if (signal?.aborted) throw signal.reason;
    if (record.kind === "declarative") return executeForm(record, args, signal, manualReturn);
    fireToolEvent("toolactivated", record.metadata.name);
    const cancelled = () => fireToolEvent("toolcancel", record.metadata.name);
    signal?.addEventListener("abort", cancelled, { once: true });
    try { return await record.execute(args, { signal: signal || new AbortController().signal }); }
    finally { signal?.removeEventListener("abort", cancelled); }
  }

  class ModelContext extends EventTarget {
    #handler = null;
    #eventHandlers = new Map();
    #setHandler(type, value) {
      const previous = this.#eventHandlers.get(type);
      if (previous) this.removeEventListener(type, previous);
      const handler = typeof value === "function" ? value : null;
      this.#eventHandlers.set(type, handler);
      if (handler) this.addEventListener(type, handler);
    }
    get ontoolactivated() { return this.#eventHandlers.get("toolactivated") || null; }
    set ontoolactivated(value) { this.#setHandler("toolactivated", value); }
    get ontoolcancel() { return this.#eventHandlers.get("toolcancel") || null; }
    set ontoolcancel(value) { this.#setHandler("toolcancel", value); }
    get ontoolchange() { return this.#handler; }
    set ontoolchange(value) {
      if (this.#handler) this.removeEventListener("toolchange", this.#handler);
      this.#handler = typeof value === "function" ? value : null;
      if (this.#handler) this.addEventListener("toolchange", this.#handler);
    }
    async registerTool(tool, options = {}) {
      assertEligible();
      if (!tool || !nameValid(tool.name) || typeof tool.description !== "string" || !tool.description.trim() || typeof tool.execute !== "function") throw new TypeError("A tool requires a valid name, description and execute function.");
      // Keep the local tool usable when a site also opts into cross-origin
      // exposure. This runtime never shares it with those additional origins.
      if (options.exposedTo !== undefined && !Array.isArray(options.exposedTo)) throw new TypeError("exposedTo must be an array of origins.");
      if (options.signal?.aborted) throw options.signal.reason;
      if (registered.has(tool.name)) throw new DOMException("Tool name already registered.", "InvalidStateError");
      if (registered.size >= maxTools) throw fault("TOO_LARGE", "At most 256 tools may be registered.");
      const metadata = copy({ name: tool.name, description: tool.description, title: tool.title || "", inputSchema: tool.inputSchema ?? { type: "object", properties: {}, additionalProperties: false }, annotations: tool.annotations || {} });
      if (!isObject(metadata.inputSchema)) throw new TypeError("inputSchema must be an object.");
      const record = { id: uuid(), kind: "imperative", metadata, execute: tool.execute };
      registered.set(metadata.name, record);
      options.signal?.addEventListener("abort", () => {
        if (registered.get(metadata.name) === record) { registered.delete(metadata.name); changed(); }
      }, { once: true });
      changed();
    }
    async getTools(options = {}) {
      assertEligible();
      if (options.fromOrigins?.some(value => value !== origin)) throw fault("UNSUPPORTED_CONTEXT", "Cross-origin tool discovery is unsupported by this compatibility layer.");
      return records().map(descriptor);
    }
    async executeTool(tool, args = {}, options = {}) {
      const record = descriptors.get(tool);
      if (!record) throw fault("STALE_TOOL", "Use a descriptor returned by getTools in this document.");
      const signal = options.signal;
      let abort;
      try {
        const cancellation = new Promise((_, reject) => {
          abort = () => reject(signal.reason || fault("CANCELLED", "Tool execution cancelled."));
          signal?.addEventListener("abort", abort, { once: true });
        });
        const result = await Promise.race([execute(record, args, signal), cancellation]);
        return result == null || result === navigationStarted ? null : typeof result === "string" ? result : JSON.stringify(copy(result));
      } finally { signal?.removeEventListener("abort", abort); }
    }
  }

  if (!eligibility()) {
    if (document.modelContext) {
      context = document.modelContext;
      native = true;
      context.addEventListener("toolchange", () => handles.clear());
    } else {
      context = new ModelContext();
      Object.defineProperty(document, "modelContext", { value: context, enumerable: true });
      // Early adopters used navigator.modelContext. Share the same registry.
      if (!navigator.modelContext) Object.defineProperty(navigator, "modelContext", { get: () => context });
      const observer = new MutationObserver(() => { try { syncForms(); } catch (_) { /* Report on explicit discovery. */ } });
      observer.observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ["toolname", "tooldescription", "toolparamdescription", "toolautosubmit", "name", "type", "required", "disabled", "multiple", "min", "max", "minlength", "maxlength", "value", "action", "method"] });
    }
  }
  const details = () => ({ implementation: native ? "native" : "compatibility", documentID, origin, url: location.href });
  const bridge = Object.freeze({
    async list() {
      const reason = eligibility();
      if (reason) return { ...details(), status: "unsupported", reason, tools: [] };
      if (typeof context?.getTools !== "function" || typeof context?.executeTool !== "function") throw fault("UNSUPPORTED_API", "The page's WebMCP API lacks getTools/executeTool.");
      let items;
      if (native) {
        const available = await context.getTools();
        handles.clear();
        items = available.filter(tool => tool.window === window && tool.origin === origin).map(tool => {
          const id = `${documentID}:${uuid()}`;
          handles.set(id, tool);
          return { id, name: tool.name, title: tool.title, description: tool.description, inputSchema: tool.inputSchema, annotations: tool.annotations, origin };
        });
      } else {
        handles.clear();
        items = records().map(record => {
          const id = `${documentID}:${record.id}`;
          handles.set(id, record);
          return { id, ...copy(record.metadata), origin, kind: record.kind, ...(record.form ? { requiresUserSubmit: !record.form.hasAttribute("toolautosubmit") } : {}) };
        });
      }
      if (items.length > maxTools) throw fault("TOO_LARGE", "This document exposes more than 256 tools.");
      return { ...details(), status: items.length ? "available" : "empty", tools: items };
    },
    async call(id, argumentsJSON) {
      const controller = new AbortController();
      let timer;
      try {
        assertEligible();
        const tool = handles.get(id);
        if (!tool || !id.startsWith(`${documentID}:`)) throw fault("STALE_TOOL", "Tool ID is stale or belongs to another document. List tools again.");
        const args = JSON.parse(argumentsJSON);
        if (!isObject(args)) throw fault("INVALID_ARGUMENTS", "Tool arguments must be a JSON object.");
        const timeout = new Promise((_, reject) => {
          timer = setTimeout(() => {
            const error = fault("TIMEOUT", "Tool execution timed out. The action may have run; inspect the page before retrying.");
            controller.abort(error); reject(error);
          }, 15000);
        });
        const pending = native ? context.executeTool(tool, args, { signal: controller.signal }) : execute(tool, args, controller.signal, true);
        const result = await Promise.race([pending, timeout]);
        if (result === humanSubmit) return { ...details(), status: "needs-user-action", toolID: id, message: "The form is filled and requires human submission. Use present for a browser handoff." };
        if (result === navigationStarted) return { ...details(), status: "navigation-started", toolID: id, result: null };
        return { ...details(), status: "completed", toolID: id, result: result === undefined ? null : copy(result) };
      } catch (error) {
        return { ...details(), status: "error", toolID: id, error: { code: typeof error?.code === "string" ? error.code : error?.name || "TOOL_ERROR", message: String(error?.message || error) } };
      } finally { clearTimeout(timer); }
    }
  });
  Object.defineProperty(globalThis, "__noodleWebMCP", { value: bridge });
  addEventListener("pagehide", () => {
    documentID = uuid(); handles.clear();
    for (const cleanup of activeForms.values()) cleanup();
  });
})();
