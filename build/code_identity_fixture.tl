--- What the tests of [`build.code_identity`] share: that the stamps of the walks of the code a worker reads are carried
--- to it and are what the code it carries works out.

local Stamp = require("build.stamp")
local Store = require("cosmic.store")
local code_identity = require("build.code_identity")
local importer = require("build.importer")
-- Required for the closure: working an identity out lexes each module, which a stamped run never does.
local _ = require("build.code_text")
-- Declares what text this module reads ([`build.code_walk`]'s `markers`): the sources of the checker's walk and the
-- analyzer's.
local _ = require("build.reads.pipeline")
local _ = require("build.reads.analyzer")

local record code_identity_fixture
  --- Raises unless the running binary carries `stamp_coded` and `stamp_analyzer`, each what the code it carries works
  --- out ([`code_identity.code_of`], [`importer.analyzer_identity`]).
  stamps_hold: function()
end

local function source(name: string): string?, string
  local text, _ = Store.source(name)
  return text, ""
end

local function requires(name: string): {string}
  local required, _ = Store.requires(name)
  return required or {}
end

function code_identity_fixture.stamps_hold()
  local coded = Stamp.read("stamp_coded")
  assert(coded ~= nil, "the running binary carries no stamp of the code that reads and checks")
  local worked = code_identity.code_of(function(name: string): string?
    local text, _ = source(name)
    return text
  end, requires)
  assert(worked == coded, "the stamp " .. coded .. " is not what the carried code works out, " .. worked)
  local analyzer = Stamp.read("stamp_analyzer")
  assert(analyzer ~= nil, "the running binary carries no stamp of the analyzer")
  local named = importer.analyzer_identity({
    basis = Store.meta("runtime_basis") or "",
    requires = function(name: string): {string}?, string return requires(name), "" end,
    source = source,
  })
  assert(named == analyzer, "the stamp " .. analyzer .. " is not what the carried analyzer works out, " .. named)
end

return code_identity_fixture
