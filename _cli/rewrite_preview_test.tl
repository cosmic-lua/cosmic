#!/usr/bin/env cosmic
-- Preview's contract: one shared plan with apply, JSON evidence, no writes,
-- and errors that preserve already-applied earlier files.
local check = require("cosmic.check")
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local json = require("cosmic.json")
local rewrite_mod = require("_cli.rewrite")

local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local record Run
  code: integer
  out: string
  err: string
end

local record Snapshot
  path: string
  bytes: string
  secs: integer
  nsecs: integer
end

local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "rewrite-preview-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  for rel, contents in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.make_dirs(fs.dirname(path)))
    assert(fs.write(path, contents))
  end
  return root
end

local function run(root: string, argv: {string}): Run
  local full: {string} = {cosmic}
  for _, value in ipairs(argv) do full[#full + 1] = value end
  local handle = check.must(child.start(full, {cwd = root}))
  local result = check.must(handle:wait())
  return {code = result.code or 128, out = result.stdout or "",
    err = result.stderr or ""}
end

local function preview(root: string, replacement: string, paths: {string}): Run
  local argv: {string} = {"--rewrite", "os.execute($CMD)", replacement,
    "--preview"}
  for _, path in ipairs(paths) do argv[#argv + 1] = path end
  return run(root, argv)
end

--- Snapshot source bytes and the filesystem's actual whole-second timestamp.
--- Do not assume a filesystem accepts an arbitrary nanosecond value.
local function snapshots(root: string, files: {string}): {Snapshot}
  local result: {Snapshot} = {}
  for i, rel in ipairs(files) do
    local path = fs.join(root, rel)
    assert(fs.set_times(path, {mtime = {secs = 1000000 + i}}))
    local stamp = check.must(fs.stat(path)):modify_time()
    result[#result + 1] = {path = path, bytes = check.must(fs.read(path)),
      secs = stamp.secs, nsecs = stamp.nsecs}
  end
  return result
end

local function assert_snapshots(before: {Snapshot})
  for _, snapshot in ipairs(before) do
    check.equal(check.must(fs.read(snapshot.path)), snapshot.bytes)
    local stamp = check.must(fs.stat(snapshot.path)):modify_time()
    assert(stamp.secs == snapshot.secs and stamp.nsecs == snapshot.nsecs,
      "preview changed mtime for " .. snapshot.path)
  end
end

local function output_rows(out: string): {{string: any}}, string
  local rows: {{string: any}} = {}
  local summary = ""
  for line in out:gmatch("([^\n]+)") do
    if line:sub(1, 1) == "{" then
      local row = check.must(json.decode(line))
      assert(row is {string: any})
      rows[#rows + 1] = row
    else
      summary = line
    end
  end
  return rows, summary
end

local function test_preview_reports_apply_bytes_without_writing()
  local root = fixture("bytes", {
      ["a.tl"] = "os.execute(a)\n", ["b.tl"] = "os.execute(b)\n",
    })
  local a, b = fs.join(root, "a.tl"), fs.join(root, "b.tl")
  local before = snapshots(root, {"a.tl", "b.tl"})
  local preview_run = preview(root, "assert(os.execute($CMD))", {"a.tl", "b.tl"})
  assert(preview_run.code == 0, preview_run.out .. preview_run.err)
  local rows, summary = output_rows(preview_run.out)
  local first_object, second_object = rows[1], rows[2]
  assert(#rows == 2 and first_object.kind == "rewrite-plan")
  assert(second_object.kind == "rewrite-plan")
  check.equal(first_object.path, "a.tl")
  check.equal(second_object.path, "b.tl")
  check.equal(first_object.matches, 1)
  check.equal(second_object.matches, 1)
  check.equal(first_object.changed, true)
  check.equal(second_object.changed, true)
  check.equal(summary, "rewrite: preview: 2 match(es), 2 proposed, 0 refused, 0 failed in 2 file(s)")
  local first_code, second_code = first_object.code, second_object.code
  assert(first_code is string and second_code is string)
  assert_snapshots(before)

  local apply_run = run(root, {"--rewrite", "os.execute($CMD)",
      "assert(os.execute($CMD))", "--apply", "a.tl", "b.tl"})
  assert(apply_run.code == 0, apply_run.out .. apply_run.err)
  check.equal(check.must(fs.read(a)), first_code)
  check.equal(check.must(fs.read(b)), second_code)
end

local function test_preview_retains_partial_refusals_and_original_positions()
  local root = fixture("refusal", {
      ["a.tl"] = "os.execute(a)\nos.execute(b --[[ keep ]] )\n",
    })
  local before = snapshots(root, {"a.tl"})
  local result = preview(root, "assert(os.execute($CMD))", {"a.tl"})
  assert(result.code == 1, result.out .. result.err)
  local rows, summary = output_rows(result.out)
  local row = rows[1]
  assert(#rows == 1 and row.kind == "rewrite-plan")
  check.equal(row.path, "a.tl")
  check.equal(row.matches, 2)
  check.equal(row.changed, true)
  check.equal(summary, "rewrite: preview: 2 match(es), 1 proposed, 1 refused, 0 failed in 1 file(s)")
  local proposed, refused = row.proposed, row.refused
  assert(proposed is {any} and refused is {any})
  local proposed_site, refused_site = proposed[1], refused[1]
  assert(proposed_site is {string: any} and refused_site is {string: any})
  assert(#proposed == 1 and proposed_site.line == 1 and proposed_site.column == 1)
  assert(#refused == 1 and refused_site.line == 2 and refused_site.column == 1
    and refused_site.comments == 1)
  assert(result.err:find("would drop 1 comment", 1, true))
  assert_snapshots(before)
end

local function test_preview_later_failure_does_not_write_earlier_file()
  local root = fixture("later", {
      ["a.tl"] = "os.execute(a)\n", ["z.tl"] = "local = bad\n",
    })
  local a = fs.join(root, "a.tl")
  local before = snapshots(root, {"a.tl", "z.tl"})
  local result = preview(root, "assert(os.execute($CMD))", {"a.tl", "z.tl"})
  assert(result.code == 2, result.out .. result.err)
  local rows, summary = output_rows(result.out)
  assert(#rows == 2 and rows[1].kind == "rewrite-plan")
  check.equal(rows[1].path, "a.tl")
  check.equal(rows[1].matches, 1)
  check.equal(rows[1].changed, true)
  check.equal(rows[2].kind, "rewrite-error")
  check.equal(rows[2].path, "z.tl")
  check.equal(rows[2].matches, 0)
  assert(rows[2].code == nil and rows[2].proposed == nil and rows[2].refused == nil)
  local message = rows[2].message
  assert(message is string and message:find("z.tl", 1, true))
  check.equal(summary, "rewrite: preview: 1 match(es), 1 proposed, 0 refused, 1 failed in 2 file(s)")
  assert_snapshots(before)

  local apply = run(root, {"--rewrite", "os.execute($CMD)",
      "assert(os.execute($CMD))", "--apply", "a.tl", "z.tl"})
  assert(apply.code == 2, apply.out .. apply.err)
  assert(check.must(fs.read(a)):find("assert(os.execute(a))", 1, true))
end

local function test_preview_refuses_invalid_templates_and_command_conflicts()
  local root = fixture("invalid", {["a.tl"] = "os.execute(a)\n"})
  local before = snapshots(root, {"a.tl"})
  local bad_template = preview(root, "(", {"a.tl"})
  assert(bad_template.code == 2 and bad_template.out:find("replacement:", 1, true))
  local conflict = run(root, {"--rewrite", "os.execute($CMD)",
      "assert(os.execute($CMD))", "--preview", "--fix", "a.tl"})
  assert(conflict.code == 2 and conflict.err:find("another command", 1, true))
  assert_snapshots(before)
end

local function test_preview_uses_no_writer_and_apply_reports_a_write_failure()
  local root = fixture("writer", {
      ["a.tl"] = "os.execute(a)\n", ["b.tl"] = "os.execute(b)\n",
    })
  local cwd = check.must(fs.cwd())
  local before = snapshots(root, {"a.tl", "b.tl"})
  assert(fs.set_cwd(root))
  local original_write = fs.write
  local called = false
  local ok, err = xpcall(function()
      fs.write = function(_path: string, _text: string): boolean, string
        called = true
        return false, "preview writer must not run"
      end
      local preview_code = rewrite_mod.run("os.execute($CMD)",
        {"assert(os.execute($CMD))", "a.tl", "b.tl"}, false, true)
      assert(preview_code == 0 and not called, "preview called the writer")
      assert_snapshots(before)

      fs.write = function(path: string, text: string): boolean, string
        if path == "a.tl" then return false, "controlled write failure" end
        return original_write(path, text)
      end
      local apply_code = rewrite_mod.run("os.execute($CMD)",
        {"assert(os.execute($CMD))", "a.tl", "b.tl"}, true)
      assert(apply_code == 2, "write failure must have highest precedence")
      assert(check.must(fs.read("a.tl")) == "os.execute(a)\n")
      assert(check.must(fs.read("b.tl")):find("assert(os.execute(b))", 1, true))
    end, debug.traceback)
  fs.write = original_write
  assert(fs.set_cwd(cwd))
  assert(ok, err)
end

local function test_read_failure_continues_to_a_later_file()
  local root = fixture("reader", {
      ["a.tl"] = "os.execute(a)\n", ["b.tl"] = "os.execute(b)\n",
    })
  local cwd = check.must(fs.cwd())
  assert(fs.set_cwd(root))
  local original_read = fs.read
  local ok, err = xpcall(function()
      fs.read = function(path: string): string | nil, string
        if path == "a.tl" then return nil, "controlled read failure" end
        return original_read(path)
      end
      local code = rewrite_mod.run("os.execute($CMD)",
        {"assert(os.execute($CMD))", "a.tl", "b.tl"}, true)
      assert(code == 2, "read failure must have highest precedence")
      assert(check.must(fs.read("b.tl")):find("assert(os.execute(b))", 1, true))
    end, debug.traceback)
  fs.read = original_read
  assert(fs.set_cwd(cwd))
  assert(ok, err)
end

local function test_preview_dot_uses_shared_checkable_selection()
  local root = fixture("selection", {
      ["a.tl"] = "os.execute(a)\n",
      ["s.tl"] = "local s = [[os.execute(s)]]\n",
      ["o/x.tl"] = "os.execute(o)\n",
      ["testdata/x.tl"] = "os.execute(testdata)\n",
      ["a.lua"] = "os.execute(lua)\n",
    })
  local before = snapshots(root, {"a.tl", "s.tl", "o/x.tl", "testdata/x.tl", "a.lua"})
  local result = preview(root, "assert(os.execute($CMD))", {"."})
  assert(result.code == 0, result.out .. result.err)
  assert(result.out:find('"path":"a.tl"', 1, true))
  assert(result.out:find('"path":"s.tl"', 1, true))
  assert(not result.out:find("o/x.tl", 1, true))
  assert(not result.out:find("testdata/x.tl", 1, true))
  assert(not result.out:find("a.lua", 1, true))
  assert_snapshots(before)
end

local function test_later_substitution_failure_keeps_preview_nonwriting_and_apply_partial()
  local root = fixture("substitution", {
      ["a.tl"] = "os.execute(f())\n", ["z.tl"] = "os.execute(cmd)\n",
    })
  local a, z = fs.join(root, "a.tl"), fs.join(root, "z.tl")
  local before = snapshots(root, {"a.tl", "z.tl"})
  local before_a, before_z = check.must(fs.read(a)), check.must(fs.read(z))
  local preview_run = preview(root, "$CMD", {"a.tl", "z.tl"})
  assert(preview_run.code == 2, preview_run.out .. preview_run.err)
  local rows, summary = output_rows(preview_run.out)
  assert(#rows == 2 and rows[1].kind == "rewrite-plan")
  check.equal(rows[1].path, "a.tl")
  check.equal(rows[1].matches, 1)
  check.equal(rows[2].kind, "rewrite-error")
  check.equal(rows[2].path, "z.tl")
  check.equal(rows[2].matches, 1)
  local error_message = rows[2].message
  assert(error_message is string)
  check.equal(summary, "rewrite: preview: 2 match(es), 1 proposed, 0 refused, 1 failed in 2 file(s)")
  check.equal(check.must(fs.read(a)), before_a)
  check.equal(check.must(fs.read(z)), before_z)
  assert_snapshots(before)
  local apply = run(root, {"--rewrite", "os.execute($CMD)", "$CMD", "--apply",
      "a.tl", "z.tl"})
  assert(apply.code == 2, apply.out .. apply.err)
  check.equal(check.must(fs.read(a)), "f()\n")
  check.equal(check.must(fs.read(z)), before_z)
end

local function test_preview_conflicts_preempt_every_writer_and_help_remains_available()
  local root = fixture("conflicts", {["a.tl"] = "os.execute(a)\n"})
  local before = check.must(fs.read(fs.join(root, "a.tl")))
  local source = snapshots(root, {"a.tl"})
  local commands: {{string}} = {
    {"--fix", "a.tl"}, {"--format", "a.tl"}, {"--compile", "a.tl"},
    {"--embed", "a.tl"}, {"--extract", "out"}, {"--make", "help"},
    {"--recipe", "build"}, {"--execute", "print(1)"},
    {"--find", "os.execute($CMD)"}, {"--check", "fmt"},
  }
  for _, command in ipairs(commands) do
    local argv: {string} = {"--rewrite", "os.execute($CMD)",
      "assert(os.execute($CMD))", "--preview", "a.tl"}
    for _, value in ipairs(command) do argv[#argv + 1] = value end
    local result = run(root, argv)
    assert(result.code == 2, "preview command conflict escaped: " .. command[1])
    check.equal(check.must(fs.read(fs.join(root, "a.tl"))), before)
    assert_snapshots(source)
  end
  local help = run(root, {"--rewrite", "os.execute($CMD)",
      "assert(os.execute($CMD))", "--preview", "a.tl", "--help"})
  assert(help.code == 0 and help.out:find("--preview", 1, true))
  assert_snapshots(source)
end

local function test_preview_requires_rewrite_and_accepts_an_empty_replacement()
  local root = fixture("empty", {["a.tl"] = "os.execute(a)\n"})
  local before = snapshots(root, {"a.tl"})
  local absent = run(root, {"--preview", "a.tl"})
  assert(absent.code == 2 and absent.err:find("requires --rewrite", 1, true))
  local result = preview(root, "", {"a.tl"})
  assert(result.code == 0, result.out .. result.err)
  assert(result.out:find('"code":""', 1, true))
  assert_snapshots(before)
end

local function test_preview_exact_zero_hit_identity_and_all_refused_records()
  local root = fixture("record-kinds", {
      ["zero.tl"] = "local x=1\n",
      ["identity.tl"] = "os.execute(a)\n",
      ["refused.tl"] = "os.execute(a --[[ keep ]] )\n",
    })
  local before = snapshots(root, {"zero.tl", "identity.tl", "refused.tl"})

  local zero = preview(root, "assert(os.execute($CMD))", {"zero.tl"})
  assert(zero.code == 1, zero.out .. zero.err)
  local zero_rows, zero_summary = output_rows(zero.out)
  local zero_row = zero_rows[1]
  assert(#zero_rows == 1 and zero_row.kind == "rewrite-plan")
  check.equal(zero_row.path, "zero.tl")
  check.equal(zero_row.matches, 0)
  check.equal(zero_row.changed, true)
  check.equal(zero_row.code, "local x = 1\n")
  local zero_proposed, zero_refused = zero_row.proposed, zero_row.refused
  assert(zero_proposed is {any} and zero_refused is {any})
  check.equal(#zero_proposed, 0)
  check.equal(#zero_refused, 0)
  check.equal(zero_summary, "rewrite: preview: 0 match(es), 0 proposed, 0 refused, 0 failed in 1 file(s)")

  local identity = preview(root, "os.execute($CMD)", {"identity.tl"})
  assert(identity.code == 0, identity.out .. identity.err)
  local identity_rows, identity_summary = output_rows(identity.out)
  local identity_row = identity_rows[1]
  assert(#identity_rows == 1 and identity_row.kind == "rewrite-plan")
  check.equal(identity_row.path, "identity.tl")
  check.equal(identity_row.matches, 1)
  check.equal(identity_row.changed, false)
  check.equal(identity_row.code, "os.execute(a)\n")
  local identity_proposed, identity_refused = identity_row.proposed, identity_row.refused
  assert(identity_proposed is {any} and identity_refused is {any})
  check.equal(#identity_proposed, 1)
  check.equal(#identity_refused, 0)
  check.equal(identity_summary, "rewrite: preview: 1 match(es), 1 proposed, 0 refused, 0 failed in 1 file(s)")

  local refused = preview(root, "assert(os.execute($CMD))", {"refused.tl"})
  assert(refused.code == 1, refused.out .. refused.err)
  local refused_rows, refused_summary = output_rows(refused.out)
  local refused_row = refused_rows[1]
  assert(#refused_rows == 1 and refused_row.kind == "rewrite-plan")
  check.equal(refused_row.path, "refused.tl")
  check.equal(refused_row.matches, 1)
  local refused_proposed, refused_refused = refused_row.proposed, refused_row.refused
  assert(refused_proposed is {any} and refused_refused is {any})
  check.equal(#refused_proposed, 0)
  check.equal(#refused_refused, 1)
  check.equal(refused_row.changed, false)
  check.equal(refused_row.code, "os.execute(a --[[ keep ]] )\n")
  check.equal(refused_summary, "rewrite: preview: 1 match(es), 0 proposed, 1 refused, 0 failed in 1 file(s)")
  assert_snapshots(before)
end

local function test_preview_validates_forms_operands_modes_and_excluded_selection()
  local root = fixture("validation", {
      ["zero.tl"] = "local x=1\n", ["o/x.tl"] = "os.execute(o)\n",
    })
  local before = snapshots(root, {"zero.tl", "o/x.tl"})
  local forms = {"assert(os.execute($CMD))", "$CMD", "", " "}
  for _, replacement in ipairs(forms) do
    local result = preview(root, replacement, {"zero.tl"})
    assert(result.code == 1, "valid template refused: " .. replacement)
    assert_snapshots(before)
  end
  local invalid = preview(root, "(", {"zero.tl"})
  assert(invalid.code == 2 and invalid.out:find("replacement:", 1, true))
  local missing_replacement = run(root, {"--rewrite", "os.execute($CMD)", "--preview"})
  assert(missing_replacement.code == 2)
  local missing_path = run(root, {"--rewrite", "os.execute($CMD)",
      "assert(os.execute($CMD))", "--preview"})
  assert(missing_path.code == 2)
  local both = run(root, {"--rewrite", "os.execute($CMD)",
      "assert(os.execute($CMD))", "--preview", "--apply", "zero.tl"})
  assert(both.code == 2 and both.err:find("cannot be combined", 1, true))
  local excluded = preview(root, "assert(os.execute($CMD))", {"o/x.tl"})
  assert(excluded.code == 2 and excluded.out:find("refused:", 1, true))
  assert_snapshots(before)
end

local function test_preview_accepts_option_like_comments_and_multiple_statements()
  local root = fixture("template-forms", {
      ["zero.tl"] = "local x=1\n", ["multi.tl"] = "os.execute(a)\n",
    })
  local before = snapshots(root, {"zero.tl", "multi.tl"})
  local comment = run(root, {"--rewrite", "os.execute($CMD)", "--preview", "--",
      "-- delete", "zero.tl"})
  assert(comment.code == 1, comment.out .. comment.err)
  local comment_rows, comment_summary = output_rows(comment.out)
  local comment_row = comment_rows[1]
  assert(#comment_rows == 1 and comment_row.kind == "rewrite-plan")
  check.equal(comment_row.path, "zero.tl")
  check.equal(comment_row.matches, 0)
  check.equal(comment_row.changed, true)
  check.equal(comment_row.code, "local x = 1\n")
  check.equal(comment_summary, "rewrite: preview: 0 match(es), 0 proposed, 0 refused, 0 failed in 1 file(s)")

  local multi = preview(root, "local x=1; assert(os.execute($CMD))", {"multi.tl"})
  assert(multi.code == 0, multi.out .. multi.err)
  local multi_rows, multi_summary = output_rows(multi.out)
  local multi_row = multi_rows[1]
  assert(#multi_rows == 1 and multi_row.kind == "rewrite-plan")
  check.equal(multi_row.matches, 1)
  check.equal(multi_row.code, "local x = 1; assert(os.execute(a))\n")
  check.equal(multi_summary, "rewrite: preview: 1 match(es), 1 proposed, 0 refused, 0 failed in 1 file(s)")
  assert_snapshots(before)
end

local function test_preview_sorts_complete_multi_refusals()
  local root = fixture("multi-refusal", {
      ["a.tl"] = "os.execute(a --[[ first ]] )\nos.execute(b --[[ second ]] )\n",
    })
  local before = snapshots(root, {"a.tl"})
  local result = preview(root, "assert(os.execute($CMD))", {"a.tl"})
  assert(result.code == 1, result.out .. result.err)
  local rows, summary = output_rows(result.out)
  local row = rows[1]
  assert(#rows == 1 and row.kind == "rewrite-plan")
  local refused = row.refused
  assert(refused is {any} and #refused == 2)
  local first, second = refused[1], refused[2]
  assert(first is {string: any} and second is {string: any})
  assert(first.line == 1 and first.column == 1 and first.comments == 1)
  assert(second.line == 2 and second.column == 1 and second.comments == 1)
  check.equal(summary, "rewrite: preview: 2 match(es), 0 proposed, 2 refused, 0 failed in 1 file(s)")
  assert_snapshots(before)
end

local function test_preview_report_write_and_flush_failures_are_exit_two()
  local root = fixture("report-io", {["a.tl"] = "os.execute(a)\n"})
  local before = snapshots(root, {"a.tl"})
  local cwd = check.must(fs.cwd())
  assert(fs.set_cwd(root))
  local function failed_report(write_at: integer, flush_at: integer): integer
    local writes, flushes = 0, 0
    local previous = rewrite_mod.set_report_io({
        write = function(_text: string): boolean, string
          writes = writes + 1
          if writes == write_at then return false, "controlled write failure" end
          return true, ""
        end,
        flush = function(): boolean, string
          flushes = flushes + 1
          if flushes == flush_at then return false, "controlled flush failure" end
          return true, ""
        end,
      })
    local code = rewrite_mod.run("os.execute($CMD)",
      {"assert(os.execute($CMD))", "a.tl"}, false, true)
    rewrite_mod.set_report_io(previous)
    return code
  end
  local ok, err = xpcall(function()
      assert(failed_report(1, 0) == 2, "record write failure escaped")
      assert(failed_report(2, 0) == 2, "summary write failure escaped")
      assert(failed_report(0, 1) == 2, "record flush failure escaped")
      assert(failed_report(0, 2) == 2, "summary flush failure escaped")
    end, debug.traceback)
  assert(fs.set_cwd(cwd))
  assert(ok, err)
  assert_snapshots(before)
end
