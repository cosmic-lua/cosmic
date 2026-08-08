--- Examples for the cosmic.env module.
--- Demonstrates reading, setting, and listing environment variables,
--- and the dotenv half (#994: was cosmic.envd): parsing KEY=VALUE
--- files and loading a directory of them into the environment.
--- For the common case of reading a single variable, env.get() is
--- the simplest approach (it wraps os.getenv() internally). It returns
--- nil when the variable is not set, so the caller narrows; env.get_or()
--- takes a fallback and cannot fail.

-- Example_get demonstrates reading a single environment variable.
-- This is the most common operation. env.get() returns the value
-- as a string, or nil if the variable is not set.
local function Example_get()
  local env = require("cosmic.env")
  local path = env.get("PATH")
  if path then
    print("PATH is set")
  end
  -- Output:
  -- PATH is set
end

-- Example_get_or demonstrates the infallible read: a fallback means the
-- result cannot be nil, so the caller never narrows.
local function Example_get_or()
  local env = require("cosmic.env")
  print(env.get_or("COSMIC_EXAMPLE_UNSET_VAR", "fallback"))
  -- Output:
  -- fallback
end

-- Example_get_missing demonstrates reading a variable that is not set.
local function Example_get_missing()
  local env = require("cosmic.env")
  local value = env.get("COSMIC_EXAMPLE_UNSET_VAR")
  print(tostring(value))
  -- Output:
  -- nil
end

-- Example_set_and_get demonstrates setting and reading back a variable.
local function Example_set_and_get()
  local env = require("cosmic.env")
  local ok, err = env.set("COSMIC_EXAMPLE_VAR", "hello")
  if not ok then
    print("set failed: " .. tostring(err))
    return
  end
  print(env.get("COSMIC_EXAMPLE_VAR"))
  assert(env.unset("COSMIC_EXAMPLE_VAR"))
  -- Output:
  -- hello
end

-- Example_unset demonstrates removing an environment variable.
local function Example_unset()
  local env = require("cosmic.env")
  assert(env.set("COSMIC_EXAMPLE_TEMP", "temporary"))
  assert(env.unset("COSMIC_EXAMPLE_TEMP"))
  print(tostring(env.get("COSMIC_EXAMPLE_TEMP")))
  -- Output:
  -- nil
end

-- Example_all demonstrates listing all environment variables.
-- env.all() returns a plain {string:string} table, unlike the
-- raw unix.environ() call which has a less convenient format.
local function Example_all()
  local env = require("cosmic.env")
  local vars = env.all()
  local count = 0
  for _ in pairs(vars) do
    count = count + 1
  end
  print("environment has " .. tostring(count > 0) .. " variables")
  -- Output:
  -- environment has true variables
end

-- Example_load_dotenv creates a temp directory with dotenv files and
-- loads them. Files are concatenated in lexical order; later files
-- override earlier ones, and the real environment always wins.
local function Example_load_dotenv()
  local env = require("cosmic.env")
  local fs = require("cosmic.fs")

  local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
  local dir = fs.join(tmpdir, "env_dotenv_example")
  assert(fs.make_dirs(dir))
  assert(fs.write(fs.join(dir, "00-defaults"), "MY_APP_NAME=cosmic-example\nMY_APP_PORT=8080\n"))
  assert(fs.write(fs.join(dir, "01-overrides"), "MY_APP_PORT=9090\n"))

  assert(env.unset("MY_APP_NAME"))
  assert(env.unset("MY_APP_PORT"))

  local result = env.load_dotenv(dir)
  print("loaded " .. tostring(result.count) .. " variable(s)")
  print("MY_APP_NAME=" .. tostring(env.get("MY_APP_NAME")))
  print("MY_APP_PORT=" .. tostring(env.get("MY_APP_PORT")))

  assert(env.unset("MY_APP_NAME"))
  assert(env.unset("MY_APP_PORT"))
  -- Output:
  -- loaded 2 variable(s)
  -- MY_APP_NAME=cosmic-example
  -- MY_APP_PORT=9090
end

-- Example_dotenv_round_trip shows the parse/format pair: parse_dotenv
-- reads KEY=VALUE text into a map, format_dotenv writes a map back as
-- deterministic (key-sorted) dotenv text.
local function Example_dotenv_round_trip()
  local env = require("cosmic.env")
  local vars = env.parse_dotenv("PORT=8080\nHOST=localhost\n")
  print("HOST=" .. vars["HOST"])
  io.write(env.format_dotenv(vars))
  -- Output:
  -- HOST=localhost
  -- HOST=localhost
  -- PORT=8080
end

-- Example_dotenv_expansion shows ${VAR} expansion in dotenv values.
-- Variables defined earlier in the same file or from an external
-- context are available for expansion. Supports ${VAR:-default} and
-- ${VAR-default}.
local function Example_dotenv_expansion()
  local env = require("cosmic.env")

  -- basic expansion: later values can reference earlier ones
  local vars = env.parse_dotenv("HOST=localhost\nPORT=8080\nURL=http://${HOST}:${PORT}\n")
  print("URL=" .. vars["URL"])

  -- ${VAR:-default} uses fallback when unset or empty
  vars = env.parse_dotenv("TIMEOUT=${MISSING:-30}\n")
  print("TIMEOUT=" .. vars["TIMEOUT"])

  -- ${VAR-default} uses fallback only when unset (empty is kept)
  vars = env.parse_dotenv("EMPTY=\nKEEP=${EMPTY-fallback}\n")
  print("KEEP=" .. vars["KEEP"])
  -- Output:
  -- URL=http://localhost:8080
  -- TIMEOUT=30
  -- KEEP=
end

-- Example_embed_dotenv demonstrates the full credential-embedding
-- cycle: extract the current executable's zip, add an env.d directory
-- with credentials, re-embed, and run the new executable to show the
-- vars are available via env.load_embedded_dotenv().
local function Example_embed_dotenv()
  local check = require("cosmic.check")
  local fs = require("cosmic.fs")
  local child = require("cosmic.child")
  local cosmic = arg[-1]

  local base = os.getenv("TEST_TMPDIR") or "/tmp"
  local tmpdir = check.must(fs.temp_dir(fs.join(base, "env_dotenv_example_XXXXXX")))

  -- 1. extract current executable
  local extractdir = fs.join(tmpdir, "extracted")
  local r = check.must(child.run({cosmic, "--extract", extractdir}))
  assert(r.ok, r.stderr ~= "" and r.stderr or r.stdout)

  -- 2. add env.d with a credential
  local envd_dir = fs.join(extractdir, "embed", "env.d")
  assert(fs.make_dirs(envd_dir))
  assert(fs.write(fs.join(envd_dir, "credentials"), "MY_SECRET_TOKEN=tok-example-12345\n"))

  -- 3. re-embed with a main.lua that loads env.d and prints the var name
  -- No loader prelude: --embed wraps a custom entry with the cosmic
  -- runtime searcher, so require() just works. The extracted tree
  -- carries the wrapper's entry PAIR (main.lua + main.user.lua, #687);
  -- re-embedding requires replacing the pair, so drop the wrapped
  -- original alongside writing the new entry.
  assert(fs.remove(fs.join(extractdir, "main.user.lua")))
  assert(fs.write(fs.join(extractdir, "main.lua"), [[
local env = require("cosmic.env")
local result = env.load_embedded_dotenv()
print("loaded " .. result.count .. " var(s)")
print("MY_SECRET_TOKEN is " .. (env.get("MY_SECRET_TOKEN") and "set" or "unset"))
]]))

  -- 4. build new executable
  local output = fs.join(tmpdir, "myapp")
  r = check.must(child.run({cosmic, "--embed", extractdir, "--output", output}))
  assert(r.ok, r.stderr ~= "" and r.stderr or r.stdout)

  -- 5. run it
  r = check.must(child.run({output}))
  assert(fs.remove_all(tmpdir))
  print(r.stdout)
  -- Output:
  -- loaded 1 var(s)
  -- MY_SECRET_TOKEN is set
end

-- Suppress unused warnings for examples
local _ = {Example_get, Example_get_or, Example_get_missing, Example_set_and_get,
  Example_unset, Example_all, Example_load_dotenv, Example_dotenv_round_trip,
  Example_dotenv_expansion, Example_embed_dotenv}
