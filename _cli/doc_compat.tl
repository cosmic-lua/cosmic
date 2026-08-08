--- TRANSITIONAL doc compatibility (#1001; DELETE this module at the
--- pin advance): the pin boot-checks `_cli` against ITS embedded
--- cosmic.doc — DocsResult{ok, output} returns, `has_docs`/`list_*`
--- spellings — while the tree's record returns `string | nil, string`
--- pairs under noun names. These wrappers reach the members through
--- erasure with a runtime fallback to the pin's spellings, and
--- normalize a pin-shaped DocsResult into the pair, so the dispatcher
--- compiles and runs under both generations.
local docs = require("cosmic.doc")

local record DocCompat
  query: function(q?: string): string | nil, string
  module_examples: function(q: string): string | nil, string
  is_available: function(): boolean
  topics: function(include_cosmo?: boolean): {{string, string}}
  guides: function(): {{string, string}}
end

local docs_any = docs as {string: any} -- cast: transitional dual-shape module

--- Wrap a lookup so a pin-shaped DocsResult return reads as the pair.
local function paired(fn: any): function(q?: string): (string | nil, string)
  local call = fn as function(any): (any, any) -- cast: transitional dual-shape call
  return function(q?: string): string | nil, string
    local r, err = call(q)
    if r is string then
      return r
    end
    if r == nil then
      return nil, err as string -- cast: transitional dual-shape result
    end
    local rec = r as {string: any} -- cast: transitional dual-shape result
    if rec["ok"] then
      return rec["output"] as string -- cast: transitional dual-shape result
    end
    return nil, rec["output"] as string -- cast: transitional dual-shape result
  end
end

-- The casts sit in statement position: the pin's parser rejects an
-- anonymous function type after `as` inside a table constructor.
-- cast: transitional dual-shape call
local compat_is_available = (docs_any["is_available"] or docs_any["has_docs"]) as
function(): boolean

-- cast: transitional dual-shape call
local compat_topics = (docs_any["topics"] or docs_any["list_topics"]) as
function(boolean): {{string, string}}

-- cast: transitional dual-shape call
local compat_guides = (docs_any["guides"] or docs_any["list_guides"]) as
function(): {{string, string}}

local M: DocCompat = {
  query = paired(docs_any["query"]),
  module_examples = paired(docs_any["module_examples"]
    or docs_any["show_module_examples"]),
  is_available = compat_is_available,
  topics = compat_topics,
  guides = compat_guides,
}

return M
