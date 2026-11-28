--- Fuzz properties for [`Patch.apply`] and [`Diff.parse`], which take a patch from elsewhere: a patch made of mutated
--- text and of hostile names raises nothing, changes nothing outside its root (a link to a directory outside it, a
--- link to a file, and the files beside the root stay as they were), makes nothing under `.git`, and leaves the
--- tree exactly as it was whenever it is refused or a hunk does not fit.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (cosmic/fuzz.tl).

local Diff = require("cosmic.diff")
local Fs = require("cosmic.fs")
local Fuzz = require("cosmic.fuzz")
local Patch = require("cosmic.patch")

--- Patches that apply to the tree [`prepare`] makes, and so give the mutations something to break.
local SAMPLES <const> = {
  "--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n",
  "--- a/sub/g\n+++ b/sub/g\n@@ -1 +1,2 @@\n x\n+y\n",
  "--- /dev/null\n+++ b/deep/er/new\n@@ -0,0 +1,2 @@\n+one\n+two\n",
  "--- a/f\n+++ /dev/null\n@@ -1,3 +0,0 @@\n-a\n-b\n-c\n",
  "diff --git a/f b/h\nsimilarity index 100%\nrename from f\nrename to h\n",
  "diff --git a/f b/f\nold mode 100644\nnew mode 100755\n",
  "diff --git a/f b/f\nold mode 100644\nnew mode 104755\n",
  "diff --git a/out b/out\nnew file mode 120000\n--- /dev/null\n+++ b/out\n@@ -0,0 +1 @@\n+/etc/passwd\n",
  "--- a/out/secret\n+++ b/out/secret\n@@ -1 +1 @@\n-s\n+pwned\n",
  "--- a/../outside/secret\n+++ b/../outside/secret\n@@ -1 +1 @@\n-s\n+pwned\n",
  "--- /dev/null\n+++ b/.git/hooks/pre-commit\n@@ -0,0 +1 @@\n+boom\n",
  "--- /dev/null\n+++ b/link/new\n@@ -0,0 +1 @@\n+pwned\n",
}

--- Names and pieces a hostile patch is made of.
local TOKENS <const> = { "..", ".", "/", "//", "\\", ".git", ".GIT", "out", "link", "sub", "f", "g", "h", "secret",
  "outside", "\0", "\n", "@@ -1 +1 @@\n", "--- ", "+++ ", "diff --git ", "rename to ", "new file mode 120000\n",
  "100755", "160000" }

--- The text of one patch: a sample mutated, with pieces put in.
local function gen_patch(src: Fuzz.Source): string
  local text = Fuzz.pick(src, SAMPLES)
  if src:int(0, 2) == 0 then
    local at = src:int(1, #text + 1)
    text = text:sub(1, at - 1) .. Fuzz.pick(src, TOKENS) .. text:sub(at)
  end
  return Fuzz.mutate(src, text, 4)
end

--- How many trees were made, to name the next.
local made = 0

--- A root with files, directories and links, and beside it files that no patch may touch. Returns the root and the
--- directory that holds the lot.
local function prepare(tmp: string): string, string
  made = made + 1
  local base = tmp .. "/t" .. tostring(made)
  assert(Fs.mkdirs(base .. "/root/sub"))
  assert(Fs.mkdirs(base .. "/outside"))
  assert(Fs.write(base .. "/outside/secret", "s\n"))
  assert(Fs.write(base .. "/root/f", "a\nb\nc\n"))
  assert(Fs.write(base .. "/root/sub/g", "x\n"))
  assert(Fs.symlink(base .. "/outside", base .. "/root/link"))
  assert(Fs.symlink(base .. "/outside/secret", base .. "/root/out"))
  assert(Fs.write(base .. "/beside", "b\n"))
  return base .. "/root", base
end

--- Every file under `dir` with its mode and bytes, and every link with its target, as one string.
local function snapshot(dir: string): string
  local parts: mut {string} = {}
  local files = assert(Fs.walk(dir))
  for _, path in ipairs(files) do
    local stat = assert(Fs.stat(dir .. "/" .. path))
    local body = assert(Fs.read(dir .. "/" .. path))
    local line = path .. "\0" .. tostring(stat.mode & 0xfff) .. "\0" .. body
    parts[#parts + 1] = line
  end
  local function links(at: string, prefix: string)
    for _, name in ipairs(assert(Fs.list(at))) do
      local full = at .. "/" .. name
      local status = assert(Fs.status(full))
      local kind = assert(status.stat).kind
      if kind == "dir" then
        local line = "dir\0" .. prefix .. name
        parts[#parts + 1] = line
        links(full, prefix .. name .. "/")
      elseif kind == "link" then
        local target = assert(Fs.readlink(full))
        local line = "link\0" .. prefix .. name .. "\0" .. target
        parts[#parts + 1] = line
      end
    end
  end
  links(dir, "")
  table.sort(parts)
  return table.concat(parts, "\n")
end

--- Applies `text` to a fresh tree with `opts`, and checks the rules above.
local function check_patch(tmp: string, text: string, opts: Patch.Options): boolean, string
  local root, base = prepare(tmp)
  local before_root, before_outside = snapshot(root), snapshot(base .. "/outside")
  local before_beside = assert(Fs.read(base .. "/beside"))
  local result: Patch.Result? = nil
  local ok, outcome = pcall(function()
    local entries, _ = Diff.parse(text, { strip = 1 })
    if entries == nil then return end
    local applied, _ = Patch.apply(root, entries, opts)
    result = applied
  end)
  if not ok then return false, "raised: " .. tostring(outcome) end
  if snapshot(base .. "/outside") ~= before_outside then
    return false, "a file outside the root changed"
  end
  if assert(Fs.read(base .. "/beside")) ~= before_beside then
    return false, "a file beside the root changed"
  end
  if assert(Fs.status(root .. "/.git")).exists then return false, "a .git was made" end
  local unchanged = true
  local seen = result
  if seen ~= nil then unchanged = not seen.applied end
  if (unchanged or opts.dry_run == true) and snapshot(root) ~= before_root then
    return false, "a refused patch changed the tree"
  end
  return true, ""
end

-- Whatever the patch says, it stays in its root and a refusal changes nothing.
local function test_a_patch_from_elsewhere_stays_in_its_root(tmp: string)
  Fuzz.run({
    name = "patch stays in root",
    dir = tmp,
    gen = gen_patch,
    check = function(input: string): boolean, string
      return check_patch(tmp, input, {})
    end,
  })
end

-- The same patch undone, or tried with fuzz, holds to the same rules.
local function test_an_undone_or_fuzzy_patch_stays_in_its_root(tmp: string)
  Fuzz.run({
    name = "patch reverse and fuzz stay in root",
    dir = tmp,
    gen = gen_patch,
    check = function(input: string): boolean, string
      local ok, why = check_patch(tmp, input, { reverse = true })
      if not ok then return false, why end
      return check_patch(tmp, input, { fuzz = 2, dry_run = true })
    end,
  })
end
