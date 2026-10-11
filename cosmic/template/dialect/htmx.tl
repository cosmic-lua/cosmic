--- The `htmx` dialect (`{{use htmx}}`): what a slot in an attribute of htmx,
--- or of its SSE, WebSocket and response-targets extensions, may be. The
--- table was read against htmx 2.0.11 (dist/htmx.js), htmx-ext-sse 2.2.4,
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
    -- `hx-swap` is refused a slot: it is a spec the author writes (a style,
    -- then modifiers such as `scroll:`, `show:`, `swap:` and `settle:`
    -- split on whitespace, getSwapSpecification). The escaper passes bytes
    -- from 0x80 raw, so a value with U+00A0 or U+2028 in it splits there and
    -- can write a modifier of its own (`scroll:#{{.id}}:top` with an id of
    -- "x scroll"). A selector in `scroll:` or `show:` seldom comes from data;
    -- write the variants as literal text.
    ["hx-swap"] = { class = "refused",
      why = "is the swap spec the author writes: a value with a no-break space or U+2028 in it splits into " ..
        "modifiers of its own; write the variants as literal text" },
    -- Attributes whose value, inherited by a subtree, changes what htmx does
    -- there. Data in them is no code but it is not data either: it can turn
    -- extensions on or off (`ignore:csrf-ext`), htmx itself off (`hx-disable`),
    -- links into requests (`hx-boost`) or the parameters sent away
    -- (`hx-params="none"`). Their values are the author's text.
    ["hx-ext"] = { class = "refused",
      why = "is the author's text: a value can enable an extension or, with 'ignore:', disable one for the subtree" },
    ["hx-disable"] = { class = "refused",
      why = "is the author's text: it turns htmx off for the subtree" },
    ["hx-boost"] = { class = "refused",
      why = "is the author's text: it turns the links and forms of the subtree into requests" },
    ["hx-params"] = { class = "refused",
      why = "is the author's text: it chooses which parameters a request sends" },
    -- `true`, a swap style, or `style:selector` (oobSwap).
    ["hx-swap-oob"] = SELECTOR,

    -- `hx-trigger` stays refused, as the always-on dialect has it: a
    -- trigger's `[filter]` is a JavaScript expression (maybeGenerateConditional),
    -- and `from:` takes a selector.

    -- `hx-ws`, the legacy WebSocket form, is refused by the always-on
    -- dialect (dialect/html.tl).
  },
  prefixes = {
    -- htmx-ext-response-targets: `hx-target-422`, `hx-target-error`, `hx-target-*`.
    { prefix = "hx-target-", rule = SELECTOR },
  },
  families = { "hx-", "sse-", "ws-" },
  plain = {
    -- A dialog's text (window.confirm and window.prompt): no markup, no code.
    "hx-confirm", "hx-prompt",
    -- Behavior, not execution: an encoding; attribute names; `false`; flags.
    "hx-encoding", "hx-disinherit", "hx-inherit", "hx-history", "hx-history-elt", "hx-preserve", "hx-validate",
    -- A marker htmx sets on an element it has revealed; a page does not write it.
    "hx-revealed",
    -- SSE event names, and a WebSocket send flag.
    "sse-swap", "sse-close", "ws-send",
  },
}

return def
