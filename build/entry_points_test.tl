--- The bar a whole test run of cosmic's own tree holds the C to: every
--- entry point called by some test, or exempt with a reason.

local Coverage = require("cosmic.coverage")
local entry_points = require("build.entry_points")
local sys = require("cosmic.sys")

local function hit(names: {string}): Coverage.Hits
  local hits: Coverage.Hits = { ["some.module"] = { [3] = true } }
  for _, name in ipairs(names) do
    hits[Coverage.called_path(name)] = { [Coverage.called_line] = true }
  end
  return hits
end

local function test_every_syscall_binding_print_and_the_object_methods_are_named()
  local names: {string: boolean} = {}
  for _, name in pairs(entry_points.all()) do
    names[name] = true
  end
  for binding, value in pairs(sys as {string: any}) do
    if type(value) == "function" then
      assert(names["sys." .. binding], "sys." .. binding .. " is an entry point")
    end
  end
  assert(names["print"] and names["errors.trace"])
  assert(names["sqlite.handle.exec"] and names["sqlite.statement.step"])
end

local function test_the_raw_http_hash_and_compress_functions_and_methods_are_named()
  local names: {string: boolean} = {}
  for _, name in pairs(entry_points.all()) do
    names[name] = true
  end
  for _, name in ipairs({ "http.open", "http.handle.read", "http.handle.headers",
                          "http.handle.sent", "hash.hasher", "hash.hasher.update",
                          "compress.inflater", "compress.stream.update" }) do
    assert(names[name], name .. " is an entry point")
  end
end

local function test_every_exemption_names_an_entry_point_and_a_reason()
  local names: {string: boolean} = {}
  for _, name in pairs(entry_points.all()) do
    names[name] = true
  end
  for name, reason in pairs(entry_points.exempt) do
    assert(names[name], name .. " is exempt but is no entry point")
    assert(reason ~= "", name .. " is exempt without a reason")
  end
end

local function test_tally_counts_reached_exempt_and_unreached()
  local points: {any: string} = { [print] = "a", [sys.getpid] = "b",
                                  [sys.exit] = "sys.exit", [sys.open] = "c" }
  local tally = entry_points.tally(points, hit({ "a", "c" }))
  assert(tally.total == 4)
  assert(tally.reached == 2)
  assert(tally.exempted == 1, "sys.exit is exempt")
  assert(#tally.unreached == 1 and tally.unreached[1] == "b")
end

local function test_an_exempt_point_a_test_calls_counts_as_reached()
  local tally = entry_points.tally({ [sys.exit] = "sys.exit" }, hit({ "sys.exit" }))
  assert(tally.reached == 1 and tally.exempted == 0 and #tally.unreached == 0)
end
