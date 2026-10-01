local Removed = require("cosmic.removed")
local coverage_hits = require("build.coverage_hits")

--- Every module [`Removed.members`] names a member of, required by a
--- literal name so the test's import closure holds each: a `require`
--- of a computed name is refused under `cosmic test`
--- ([`build.test_worker`]).
local modules <const>: {string:any} = {
  ["cosmic.archive"] = require("cosmic.archive"),
  ["cosmic.cli"] = require("cosmic.cli"),
  ["cosmic.codec"] = require("cosmic.codec"),
  ["cosmic.csv"] = require("cosmic.csv"),
  ["cosmic.coverage"] = require("cosmic.coverage"),
  ["cosmic.fs"] = require("cosmic.fs"),
  ["cosmic.hash"] = require("cosmic.hash"),
  ["cosmic.http"] = require("cosmic.http"),
  ["cosmic.json"] = require("cosmic.json"),
  ["cosmic.shape"] = require("cosmic.shape"),
  ["cosmic.sqlite"] = require("cosmic.sqlite"),
  ["cosmic.stream"] = require("cosmic.stream"),
  ["cosmic.sys"] = require("cosmic.sys"),
  ["cosmic.tar"] = require("cosmic.tar"),
  ["cosmic.test"] = require("cosmic.test"),
  ["cosmic.time"] = require("cosmic.time"),
  ["cosmic.zip"] = require("cosmic.zip"),
}

--- Every replacement is for a field of a name the surface removes, so
--- `message` can reach it: an entry under a misspelt library would never
--- be said.
local function test_every_replacement_is_for_a_removed_name()
  for dotted in pairs(Removed.replacements) do
    local name = dotted:match("^([%a_]+)%.")
    assert(name ~= nil and Removed.names[name] ~= nil, dotted)
  end
  for _, name in ipairs(Removed.order) do
    assert(Removed.names[name] ~= nil, name)
  end
end

local function test_a_field_with_no_replacement_names_where_to_look()
  assert(Removed.message("debug", "getinfo") ==
    "debug.getinfo is not available: " .. Removed.names.debug)
  assert(Removed.message("print") == "print is not available")
end

--- Every removed member names a `cosmic.*` module that loads and no
--- longer has that member, so its replacement is never said for a
--- member that still works.
local function test_every_removed_member_is_gone_from_its_module()
  for dotted in pairs(Removed.members) do
    local module, member = dotted:match("^(cosmic%.[%w_]+)%.([%w_]+)$")
    assert(module ~= nil, dotted)
    local loaded = modules[module]
    assert(loaded ~= nil, module .. " is not among this test's modules: add it")
    assert(loaded is {string: any} and loaded[member] == nil, dotted)
  end
end

--- A program that called a streaming coder is told that `cosmic codec`
--- has them and which whole-string function to use.
local function test_the_removed_coders_name_the_verb_and_the_whole_string_functions()
  for _, member in ipairs({ "encoder", "decoder", "Coder", "Name" }) do
    local instead = Removed.members["cosmic.codec." .. member]
    assert(instead ~= nil, member)
    assert(instead:find("`cosmic codec`", 1, true), instead)
    assert(instead:find("Codec.base64", 1, true), instead)
  end
end

--- A program that called one of the lookups that moved with the dataset
--- loader is told where they went and that it indexes the table directly.
local function test_the_removed_json_lookups_name_build_json_query_and_direct_indexing()
  for _, member in ipairs({ "get", "entries", "items" }) do
    local instead = Removed.members["cosmic.json." .. member]
    assert(instead ~= nil, member)
    assert(instead:find("build.json_query", 1, true), instead)
  end
  assert(Removed.members["cosmic.json.get"]:find("directly", 1, true))
end

local function test_the_removed_csv_functions_name_what_to_use_instead()
  assert(Removed.members["cosmic.csv.rows"]:find("Csv.table", 1, true))
  assert(Removed.members["cosmic.csv.encode"]:find("delimiter", 1, true))
end

--- A program that named the removed codec type is told its interface.
local function test_the_removed_codec_type_names_the_transform_interface()
  local instead = Removed.members["cosmic.stream.Codec"]
  assert(instead ~= nil and instead:find("Stream.Transform", 1, true), instead)
end

--- A program that asked `into` for every failure, or a union, is told
--- that `into` answers the first and what to write for alternatives.
local function test_the_removed_shape_members_name_into_and_one_of()
  local failures = Removed.members["cosmic.shape.failures"]
  assert(failures ~= nil and failures:find("Shape.into", 1, true) and failures:find("first", 1, true), failures)
  local either = Removed.members["cosmic.shape.either"]
  assert(either ~= nil and either:find("Shape.one_of", 1, true) and either:find("Shape.into", 1, true), either)
  assert(Removed.members["cosmic.shape.Failure"] ~= nil)
end

--- A program that called a [`cosmic.test`] validator is told to declare
--- [`Test.needs`] and let the build refuse a bad one, and one that read the
--- collector's window in place is told the module that has it, which does.
local function test_the_removed_test_and_coverage_members_say_what_to_do_instead()
  for _, member in ipairs({ "fields", "any_host_refusal", "network_trouble", "lua_trouble" }) do
    local instead = Removed.members["cosmic.test." .. member]
    assert(instead ~= nil and instead:find("Test.needs", 1, true), member)
  end
  for _, member in ipairs({ "snapshot", "native_entries" }) do
    local instead = Removed.members["cosmic.coverage." .. member]
    assert(instead ~= nil and instead:find("build.coverage_hits", 1, true), member)
  end
  assert(coverage_hits.snapshot ~= nil and coverage_hits.native_entries ~= nil)
end

--- Every replaced argument is keyed by a `cosmic.*` module that loads,
--- and by the name of a type, which is capitalized.
local function test_every_replaced_argument_names_a_module_that_loads()
  for dotted in pairs(Removed.arguments) do
    local module, record = dotted:match("^(cosmic%.[%w_]+)%.(%u[%w_]*)$")
    assert(module ~= nil and record ~= nil, dotted)
    assert(modules[module] ~= nil, module .. " is not among this test's modules: add it")
  end
end

--- A program that passed a boolean to [`Sqlite.open`] is told what the
--- old `true` becomes and that `false` is no argument.
local function test_the_sqlite_options_name_each_old_boolean_call()
  local instead = Removed.arguments["cosmic.sqlite.OpenOptions"]
  assert(instead ~= nil and instead:find("{ writable = true }", 1, true)
    and instead:find("nothing for `false`", 1, true), instead)
end

--- A program that made a raw pipe for a child's stdin is told to use
--- `stdin = "stream"` and `h.stdin_stream`, never the `"pipe"` mode.
local function test_the_removed_raw_pipe_names_the_stdin_stream()
  for _, member in ipairs({ "pipe", "Pipe", "ignore_sigpipe" }) do
    local instead = Removed.members["cosmic.sys." .. member]
    assert(instead ~= nil and instead:find('stdin = "stream"', 1, true) and
      not instead:find('"pipe"', 1, true), member)
  end
  assert(Removed.members["cosmic.sys.pipe"]:find("h.stdin_stream", 1, true))
end

--- A program that called a removed calendar function or type is told what
--- replaced it: `between` for the two counts, `local_zone` for a TZ string,
--- `Duration` and `AddOptions` for the records.
local function test_the_removed_time_members_name_their_replacements()
  for member, want in pairs({
    months_between = "Time.between", days_between = "Time.between",
    zone_from_posix = "Time.local_zone", Change = "Time.Duration",
    CivilOptions = "Time.AddOptions", parse_input = "build.time",
  } as {string:string}) do
    local instead = Removed.members["cosmic.time." .. member]
    assert(instead ~= nil and instead:find(want, 1, true), member)
  end
end

--- A program that read [`cosmic.cli`]'s `options`, `usage` or `summary` is told
--- which field of the verb's record in `Cli.verbs` holds it now.
local function test_the_removed_cli_maps_name_the_verb_record_field_that_replaced_each()
  local fields: {string:string} = { options = "spec", usage = "usage", summary = "about" }
  for member, field in pairs(fields) do
    local instead = Removed.members["cosmic.cli." .. member]
    assert(instead ~= nil and instead:find("Cli.verbs[verb]." .. field, 1, true), member)
  end
end

--- A program that streamed a request body, truncated a descriptor or
--- asked for a cache path is told what to write instead: a whole body
--- through [`Http.open`], [`sys.ftruncate`], and `cache_dir` with `make = false`.
local function test_the_removed_fs_and_http_members_name_their_replacements()
  for member, want in pairs({
    ["http.upload"] = "Http.open(url, { method = \"PUT\", body = body })",
    ["http.Upload"] = "Http.open(url, { method = \"PUT\", body = body })",
    ["fs.truncate"] = "sys.ftruncate(fd, length)",
    ["fs.cache_path"] = "Fs.cache_dir(tool, { environment = environment, make = false })",
  } as {string:string}) do
    local instead = Removed.members["cosmic." .. member]
    assert(instead ~= nil and instead:find(want, 1, true), member)
  end
end
