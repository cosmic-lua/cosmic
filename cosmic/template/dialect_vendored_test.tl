--- Keeps the htmx dialect's attribute table honest against the files the
--- binary carries: every `hx-*` name the vendored htmx reads, and every
--- `sse-*` name its SSE extension reads, is classified by the dialect or
--- listed as needing no rule, and the dialect targets the htmx version
--- [`cosmic.web.htmx`] serves. Bumping the pinned files fails this test
--- until a person has read what changed and classified the new names.

local dialect = require("cosmic.template.dialect")
local Fs = require("cosmic.fs")
local Htmx = require("cosmic.web.htmx")
local Test = require("cosmic.test")

Test.policy{ grants = {
  { path = "vendor/htmx/dist/htmx.min.js", letters = "r" },
  { path = "vendor/htmx-ext-sse/dist/sse.min.js", letters = "r" },
} }

--- The names of `family` that `source` holds as words, once each.
local function names_in(source: string, family: string): {string}
  local seen: mut {string:boolean} = {}
  local names: mut {string} = {}
  for name in source:gmatch("%f[%w-](" .. family .. "[%a-]*)") do
    if not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

--- Whether the dialect says something of `name`, or lists it as needing no rule.
local function classified(table_: dialect.Table, name: string): boolean
  if table_:classify(name) ~= nil then return true end
  for _, plain in ipairs(dialect.registry.htmx.plain) do
    if plain == name then return true end
  end
  return false
end

local function test_every_attribute_the_vendored_htmx_reads_is_classified()
  local source = assert(Fs.read("vendor/htmx/dist/htmx.min.js"))
  local table_ = assert(dialect.resolve({ "htmx" }, dialect.registry))
  local names = names_in(source, "hx%-")
  assert(#names > 20, "the extraction found only " .. #names .. " names")
  for _, name in ipairs(names) do
    -- "hx-" alone is the family's prefix, which htmx concatenates a name to.
    if name ~= "hx-" then
      assert(classified(table_, name), name .. " is read by htmx " .. Htmx.version ..
          " and neither classified nor plain in cosmic/template/dialect/htmx.tl")
    end
  end
end

local function test_every_attribute_the_vendored_sse_extension_reads_is_classified()
  local source = assert(Fs.read("vendor/htmx-ext-sse/dist/sse.min.js"))
  local table_ = assert(dialect.resolve({ "htmx" }, dialect.registry))
  local names = names_in(source, "sse%-")
  assert(#names == 3, table.concat(names, " "))
  for _, name in ipairs(names) do
    assert(classified(table_, name), name .. " is read by htmx-ext-sse " .. Htmx.sse_version ..
        " and neither classified nor plain in cosmic/template/dialect/htmx.tl")
  end
end

local function test_the_dialect_targets_the_version_served()
  assert(dialect.registry.htmx.targets == Htmx.version, dialect.registry.htmx.targets .. " ~= " .. Htmx.version)
end

local function test_the_configuration_keys_htmx_head_writes_are_ones_the_vendored_file_reads()
  local source = assert(Fs.read("vendor/htmx/dist/htmx.min.js"))
  for _, key in ipairs({ "allowEval", "allowScriptTags", "includeIndicatorStyles", "selfRequestsOnly",
      "responseHandling", "inlineScriptNonce", "historyCacheSize" }) do
    assert(source:find(key, 1, true), key)
  end
end
