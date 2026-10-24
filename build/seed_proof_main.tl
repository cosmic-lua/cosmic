--- The command line of the proof that the tool can be bootstrapped from the new checker's seed:
--- `bin/cosmic build/seed_proof_main.tl prove <dir> [--seed <cosmic>] [--tool]`, run from the root of the tree
--- ([`build/seed_proof.tl`]).

local SeedProof = require("build.seed_proof")

return function(argv: {string}): integer
  return SeedProof.main(argv)
end
