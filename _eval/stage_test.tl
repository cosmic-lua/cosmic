local fs = require("cosmic.fs")
local json = require("cosmic.json")
local hash = require("cosmic.hash")
local check = require("cosmic.check")
local shape = require("cosmic.shape")
local stage = require("_eval.stage")
local eval_types = require("_eval.eval_types")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- meta.json's shape: eval_types.Meta field for field. cosmic_version
--- is the one optional -- stage.tl leaves it unset when the staged
--- binary's own version could not be resolved.
local META < const > = shape.record({
    timestamp = shape.number,
    suite_version = shape.integer,
    bin = shape.string,
    bin_sha = shape.string,
    cosmic_version = shape.optional(shape.string),
    os = shape.string,
    isa = shape.string,
    model = shape.string,
    agent_tool = shape.string,
    timeout_secs = shape.integer,
  })

--- @param path string A meta.json path, as written by staging
--- @return Meta|nil The validated meta.json at that path
--- @return string The mismatch when the file is not the shape stage.tl
--- writes
local function read_meta(path: string): eval_types.Meta | nil, string
  local body = check.must(fs.read(path))
  return shape.into(check.must(json.decode(body)), META)
end

--- The same file read as a plain table, for the test whose subject is
--- which field NAMES meta.json carries: a {string: any} keeps
--- `meta[field]` legal where `field` is a loop variable, which
--- validating into Meta would not.
--- @param path string A meta.json path, as written by staging
--- @return {string: any}|nil The decoded meta.json at that path
--- @return string The mismatch when the file is not a string-keyed object
local function read_meta_object(path: string): {string: any} | nil, string
  local body = check.must(fs.read(path))
  return shape.into(check.must(json.decode(body)), shape.map(shape.any))
end

local EXPECTED_IDS < const >: {string} = {
  "json-cli",
  "module-tests",
  "sqlite-indexer",
  "child-tcp",
  "text-report",
  "multi-module-build",
  "contained-task",
}

--- A minimal stand-in binary: stage.tl never runs it, only copies and
--- hashes it, so any bytes serve.
--- @return string Path to the fixture binary
local function fixture_bin(): string
  local path = fs.join(tmpdir, "stage-fixture-cosmic")
  check.must(fs.write(path, "not a real cosmic binary, just bytes to stage\n"))
  return path
end

--- Stage the fixture binary into a fresh run directory, once, shared
--- by every test below -- staging is the thing under test, not a
--- per-test setup step to repeat seven times over.
--- @return string The run directory
local function staged_run(): string
  local bin = fixture_bin()
  local out = fs.join(tmpdir,
    "stage-run-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000)))
  local code = stage.main("--bin", bin, "--out", out)
  assert(code == 0, "stage.main should succeed, got exit " .. code)
  return out
end

local run_dir = staged_run()

local function test_workspaces_hold_exactly_two_files()
  for _, id in ipairs(EXPECTED_IDS) do
    local dir = fs.join(run_dir, id)
    local found = check.must(fs.find(dir, {recursive = false, sorted = true}))
    local names: {string} = {}
    for _, p in ipairs(found) do
      names[#names + 1] = fs.basename(p)
    end
    table.sort(names)
    assert(#names == 2, id .. ": expected exactly 2 entries, got " .. #names)
    assert(names[1] == "cosmic" and names[2] == "prompt.txt",
      id .. ": expected cosmic + prompt.txt, got " ..
      table.concat(names, ", "))
    assert(fs.is_accessible(fs.join(dir, "cosmic"), fs.X_OK),
      id .. ": cosmic must be executable")
  end
end
test_workspaces_hold_exactly_two_files()

local function test_frame_embedded_placeholder_gone()
  for _, id in ipairs(EXPECTED_IDS) do
    local prompt = check.must(fs.read(fs.join(run_dir, id, "prompt.txt")))
    assert(not prompt:find("<the brief>", 1, true),
      id .. ": placeholder must be replaced")
    assert(prompt:find("YOUR PROJECT:", 1, true),
      id .. ": frame's YOUR PROJECT line must survive substitution")
    assert(prompt:find("STRICT EVAL RULES:", 1, true),
      id .. ": frame body must survive substitution")
  end
end
test_frame_embedded_placeholder_gone()

local function test_meta_json_has_all_ten_fields()
  local meta = check.must(read_meta_object(fs.join(run_dir, "meta.json")))
  local want < const >: {string} = {
    "timestamp", "suite_version", "bin", "bin_sha", "cosmic_version",
    "os", "isa", "model", "agent_tool", "timeout_secs",
  }
  for _, field in ipairs(want) do
    assert(meta[field] ~= nil, "meta.json missing field: " .. field)
  end
  assert(meta.suite_version == 1, "suite_version should be 1")
  assert(meta.model == "sonnet", "model should be sonnet")
  assert(meta.agent_tool == "claude", "agent_tool should be claude")
  assert(meta.timeout_secs == 2400, "timeout_secs should be 2400")
end
test_meta_json_has_all_ten_fields()

local function test_bin_sha_matches_independent_digest()
  local bin = fixture_bin()
  local meta = check.must(read_meta(fs.join(run_dir, "meta.json")))
  local sha = meta.bin_sha
  assert(sha ~= nil and #sha == 64 and sha:match("^%x+$"),
    "bin_sha must be 64 hex characters, got: " .. tostring(sha))
  local want = hash.sha256_hex(check.must(fs.read(bin)))
  assert(sha == want, "bin_sha must match an independently computed digest")
end
test_bin_sha_matches_independent_digest()

local function test_printed_output_carries_the_env_scrub()
  local manifest = check.must(stage.load_manifest(stage.MANIFEST_PATH))
  local text = stage.commands_text(run_dir, manifest)
  assert(text:find("env %-u CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"),
    "must scrub CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD")
  assert(text:find("%-u CLAUDE_CODE_SESSION_ID"), "must scrub CLAUDE_CODE_SESSION_ID")
  assert(text:find("%-u CLAUDE_CODE_CHILD_SESSION"), "must scrub CLAUDE_CODE_CHILD_SESSION")
  assert(text:find('--disallowedTools "Skill"', 1, true),
    "must carry --disallowedTools \"Skill\"")
  local count = 0
  for _ in text:gmatch("claude %-p") do
    count = count + 1
  end
  assert(count == 8, "expected 1 probe + 7 launches = 8 'claude -p' lines, got " .. count)
end
test_printed_output_carries_the_env_scrub()

local function test_stage_rejects_missing_bin()
  local out = fs.join(tmpdir, "stage-run-missing-bin")
  local code = stage.main("--bin", fs.join(tmpdir, "no-such-binary"), "--out", out)
  assert(code ~= 0, "staging a missing binary must fail")
end
test_stage_rejects_missing_bin()

--- The probe directory is part of the reproducible run directory,
--- same as the workspaces, so its creation can fail just like theirs:
--- block it with a plain file where the directory needs to go.
local function test_stage_rejects_when_probe_dir_blocked()
  local bin = fixture_bin()
  local out = fs.join(tmpdir, "stage-run-probe-blocked-" .. tostring(os.time()))
  check.must(fs.make_dirs(out))
  check.must(fs.write(fs.join(out, "probe"), "not a directory"))
  local code = stage.main("--bin", bin, "--out", out)
  assert(code ~= 0, "staging must fail when the probe directory can't be created")
end
test_stage_rejects_when_probe_dir_blocked()

local function test_parse_args_requires_bin_and_out()
  assert(stage.parse_args({"--out", "x"}).err ~= nil, "--bin should be required")
  assert(stage.parse_args({"--bin", "x"}).err ~= nil, "--out should be required")
  assert(stage.parse_args({"--bin", "x", "--out", "y"}).err == nil,
    "both flags present should parse cleanly")
end
test_parse_args_requires_bin_and_out()
