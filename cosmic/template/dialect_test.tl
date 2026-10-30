local dialect = require("cosmic.template.dialect")
local types = require("cosmic.template.types")

local type Def = types.Def

--- The class of every attribute the htmx dialect has looked at, against
--- htmx 2.0.11 (dist/htmx.js, and the SSE, WebSocket and response-targets
--- extensions): "plain" for one that needs no rule. It is a second statement
--- of the table in dialect/htmx.tl, so that a change to the table is a change
--- here too.
local HTMX <const>: {string: string} = {
  ["hx-get"] = "url_local", ["hx-post"] = "url_local", ["hx-put"] = "url_local", ["hx-patch"] = "url_local",
  ["hx-delete"] = "url_local", ["hx-push-url"] = "url_local", ["hx-replace-url"] = "url_local",
  ["sse-connect"] = "url_local", ["ws-connect"] = "url_local",
  ["hx-vals"] = "json", ["hx-headers"] = "json", ["hx-request"] = "json",
  ["hx-target"] = "selector", ["hx-select"] = "selector", ["hx-select-oob"] = "selector",
  ["hx-include"] = "selector", ["hx-indicator"] = "selector", ["hx-disabled-elt"] = "selector",
  ["hx-sync"] = "selector", ["hx-swap-oob"] = "selector",
  ["hx-swap"] = "refused", ["hx-ext"] = "refused", ["hx-disable"] = "refused", ["hx-boost"] = "refused",
  ["hx-params"] = "refused",
  ["hx-target-422"] = "selector", ["hx-target-error"] = "selector", ["hx-target-*"] = "selector",
  ["hx-trigger"] = "refused", ["hx-vars"] = "refused", ["hx-ws"] = "refused",
  ["hx-on"] = "refused", ["hx-on:click"] = "refused", ["hx-on::after-request"] = "refused",
  ["hx-on--after-request"] = "refused", ["hx-on-click"] = "refused",
  ["hx-confirm"] = "plain", ["hx-prompt"] = "plain",
  ["hx-encoding"] = "plain", ["hx-disinherit"] = "plain", ["hx-inherit"] = "plain",
  ["hx-history"] = "plain", ["hx-history-elt"] = "plain", ["hx-preserve"] = "plain",
  ["hx-validate"] = "plain", ["hx-revealed"] = "plain", ["sse-swap"] = "plain", ["sse-close"] = "plain", ["ws-send"] = "plain",
}

local function htmx_table(): dialect.Table
  return (assert(dialect.resolve({ "htmx" }, dialect.registry)))
end

local function class_of(table_: dialect.Table, attr: string): string
  local rule = table_:classify(attr)
  return rule ~= nil and rule.class or "plain"
end

local function test_the_htmx_table_is_what_is_pinned_here()
  local table_ = htmx_table()
  for attr, want in pairs(HTMX) do
    assert(class_of(table_, attr) == want, attr .. " is " .. class_of(table_, attr) .. ", not " .. want)
    assert(class_of(table_, "data-" .. attr) == want, "data-" .. attr)
    -- `classify` takes the lower-case name the tokenizer gives it; the
    -- upper-case spellings of a page are compiled in template_test.
  end
  local def = dialect.registry.htmx
  assert(def.targets == "2.0.11", def.targets)
  -- Nothing in the table or its plain list is missing from the pin.
  for attr in pairs(def.exact) do
    assert(HTMX[attr] ~= nil, attr .. " is in the table but not pinned")
  end
  for _, attr in ipairs(def.plain) do
    assert(HTMX[attr] == "plain", attr .. " is plain but not pinned so")
  end
  for _, entry in ipairs(def.prefixes) do
    assert(HTMX[entry.prefix .. "*"] ~= nil or HTMX[entry.prefix] ~= nil, entry.prefix .. " is not pinned")
  end
  for _, family in ipairs(def.families) do
    assert(family:find("^%a+%-$"), family)
  end
end

local function test_an_attribute_no_dialect_names_is_plain()
  local table_ = htmx_table()
  for _, attr in ipairs({ "class", "href", "hx-nothing", "hx-gets", "xhx-get", "data-hx", "data-data-hx-get", "hxget",
      "data-x-link", "hx-targets", "x-on:click", "@click", "sse-x", "hx-vals2", "hx-getx" }) do
    -- A longer name that begins as an exact rule's does not take it.
    assert(class_of(table_, attr) == "plain", attr .. ": " .. class_of(table_, attr))
  end
end

local function test_without_use_only_the_always_on_refusals_are_there()
  local bare = assert(dialect.resolve({}, dialect.registry))
  for _, attr in ipairs({ "hx-vars", "hx-vals", "hx-headers", "hx-request", "hx-trigger", "hx-on:click", "hx-on",
      "data-hx-on--x", "data-hx-vals" }) do
    assert(class_of(bare, attr) == "refused", attr)
  end
  for attr, want in pairs(HTMX) do
    if want ~= "refused" and attr ~= "hx-vals" and attr ~= "hx-headers" and attr ~= "hx-request" then
      assert(class_of(bare, attr) == "plain", attr)
    end
  end
  local rule = assert(bare:classify("hx-vals"))
  assert(rule.why:find("{{use htmx}}", 1, true), rule.why)
  assert(assert(bare:classify("hx-trigger")).why:find("trigger", 1, true))
  -- `use htmx` takes the JSON attributes out of the refusals and no other.
  local used = htmx_table()
  assert(class_of(used, "hx-vals") == "json" and class_of(used, "hx-trigger") == "refused" and
      class_of(used, "hx-vars") == "refused" and class_of(used, "hx-on:x") == "refused")
end

local function test_the_longest_prefix_wins_and_an_exact_name_beats_a_prefix()
  local def: Def = {
    name = "x", targets = "1", plain = {}, families = { "x-" },
    exact = { ["x-on-special"] = { class = "json", why = "" } },
    prefixes = {
      { prefix = "x-on", rule = { class = "refused", why = "short" } },
      { prefix = "x-on-ok", rule = { class = "selector", why = "long" } },
    },
  }
  local table_ = assert(dialect.resolve({ "x" }, { x = def }))
  assert(class_of(table_, "x-on-click") == "refused")
  assert(class_of(table_, "x-on-okay") == "selector")
  assert(class_of(table_, "data-x-on-okay") == "selector")
  assert(class_of(table_, "x-on-special") == "json")
  assert(class_of(table_, "data-x-on-special") == "json")
  -- Not a family of any dialect: no `data-` form.
  assert(class_of(table_, "data-y-on-click") == "plain")
end

local function test_a_name_is_checked_and_two_dialects_must_agree_on_an_attribute()
  local table_, why = dialect.resolve({ "nope" }, dialect.registry)
  assert(table_ == nil and why == "unknown dialect 'nope'", tostring(why))
  local function def(name: string, class: types.Class): Def
    return { name = name, targets = "1", plain = {}, families = {}, prefixes = {}, exact = { ["z-a"] = { class = class, why = "" } } }
  end
  local registry: {string: Def} = { one = def("one", "json"), two = def("two", "selector"), same = def("same", "json") }
  local clash, clash_why = dialect.resolve({ "one", "two" }, registry)
  assert(clash == nil and clash_why:find("dialects 'one' and 'two' give 'z-a' different rules", 1, true) ~= nil, tostring(clash_why))
  assert(dialect.resolve({ "one", "same" }, registry) ~= nil)
  -- The always-on dialect is the one a named dialect may override.
  assert(class_of(assert(dialect.resolve({ "htmx" }, dialect.registry)), "hx-headers") == "json")
end

local function lock_def(exact: {string: types.Rule}, prefixes: {types.Prefix}): Def
  return { name = "mine", targets = "1", plain = {}, families = { "hx-" }, exact = exact, prefixes = prefixes }
end

local function test_no_dialect_takes_off_a_refusal_that_is_always_on()
  local classes: {types.Class} = { "url", "url_local", "selector", "json" }
  for _, attr in ipairs({ "hx-vars", "hx-trigger", "hx-on", "hx-on:click", "hx-on-click", "hx-onx", "data-hx-on:click",
      "data-hx-trigger" }) do
    for _, class in ipairs(classes) do
      local table_, why = dialect.resolve({ "mine" }, { mine = lock_def({ [attr] = { class = class, why = "" } }, {}) })
      assert(table_ == nil and why:find("no dialect may change", 1, true) ~= nil and
          why:find("'" .. attr .. "'", 1, true) ~= nil,
        attr .. " " .. class .. ": " .. tostring(why))
    end
  end
  for _, prefix in ipairs({ "hx-on", "hx-on:", "hx-on-click", "hx-onx" }) do
    local table_, why = dialect.resolve({ "mine" }, { mine = lock_def({}, { { prefix = prefix, rule = { class = "url", why = "" } } }) })
    assert(table_ == nil and why:find("the prefix '" .. prefix .. "'", 1, true) ~= nil, prefix .. ": " .. tostring(why))
  end
  -- A shorter prefix is beaten by the longer, and a refusal stays one.
  local ok = assert(dialect.resolve({ "mine" }, { mine = lock_def({ ["hx-vars"] = { class = "refused", why = "x" } },
    { { prefix = "hx-", rule = { class = "url", why = "" } } }) }))
  assert(class_of(ok, "hx-on:click") == "refused" and class_of(ok, "hx-trigger") == "refused" and
      class_of(ok, "hx-vars") == "refused")
end

local function test_a_dialect_may_give_the_json_attributes_the_json_class_and_no_other()
  for _, attr in ipairs({ "hx-vals", "hx-headers", "hx-request", "data-hx-vals" }) do
    local table_ = assert(dialect.resolve({ "mine" }, { mine = lock_def({ [attr] = { class = "json", why = "" } }, {}) }))
    -- A `data-` name in a table is never looked up: the form is stripped first.
    assert(attr:find("^data%-") ~= nil or class_of(table_, attr) == "json", attr)
    local other, why = dialect.resolve({ "mine" }, { mine = lock_def({ [attr] = { class = "selector", why = "" } }, {}) })
    assert(other == nil and why:find("no dialect may change", 1, true) ~= nil, attr .. ": " .. tostring(why))
  end
  local other, why = dialect.resolve({ "mine" }, { mine = lock_def({}, { { prefix = "hx-vals", rule = { class = "json", why = "" } } }) })
  assert(other ~= nil, tostring(why))
end
