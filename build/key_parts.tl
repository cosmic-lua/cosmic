--- The parts of a verdict key a worker spells too: how one contribution
--- is framed ([`key_part`]), how a path names the tree ([`tree_name`]), and
--- which modules read the compiler's identity (`compiler_readers`,
--- [`reads_compiler`]). build.declared_key computes a key from them and
--- answers the compiler's readers as its own, so their callers need not
--- know they live here; a worker (build.test_worker) takes them from
--- here, and so loads none of what the rest of a key takes to compute --
--- the artifact, the core image, the launcher, SQLite.
---
--- Nothing here is taken through a table a test can replace once this
--- module has loaded, ahead of any test's: [`Fs.relative`] is taken as a
--- local at load, and the hexadecimal is its own.

local Fs = require("cosmic.fs")

local relative = Fs.relative

local record key_parts
  hex: function(data: string): string
  unhex: function(text: string): string | nil, string
  compiler_readers: {string}
end

--- Every byte to its two lowercase hex digits, and every pair of hex
--- digits, either case, to the byte it spells.
local hex_of: {string:string} = {}
local byte_of_hex: {string:string} = {}
do
  local digits, upper = "0123456789abcdef", "0123456789ABCDEF"
  for byte = 0, 255 do
    local hi, lo = (byte >> 4) + 1, (byte & 15) + 1
    local ch = string.char(byte)
    hex_of[ch] = digits:sub(hi, hi) .. digits:sub(lo, lo)
    for _, h in ipairs({ digits:sub(hi, hi), upper:sub(hi, hi) }) do
      for _, l in ipairs({ digits:sub(lo, lo), upper:sub(lo, lo) }) do
        byte_of_hex[h .. l] = ch
      end
    end
  end
end

--- Bytes as lowercase hexadecimal, two digits a byte: what
--- [`cosmic.codec`]'s `hex` answers.
local function hex(data: string): string
  return (data:gsub(".", hex_of))
end
key_parts.hex = hex

--- The bytes hexadecimal text spells, in either case, or nil and why
--- for an odd number of digits or a character that is none.
local function unhex(text: string): string | nil, string
  if #text % 2 ~= 0 then
    return nil, ("hex text of odd length %d"):format(#text)
  end
  local at = text:find("[^0-9a-fA-F]")
  if at ~= nil then
    return nil, ("byte 0x%02x at %d is not a hex digit"):format(text:byte(at), at)
  end
  return (text:gsub("..", byte_of_hex)), ""
end
key_parts.unhex = unhex

--- One framed contribution to a verdict key.
function key_parts.key_part(kind: string, path: string, answer: string): string
  return kind .. " " .. hex(path) .. " " .. hex(answer)
end

--- What names the tree's own root in [`tree_name`]: a NUL, which no
--- path holds, so no path outside the tree is ever named as one inside.
local tree_marker <const> = "\0tree"

--- A path as a key names it, the same in every checkout of one tree:
--- one under `tree` -- as written, not climbing with ".." -- by its name
--- below it after a marker no path holds, one under `output`, the
--- tree's build directory, as `o` below that marker, and any other as it
--- is. The tree's own location is no input to what a test does there, so
--- two checkouts of the same content key the same read alike.
---
--- That is a rule, not an accident of keying: a test may not turn on
--- where the tree is -- a path length limit, a name it prints and
--- compares. The answers a capture observes that name the tree (the
--- working directory, a realpath, a readlink, a path under the tree read
--- or given) are keyed by [`tree_name`] in the shared key and whole only in
--- a checkout's own. The artifact path ([`Proc.relaunch`] and the process
--- table's `relaunch` answer) is keyed nowhere.
---
--- The same rule holds of where the running program is: what
--- [`Proc.executable`] answered is keyed nowhere, only that it answered
--- (build.declared_key's `program_answer`).
---
--- Nothing here can see a test break either rule. CI enforces both by
--- moving its checkout, before it builds the tool it runs, to
--- a path the commit and the leg choose, new for each commit
--- (ci/cosmic_ci/place_tree.tl) -- but on the gating runs of a leg
--- whose unsandboxed workers' keys hold the tree's path (build.declared_key's
--- [`Spec.tree`]), where the leg alone chooses it and the scheduled run
--- moves it. That catches a test that breaks one
--- only on a run that runs the test: every run while CI stands only on
--- what it runs itself, and once it stands on shared verdicts, only a
--- run where the test's key changed.
function key_parts.tree_name(path: string, tree: string, output?: string): string
  if ("/" .. path .. "/"):find("/%.%./") ~= nil then return path end
  -- The build directory, outside the tree, by the name a declaration
  -- gives it (`o`), as a sandbox gives it wherever the host has it.
  if output ~= nil then
    local built, _ = relative(path, output)
    if built ~= nil then
      return tree_marker .. "/o" .. (built == "." and "" or "/" .. built)
    end
  end
  local rest, _ = relative(path, tree)
  if rest == nil then return path end
  if rest == "." then return tree_marker end
  return tree_marker .. "/" .. rest
end

--- The modules of the tree that read the compiler's identity
--- ([`Store.meta`]'s `compiler` or `compiled_by`), which a closure store
--- does not carry: a worker's reads of it are answered from the running
--- tool's own `meta`, so a test whose closure holds one of them is keyed
--- by the tool's (build.declared_key's [`Spec.compiler`]).
--- [`build.tree_checks`] refuses the tree when a module of it reads it and
--- is not named here.
local compiler_readers <const>: {string} = {
  "build.dispatch", "build.embed", "build.fix.spill", "build.importer", "build.reboot",
  "build.rebuild", "build.test", "build.tree_checks", "core.allocation_test",
  "cosmic.store_handles_test", "doc.guides.portable-runtime",
}

key_parts.compiler_readers = compiler_readers

--- Whether an import closure, the names of its modules, holds a module
--- that reads the compiler's identity (`compiler_readers`).
function key_parts.reads_compiler(closure: {string}): boolean
  local readers: {string:boolean} = {}
  for _, name in ipairs(compiler_readers) do readers[name] = true end
  for _, name in ipairs(closure) do
    if readers[name] then return true end
  end
  return false
end

return key_parts
