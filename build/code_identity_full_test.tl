--- [`build.code_identity`] and [`build.importer`]'s `analyzer_identity` in a worker given the full store of its closure,
--- text and all, which keeps the sources of a walk's modules its closure leaves out as the pure store does
--- ([`build.closure_store`]'s `source_kept`): each walk's stamp is carried and is what the carried code works out.

local Test = require("cosmic.test")
local fixture = require("build.code_identity_fixture")

-- The full store, as a test of the language server or of `cosmic docs` is given.
Test.policy{ store_text = true }

local function test_a_full_store_worker_carries_the_stamps_of_the_code_it_reads()
  fixture.stamps_hold()
end
