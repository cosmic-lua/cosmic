--- Whether the build's own pipeline ([`build.pipeline`]) holds each module of the tree as the checks of the tree do,
--- apart from [`build.tree_checks.checked`], so that what the pipeline loads is no part of the code the other checks'
--- memos are salted by ([`check_memo.salt`]).
local PipelineCheck = require("build.pipeline_check")
local Sqlite = require("cosmic.sqlite")
local type work_schema = require("build.work_schema")
local tree_checked = require("build.tree_checks.checked")

local type Database = work_schema.Database

local record tree_pipeline
  --- Whether the pipeline holds each module of the tree at `root` as the checks of the tree do, by the inputs of
  --- `build_db`, and the modules it refuses for more than a count ([`build.pipeline_check`] has the rules). `memo`
  --- keeps the result for a module under the key `checked` keeps its own.
  findings: function(root: string, build_db: Database, memo?: Sqlite.Handle): {string}
end

--- What makes a comparison's result, which salts its memo.
local FILES <const>: {string} = { "lang/ast.tl", "lang/lexer.tl", "lang/parser.tl", "lang/scopes.tl",
  "lang/types.tl", "lang/relation.tl", "lang/declarations.tl", "lang/check/", "lang/flow.tl",
  "lang/check_codes.tl", "lang/warnings.tl", "lang/prelude.d.tl", "lang/stdlib.d.tl",
  "build/check_memo.tl", "build/driver.tl", "build/tree_checks/checked.tl", "build/tree_checks/pipeline.tl", "build/tree_checks/common.tl", "build/tree_program.tl",
  "build/syntax_shape_specs.tl", "build/syntax_record_calls.tl", "build/syntax_protobuf_specs.tl", "build/syntax_record_splices.tl", "build/pipeline.tl", "build/pipeline_check.tl",
  "build/gen_syscalls.tl", "build/compile_grammar.tl", "build/main_locals.tl", "build/lua_tail.tl", "lang/codegen.tl", "lang/truthy.tl", "lang/fact_wraps.tl",
  "lang/boundaries.tl", "lang/boundary_checks.tl",
  "core/syscalls.h", "core/process.h", "core/socket.h" }

function tree_pipeline.findings(root: string, build_db: Database, memo?: Sqlite.Handle): {string}
  local rows, trouble = tree_checked.lowered(root, FILES, "pipeline 6", memo)
  if rows == nil then return { trouble } end
  return PipelineCheck.compare(root, build_db, memo, #rows, function(index: integer): PipelineCheck.Row
    local row = assert(rows[index])
    return { file = row.file, module = row.module, dialect = row.dialect, key = row.key }
  end, tree_checked.declared(root, memo), tree_checked.checked(root, memo))
end

return tree_pipeline
