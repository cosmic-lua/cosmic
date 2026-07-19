#!/usr/bin/env cosmic
-- Windows-absolute path handling (#510 step 12). These are pure string
-- operations, so they run — and must pass — on every OS: cosmic ships
-- one binary, and a path pasted from a Windows shell must not turn into
-- garbage on the machine that happens to process it.
local fs = require("cosmic.fs")

-- is_absolute: POSIX, drive-letter, and UNC roots

local function test_is_absolute_posix()
  assert(fs.is_absolute("/"), "/ is absolute")
  assert(fs.is_absolute("/usr/lib"), "/usr/lib is absolute")
  assert(not fs.is_absolute("usr/lib"), "relative path")
  assert(not fs.is_absolute("./x"), "explicit relative")
  assert(not fs.is_absolute(""), "empty path")
end
test_is_absolute_posix()

local function test_is_absolute_drive()
  assert(fs.is_absolute("C:/foo"), "forward-slash drive root")
  assert(fs.is_absolute("C:\\foo"), "backslash drive root")
  assert(fs.is_absolute("c:\\foo"), "lowercase drive root")
  assert(fs.is_absolute("C:/"), "bare drive root")
  assert(not fs.is_absolute("C:foo"), "drive-relative is not absolute")
  assert(not fs.is_absolute("C:"), "bare drive is not absolute")
  assert(not fs.is_absolute("1:/foo"), "non-letter drive")
  assert(not fs.is_absolute("CC:/foo"), "multi-letter drive")
end
test_is_absolute_drive()

local function test_is_absolute_unc_and_backslash()
  assert(fs.is_absolute("\\\\server\\share"), "UNC root")
  -- On POSIX "\" is an ordinary filename character; a single leading
  -- backslash stays a relative path.
  assert(not fs.is_absolute("\\foo"), "single backslash is relative")
  assert(not fs.is_absolute("a\\b"), "interior backslash is relative")
end
test_is_absolute_unc_and_backslash()

-- normalize: drive-letter roots

local function test_normalize_drive_separators()
  assert(fs.normalize("C:\\foo\\bar") == "C:/foo/bar",
    "backslashes become forward slashes under a drive root")
  assert(fs.normalize("C:/foo//bar") == "C:/foo/bar", "redundant slashes")
  assert(fs.normalize("C:\\foo/bar") == "C:/foo/bar", "mixed separators")
end
test_normalize_drive_separators()

local function test_normalize_drive_dots()
  assert(fs.normalize("c:/a/./b/../c") == "C:/a/c",
    "dots collapse and the drive letter uppercases")
  assert(fs.normalize("C:\\..") == "C:/", ".. at the root is ignored")
  assert(fs.normalize("C:/") == "C:/", "bare root unchanged")
end
test_normalize_drive_dots()

local function test_normalize_drive_idempotent()
  local once = fs.normalize("c:\\a\\..\\b\\.\\c")
  assert(once == "C:/b/c", "got: " .. once)
  assert(fs.normalize(once) == once, "normalize is idempotent")
end
test_normalize_drive_idempotent()

-- normalize: UNC roots keep the backslash form

local function test_normalize_unc()
  assert(fs.normalize("\\\\server\\share\\a\\..\\b") == "\\\\server\\share\\b",
    "UNC dots collapse, backslash form kept")
  local unc = fs.normalize("\\\\server\\share")
  assert(unc == "\\\\server\\share", "got: " .. unc)
  assert(fs.normalize(unc) == unc, "UNC normalize is idempotent")
end
test_normalize_unc()

-- normalize: POSIX paths still treat "\" as a filename character

local function test_normalize_posix_backslash_preserved()
  assert(fs.normalize("a\\b/c") == "a\\b/c", "backslash inside component")
  assert(fs.normalize("/a\\b/../c") == "/c", "backslash component pops as one")
end
test_normalize_posix_backslash_preserved()

-- abspath: Windows-absolute paths never get cwd prepended

local function test_abspath_drive()
  assert(fs.abspath("C:\\foo") == "C:/foo", "drive path stays rooted")
  assert(fs.abspath("c:/a/../b") == "C:/b", "drive path normalizes")
end
test_abspath_drive()

local function test_abspath_unc()
  assert(fs.abspath("\\\\srv\\share\\x") == "\\\\srv\\share\\x",
    "UNC path stays rooted")
end
test_abspath_unc()

-- relpath: same drive walks, different roots return the absolute target

local function test_relpath_same_drive()
  assert(fs.relpath("C:/a/b", "C:/a") == "b", "child of base")
  assert(fs.relpath("C:/a", "C:/b") == "../a", "sibling")
  assert(fs.relpath("C:\\a\\b", "c:\\a") == "b", "mixed case and separators")
  assert(fs.relpath("C:/a", "C:/a") == ".", "same path")
end
test_relpath_same_drive()

local function test_relpath_different_roots()
  assert(fs.relpath("C:/x", "D:/y") == "C:/x", "different drives")
  assert(fs.relpath("C:\\x", "/tmp") == "C:/x", "drive vs POSIX")
  assert(fs.relpath("/tmp/x", "C:/a") == "/tmp/x", "POSIX vs drive")
  assert(fs.relpath("\\\\srv\\s\\x", "C:/a") == "\\\\srv\\s\\x",
    "UNC vs drive")
end
test_relpath_different_roots()

local function test_relpath_unc()
  assert(fs.relpath("\\\\srv\\s\\a\\b", "\\\\srv\\s\\a") == "b",
    "same share walks")
  assert(fs.relpath("\\\\srv\\a\\x", "\\\\srv\\b\\y") == "\\\\srv\\a\\x",
    "different shares have no relative form")
end
test_relpath_unc()
