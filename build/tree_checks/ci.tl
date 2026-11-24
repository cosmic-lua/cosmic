--- The checks of the tree over `ci/`: its sources listed, and every file under ci/testdata type-checking standalone.

local Fs = require("cosmic.fs")
local Pipeline = require("build.pipeline")
local Ceilings = require("build.ceilings")
local Warnings = require("lang.warnings")
local _ = require("build.reads.all")
local tree_common = require("build.tree_checks.common")

local nth = tree_common.nth

local record tree_ci
end

--- The Teal sources of `ci/` under `root`, out of the projection (ci is
--- a tree of its own), as `{file, source}` pairs: every module of
--- `ci/cosmic_ci` that is not a test.
function tree_ci.ci_sources(root: string): {{string}}
  local out: mut {{string}} = {}
  local listed, _ = Fs.walk(root .. "/ci/cosmic_ci")
  for _, name in ipairs(listed or {}) do
    if name:match("%.tl$") ~= nil and name:match("_test%.tl$") == nil then
      local text, _ = Fs.read(root .. "/ci/cosmic_ci/" .. name)
      if text ~= nil then out[#out + 1] = { "ci/cosmic_ci/" .. name, text } end
    end
  end
  table.sort(out, function(a: {string}, b: {string}): boolean return nth(a, 1) < nth(b, 1) end)
  return out
end

--- Whether `line`, a finding of the new checker, is a warning of an unused name: it ends its message with the code.
local function unused_warning(line: string): boolean
  for _, code in ipairs(Warnings.codes) do
    if Warnings.kind_of(code) == "unused" and line:find("(" .. code .. "): ", 1, true) ~= nil then
      return true
    end
  end
  return false
end

--- The Teal under `ci/testdata` that fails to type-check in the new checker ([`build.pipeline`]), one line per complaint.
--- No leg runs these with `--standalone`: they are copied into fixture directories and run there, `cmd/*/main.tl` as
--- modules of a project the candidate builds, `retained_probe.tl` and `work_db_integrity.tl` as files, and
--- `runtime_test.tl` by `cosmic test`. Each requires `cosmic.*` modules alone and is held to a build's own strictness,
--- which a file alone is checked under ([`Pipeline.alone`]: the declarations the tool carries, and no marker), so a
--- refusal that would otherwise be met only when a leg runs it is met here; `cosmic fix --check` in `ci/` only parses
--- them. Each is read as written, and every finding of the checker is told: no marker or count holds one. A test module's
--- unused functions are no complaint (a test runner calls them); any other file's unused locals are.
function tree_ci.ci_testdata(root: string): {string}
  local out: mut {string} = {}
  local options, options_trouble = Pipeline.alone()
  if options == nil then return { options_trouble } end
  local listed, _ = Fs.walk(root .. "/ci/testdata")
  local names: mut {string} = {}
  for _, name in ipairs(listed or {}) do
    if name:match("%.tl$") then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local file = "ci/testdata/" .. name
    local source, read_trouble = Fs.read(root .. "/" .. file)
    if source == nil then
      out[#out + 1] = tostring(read_trouble)
    else
      -- Checked under its path below `ci/testdata`, which the build leaves out of a tree as no module of it (any
      -- `testdata/` directory), and told under its own.
      local testy = name:match("_test%.tl$") ~= nil
      local made = Pipeline.checked_alone(name, source, options, testy)
      local findings: mut {Ceilings.Finding} = {}
      local codes: mut {string} = {}
      local seen: mut {string: boolean} = {}
      for _, line in ipairs(made.lines) do
        if not (testy and unused_warning(line)) then
          local y, x, msg, code, fix = line:match("^[^:]+:(%d+):(%d+): (.-) %(([%a_]+)%): (.*)$")
          if code == nil or msg == nil or fix == nil then
            -- The checker's own count of a code ("2 errors of x in its bodies") is told again, by the markers, below.
            -- TODO: take the findings of [`Pipeline.checked_alone`] as the spots of [`build.ceilings.marked`] and not parse its
            -- prose here, once it answers them beside its lines; a changed wording tells a count twice, which fails closed.
            if line:match("^[^:]+: %d+ errors? of [%a_]+ in its %a+ on line %d+; follow the fix above$") == nil then
              out[#out + 1] = if line:sub(1, #name + 1) == name .. ":" then file .. line:sub(#name + 1) else line end
            end
          else
            findings[#findings + 1] = { code = code, y = math.tointeger(tonumber(y)) or 0,
              x = math.tointeger(tonumber(x)) or 0, msg = msg, fix = fix }
            if seen[code] ~= true then
              seen[code] = true
              codes[#codes + 1] = code
            end
          end
        end
      end
      for _, line in ipairs(Ceilings.marked("checked", file, "", findings, codes, "bodies", true).lines) do
        out[#out + 1] = line
      end
      if made.code == nil and #made.lines == 0 then
        out[#out + 1] = file .. ": the compiler refused it"
      end
    end
  end
  return out
end

return tree_ci
