--- The command line of the proof that the seed builds the new checker from its translated source:
--- `bin/cosmic build/lang_proof_main.tl prove <dir> [stem...]`, run from the root of the tree
--- ([`build/lang_proof.tl`]).

local LangProof = require("build.lang_proof")

return function(argv: {string}): integer
  return LangProof.main(argv)
end
