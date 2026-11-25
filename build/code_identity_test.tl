--- [`build.code_identity`] and [`build.importer`]'s `analyzer_identity` in a worker given the pure store of its closure:
--- each walk's stamp is carried and is what the carried code works out ([`build.test_key`]'s `sealed_stamps`).

local fixture = require("build.code_identity_fixture")

local function test_a_pure_store_worker_carries_the_stamps_of_the_code_it_reads()
  fixture.stamps_hold()
end
