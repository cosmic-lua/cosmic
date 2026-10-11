--- The `htmx` dialect (`{{use htmx}}`): what a slot in an attribute of htmx,
--- or of its SSE, WebSocket and response-targets extensions, may be. The
--- table was read against htmx 2.0.11 (dist/htmx.js), htmx-ext-sse 2.2.2,
--- htmx-ext-ws 2.0.2 and htmx-ext-response-targets 2.0.2; every
--- `hx-*` attribute that source reads is either here or in `plain`, which
--- `template_dialect_test` pins. Private to [`cosmic.template`].
---
--- htmx reads each attribute as `hx-x` or `data-hx-x` (getAttributeValue),
--- so the families below also match with a `data-` prefix.

local types = require("cosmic.template.types")

--- A request or history URL. htmx fetches it and swaps the answer into the
--- page, so a cross-origin URL is a stored-XSS channel of its own (the
--- client's `selfRequestsOnly` is configuration an app may turn off): a
--- plain string must be a same-origin reference, and a deliberate other URL
--- is a `SafeUrl`.
local URL <const>: types.Rule = { class = "url_local", why = "" }

--- The value is JSON that htmx parses; with a `js:` or `javascript:` prefix
--- (after a trim) it evaluates it (getValuesForElement). A `SafeJson` is JSON
--- text and cannot begin with `j`, so a slot cannot make it code.
local JSON <const>: types.Rule = { class = "json", why = "" }

--- A CSS selector, or htmx's extension of one (`closest`, `find`, `next`,
--- `previous`, `this`, `global`, a comma list: querySelectorAllExt). No code
--- runs, but a selector chosen by data retargets where a response lands.
-- TODO: a slot in an attribute selector (`[data-id='{{.id}}']`) or a whole
-- selector from trusted code is refused; once cosmic.html has a CSS string
-- escaper (the JS and CSS escapers on doc/roadmap.md) the class takes the
-- first, and a typed selector value the second.
local SELECTOR <const>: types.Rule = { class = "selector", why = "" }

local def: types.Def = {
  name = "htmx",
  targets = "2.0.11",
  exact = {
    -- Request URLs (processVerbs reads them as the path of an XHR).
    ["hx-get"] = URL,
    ["hx-post"] = URL,
    ["hx-put"] = URL,
    ["hx-patch"] = URL,
    ["hx-delete"] = URL,
    -- `true`, `false` or a URL (determineHistoryUpdates): `true` is a
    -- relative reference and passes the same-origin check as itself.
    ["hx-push-url"] = URL,
    ["hx-replace-url"] = URL,
    -- htmx-ext-sse (an EventSource URL) and htmx-ext-ws (a WebSocket URL; a
    -- cross-origin or `wss:` one is a SafeUrl).
    ["sse-connect"] = URL,
    ["ws-connect"] = URL,

    ["hx-vals"] = JSON,
    ["hx-headers"] = JSON,
    ["hx-request"] = JSON,

    ["hx-target"] = SELECTOR,
    ["hx-select"] = SELECTOR,
    -- `#a:outerHTML,#b`: selectors with a swap style after a colon, which an
    -- escaped identifier cannot write (its colon is `\3a `).
    ["hx-select-oob"] = SELECTOR,
    ["hx-include"] = SELECTOR,
    ["hx-indicator"] = SELECTOR,
    ["hx-disabled-elt"] = SELECTOR,
    -- `closest form:abort`: a selector, then a strategy after a colon.
    ["hx-sync"] = SELECTOR,
    -- Its `scroll:` and `show:` modifiers take a selector (getSwapSpecification),
    -- `swap:` and `settle:` take a time. Whitespace separates the modifiers,
    -- so the space an escape ends in splits a selector there: that breaks a
    -- modifier, it does not make one (every modifier has a colon, and the
    -- escaper writes none).
    ["hx-swap"] = SELECTOR,
    -- `true`, a swap style, or `style:selector` (oobSwap).
    ["hx-swap-oob"] = SELECTOR,

    -- `hx-trigger` stays refused, as the always-on dialect has it: a
    -- trigger's `[filter]` is a JavaScript expression (maybeGenerateConditional),
    -- and `from:` takes a selector.

    -- The legacy form of the ws extension, `hx-ws="connect:URL"`, which
    -- still opens a socket; use `ws-connect`.
    ["hx-ws"] = { class = "refused",
      why = "is the legacy WebSocket form, whose URL follows 'connect:'; use ws-connect" },
  },
  prefixes = {
    -- htmx-ext-response-targets: `hx-target-422`, `hx-target-error`, `hx-target-*`.
    { prefix = "hx-target-", rule = SELECTOR },
  },
  families = { "hx-", "sse-", "ws-" },
  plain = {
    -- A dialog's text (window.confirm and window.prompt): no markup, no code.
    "hx-confirm", "hx-prompt",
    -- Behavior, not execution: `true`; `*`, `none` or a list of names;
    -- an encoding; extension names (only a registered one loads); attribute
    -- names; `false`; an id-less flag.
    "hx-boost", "hx-params", "hx-encoding", "hx-ext", "hx-disinherit", "hx-inherit", "hx-history",
    "hx-history-elt", "hx-preserve", "hx-disable", "hx-validate",
    -- SSE event names, and a WebSocket send flag.
    "sse-swap", "sse-close", "ws-send",
  },
}

return def
