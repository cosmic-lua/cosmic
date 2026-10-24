--- The cheap form of the proof that the tool can be bootstrapped from the new checker's seed ([`build.seed_proof`]): the real
--- seed, the real bridge, a tree of the seed's own translated files and a stub in the place of [`build.boot`]. The seed is
--- compiled by this tool, which is what the pinned release's compile is once the pin names this tree's generator; the proof
--- itself (`bin/cosmic build/seed_proof_main.tl prove <dir>`) compiles it with the pinned release and boots the whole tree.

local Fs = require("cosmic.fs")
local SeedProof = require("build.seed_proof")
local Test = require("cosmic.test")
local artifact = require("build.artifact")

Test.policy{ grants = {
  { path = "build/", letters = "r" },
  { path = "lang/", letters = "r" },
  { path = "cosmic/", letters = "r" },
  { path = "core/bridge_new.lua", letters = "r" },
} }

--- A stand-in for [`build.boot`] that reaches the seed's code through the bridge, and for [`build.gen_syscalls`], which
--- the boot loads first.
local BOOT <const> = [[
local Truthy = require("lang.truthy")
local String = require("cosmic.string")
return function(root: string, argv: {string}, source: string): integer
  return (type(Truthy) == "table" and type(String) == "table") and 7 or 3
end
]]

local GEN_SYSCALLS <const> = [[
local record Gen
  targets: {string}
  declaration: function(): string
end
local gen: Gen = { targets = {}, declaration = function(): string return "return {}" end }
return gen
]]

--- Writes the translated files of the seed list below `tmp`/tree, with the declarations of the standard library and the
--- stand-ins, and the seed this tool compiles of them below `tmp`/seed. Answers the seed list.
local function prepared(tmp: string): {string}
  local list = assert(SeedProof.listed("."))
  local report = assert(SeedProof.translate(".", list, tmp .. "/tree"))
  local declarations = assert(SeedProof.translate(".", { "lang/prelude.d.tl", "lang/stdlib.d.tl" }, tmp .. "/tree"))
  assert(#report.refused == 0 and #declarations.refused == 0, "the translation refused a file of the seed")
  local tree = tmp .. "/tree"
  assert(Fs.write(tree .. "/build/seed.txt", (assert(Fs.read("build/seed.txt")))))
  assert(Fs.mkdirs(tree .. "/core"))
  assert(Fs.write(tree .. "/core/bridge.lua", SeedProof.shim()))
  assert(Fs.write(tree .. "/core/bridge_new.lua", (assert(Fs.read("core/bridge_new.lua")))))
  assert(Fs.write(tree .. "/build/boot.tl", BOOT))
  assert(Fs.write(tree .. "/build/gen_syscalls.tl", GEN_SYSCALLS))
  assert(SeedProof.compile(tree, list, tmp .. "/seed"))
  return list
end

local function boot(tmp: string, cache: string): SeedProof.Booted
  local core = tmp .. "/cosmic-core"
  if Fs.exists(core) ~= true then
    local trusted = assert(artifact.trusted_core())
    assert(Fs.write(core, trusted.bytes, 0x1ed))
  end
  return (assert(SeedProof.boot(core, tmp .. "/tree", tmp .. "/seed", { "status" },
    { COSMIC_BRIDGE_TRACE = "1", COSMIC_BUILD_CACHE = cache })))
end

local function test_the_seed_boots_a_tree_through_the_bridge_and_agrees_with_its_own_compile(tmp: string)
  prepared(tmp)
  local booted = boot(tmp, tmp .. "/cache.db")
  -- No lang/SEED_DIFFERS is there to excuse a difference, so the seed and stage two are one text for every file.
  assert(booted.code == 7, "exit " .. tostring(booted.code) .. ": " .. booted.stderr)
  local seen = table.concat(booted.trace, "\n")
  assert(seen:find("stage two: compiled by stage one", 1, true) and seen:find("build.boot loaded: ", 1, true), seen)
  local again = boot(tmp, tmp .. "/cache.db")
  assert(again.code == 7, "exit " .. tostring(again.code) .. ": " .. again.stderr)
  assert(table.concat(again.trace, "\n"):find("stage two: taken from the cache", 1, true), table.concat(again.trace, "\n"))
end

--- A change to what the generator writes that the pin lacks shows as a file whose seed differs from stage two: the boot
--- refuses it unless the tree names the file.
local function test_a_file_the_seed_writes_otherwise_than_the_tree_does_is_named(tmp: string)
  prepared(tmp)
  local text = assert(Fs.read(tmp .. "/seed/truthy.lua"))
  assert(Fs.write(tmp .. "/seed/truthy.lua", text .. "\n-- the pin's emitter wrote this\n"))
  local booted = boot(tmp, "0")
  assert(booted.code == 1, "exit " .. tostring(booted.code))
  assert(booted.stderr:find("differs from the build compiled by itself in lang/truthy.tl", 1, true), booted.stderr)
  assert(Fs.write(tmp .. "/tree/lang/SEED_DIFFERS", "lang/truthy.tl\n"))
  local declared = boot(tmp, "0")
  assert(declared.code == 7, "exit " .. tostring(declared.code) .. ": " .. declared.stderr)
end
