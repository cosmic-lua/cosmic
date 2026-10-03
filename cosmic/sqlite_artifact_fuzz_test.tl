--- The external-path reader shares the structural decoder with startup,
--- but also opens foreign/subset inputs that startup deliberately refuses.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Fuzz = require("build.fuzz")
local fixture = require("build.sql_artifact_fixture")

local function test_artifact_inspection_is_bounded_under_mutation(tmp: string)
  for _, host in ipairs({ false, true }) do
    local path = fixture.write(tmp, host and "host" or "portable", "one", host)
    local original = assert(Fs.read(path))
    local changed = path .. ".changed"
    Fuzz.run({
      name = host and "host artifact inspection" or "portable artifact inspection",
      dir = tmp,
      gen = function(src: Fuzz.Source): string
        local choice = src:int(1, 3)
        if choice == 1 then return original end
        if choice == 2 then return original:sub(1, -2) end
        return Fuzz.mutate(src, original, 4)
      end,
      check = function(bytes: string): boolean, string
        assert(Fs.write(changed, bytes))
        local a, why = Sqlite.artifact(changed)
        if a == nil then
          Fuzz.label("refused")
          return why ~= "", "a refusal must say why"
        end
        Fuzz.label("opened")
        local db, _ = a:open()
        assert(a:close())
        if db ~= nil then
          -- Corrupt SQLite contents may be refused here after valid framing.
          local _, _ = Sqlite.text_rows(db, "PRAGMA quick_check")
          assert(db:close())
        end
        return true, ""
      end,
      requires = { "opened", "refused" },
    })
  end
end
