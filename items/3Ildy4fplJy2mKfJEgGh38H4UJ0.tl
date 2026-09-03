return {
  ["block_reason"] = {["3In3TXtn2gq04wZGZS2SyRR7Gcb"] = "batch 1 of 'the remaining fifteen' cannot be built: backup and recover don't fit the registry's init-function shape, so the batch list needs correcting first", ["3InoAi3bSUyDIgESDOlE6CIBbi4"] = "batch 1 (appendvfs base64 base85 completion dbdata) cannot land as specified: dbdata's shell.c marker is under ext/recover/ not ext/misc/, and base64/base85's init declarations are wrapped in #ifndef SQLITE_SHELL_EXTFUNCS, breaking the test's literal substring checks — needs a decision on extending the extraction rule/test"},
  ["blocked_by"] = "3In3TXtn2gq04wZGZS2SyRR7Gcb 3InoAi3bSUyDIgESDOlE6CIBbi4",
  ["builders"] = "builder-h38H_4UJ0-orch9 orchestrate9-h38H_4UJ0",
  ["claim"] = "orchestrate9-h38H_4UJ0",
  ["id"] = "3Ildy4fplJy2mKfJEgGh38H4UJ0",
  ["parent"] = "3HyRdY4sPAYZ6xkwrXCh5BnsH7B",
  ["pr"] = 370,
  ["repo"] = "cosmic-lua/cosmopolitan",
  ["reviewer"] = "review-h38H_4UJ0-orch9",
  ["speccers"] = "c3166793-5886-5fa0-8f44-66f7df2ae6f2",
  ["title"] = "sqlite extension registry: extract the remaining fifteen ext/misc units in three batches",
}
