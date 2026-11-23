--- [`cosmic.store`]'s lookups that read no source text, in the shape the
--- build's own walks take (`function(string): T?, string`, the reason as
--- text): what [`build.code_walk`], [`build.identity`],
--- [`build.importer`] and [`build.check_memo`] are handed in place of the
--- Store functions, which answer a [`cosmic.failure`].
-- TODO: make those walks take the Failure shape, and drop this module.

local Store = require("cosmic.store")

local record store_lookups
end

--- [`Store.requires`], its failure in words.
function store_lookups.requires(name: string): {string}?, string
  local names, why = Store.requires(name)
  if names == nil then return nil, tostring(why) end
  return names, ""
end

--- [`Store.bytecode`], its failure in words.
function store_lookups.bytecode(name: string): string?, string
  local bytes, why = Store.bytecode(name)
  if bytes == nil then return nil, tostring(why) end
  return bytes, ""
end

--- [`Store.holds`], its failure in words.
function store_lookups.holds(name: string): boolean?, string
  local held, why = Store.holds(name)
  if held == nil then return nil, tostring(why) end
  return held, ""
end

return store_lookups
