--- [`eval/solve.tl`]'s pure parts: its command line, the arguments and
--- environment the solver is given, and what its sandbox unveils.
local Solve = require("eval.solve")

local function test_the_command_line_takes_an_arena_and_a_model()
  local options = assert(Solve.parse({ "/a", "--model", "m" }))
  assert(options.arena == "/a" and options.model == "m")
  assert(options.max_turns == 60 and options.timeout == 600)
  options = assert(Solve.parse({ "--timeout", "30", "/a", "--max-turns", "3", "--model", "m" }))
  assert(options.max_turns == 3 and options.timeout == 30)
end

local function test_the_command_line_refuses_what_it_cannot_run()
  local cases: {{string}} = {
    { "an arena is required" },
    { "--model is required", "/a" },
    { "--model needs a value", "/a", "--model" },
    { "--timeout takes a positive integer: 0", "/a", "--model", "m", "--timeout", "0" },
    { "--max-turns takes a positive integer: 2x", "/a", "--model", "m", "--max-turns", "2x" },
    { "unknown option --bare", "/a", "--bare" },
    { "one arena only: /b", "/a", "/b" },
  }
  for _, case in ipairs(cases) do
    local argv: {integer:string} = { table.unpack(case, 2) }
    local options, trouble = Solve.parse(argv)
    assert(options == nil and trouble == case[1], trouble)
  end
end

local function test_the_arguments_are_the_manual_launchs()
  local options = assert(Solve.parse({ "/a", "--model", "m", "--max-turns", "7" }))
  local args = Solve.arguments("the prompt", options)
  assert(args[1] == "-p" and args[2] == "the prompt", args[1])
  local joined = table.concat(args, " ")
  assert(joined:find("--model m --disable-slash-commands", 1, true), joined)
  local tail = "--max-turns 7 --output-format stream-json --verbose"
  assert(joined:sub(-#tail) == tail, joined)
  assert(joined:find("--disallowedTools Skill,WebSearch,", 1, true), joined)
end

local function test_the_environment_keeps_only_what_the_cli_needs()
  local host: {string:string} = {
    HTTPS_PROXY = "http://127.0.0.1:1", SSL_CERT_FILE = "/ca.crt", HOME = "/root",
    CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD = "1", CLAUDE_ADDITIONAL_DIRECTORIES = "/home/user/cosmic",
    CLAUDE_CODE_SYNC_SKILLS = "1", GH_TOKEN = "secret", PATH = "/opt/x/bin:/usr/bin",
  }
  local env = Solve.environment(host, "/r", { "/opt/node/bin" })
  local names: {string} = {}
  for name in pairs(env) do names[#names + 1] = name end
  table.sort(names)
  assert(table.concat(names, " ") == "CLAUDE_CONFIG_DIR COSMIC_TEST_SANDBOX HOME HTTPS_PROXY PATH SSL_CERT_FILE TMPDIR",
    table.concat(names, " "))
  assert(env.PATH == "/r/bin:/opt/node/bin:/usr/local/bin:/usr/bin:/bin", env.PATH)
  assert(env.HOME == "/r/home" and env.CLAUDE_CONFIG_DIR == "/r/config" and env.TMPDIR == "/r/tmp")
  assert(env.COSMIC_TEST_SANDBOX == "0", "the solver's tests run unsandboxed")
end

local function test_a_native_cli_is_given_alone_and_a_script_with_its_interpreter()
  local found: {string:string} = { node = "/opt/node/bin/node" }
  local function find(name: string): string | nil return found[name] end
  local native = assert(Solve.program("/opt/c/bin/claude", "\127ELF\2\1", find))
  assert(#native.reads == 1 and native.reads[1] == "/opt/c/bin/claude" and #native.path == 0)
  local script = assert(Solve.program("/usr/lib/node_modules/cc/cli.js",
    "#!/usr/bin/env node\nimport x\n", find))
  assert(script.reads[1] == "/usr/lib/node_modules/cc" and script.reads[2] == "/opt/node/bin/node")
  assert(script.path[1] == "/opt/node/bin")
  local none, trouble = Solve.program("/x/claude", "#!/usr/bin/env deno\n", find)
  assert(none == nil and trouble == "/x/claude: interpreter deno not found", trouble)
  none, trouble = Solve.program("/x/claude", "plain text", find)
  assert(none == nil and trouble:find("neither", 1, true), trouble)
end

local function test_the_sandbox_unveils_the_arena_and_the_hosts_runtime_alone()
  local program: Solve.Program = { reads = { "/opt/c/bin/claude" }, path = {} }
  local reads = Solve.host_reads({ SSL_CERT_FILE = "/ca/bundle.crt", NODE_EXTRA_CA_CERTS = "relative" })
  local missing: {string:boolean} = { ["/lib64"] = true }
  local unveil = Solve.unveil("/r", program, reads, function(path: string): boolean
    return not missing[path]
  end)
  local given: {string:boolean} = {}
  for _, path in ipairs(unveil.reads) do given[path] = true end
  for _, path in ipairs({ "/usr", "/etc", "/proc", "/dev/null", "/ca/bundle.crt",
      "/home/claude/.claude/remote/.oauth_token", "/opt/c/bin/claude", "/r/bin" }) do
    assert(given[path], path)
  end
  for _, path in ipairs({ "/lib64", "relative", "/home", "/root", "/sys", "/tmp", "/r", "/r/project" }) do
    assert(not given[path], path)
  end
  assert(table.concat(unveil.writes, " ") == "/r/project /r/tmp /r/config /r/home",
    table.concat(unveil.writes, " "))
end

local function test_the_status_is_what_timeout_would_record()
  assert(Solve.status({ code = 3, ok = false, timed_out = false, captured = {}, truncated = false }) == 3)
  assert(Solve.status({ signal = 9, ok = false, timed_out = true, captured = {}, truncated = false }) == 124)
  assert(Solve.status({ signal = 15, ok = false, timed_out = false, captured = {}, truncated = false }) == 143)
end

local function test_the_proc_probe_looks_for_a_pid_outside_the_sandbox()
  local probe = Solve.proc_probe(4242)
  assert(probe[1] == "/bin/sh" and probe[3] == "test ! -e /proc/4242", probe[3])
end
