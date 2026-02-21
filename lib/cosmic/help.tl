--- Help text generation for cosmic CLI.
--- Produces the complete --help output including static option descriptions
--- and dynamic module list from embedded docs.

local cio = require("cosmic.io")

--- Generate help text for cosmic CLI.
--- @return string The complete help text
local function generate(): string
  local lines: {string} = {}

  -- Load static help text from embedded file, with fallback to inline text
  local static_help, err = cio.slurp("/zip/embed/sys/help.md")
  if static_help then
    table.insert(lines, static_help)
  else
    -- Fallback: inline help text for backwards compatibility
    table.insert(lines, "cosmic-lua: cosmopolitan lua with bundled libraries")
    table.insert(lines, "")
    table.insert(lines, "Usage: cosmic-lua [options] [script [args]]")
    table.insert(lines, "")
    table.insert(lines, "Cosmic options:")
    table.insert(lines, "  --compile <file.tl>           compile Teal file to Lua, lax mode (stdout)")
    table.insert(lines, "  --format <file>               format Teal or Lua file (stdout)")
    table.insert(lines, "  --check-format <file>         check file formatting (diff on stderr)")
    table.insert(lines, "  --check-types <file.tl>       type-check a Teal file, strict mode")
    table.insert(lines, "  --check-examples <file.tl>    run Example_* functions, check output")
    table.insert(lines, "  --examples [module]           browse examples (list all, or show module)")
    table.insert(lines, "  --embed <path>                embed file or directory into executable")
    table.insert(lines, "  --output <file>               output file for --embed (default: cosmic)")
    table.insert(lines, "  --extract <dir>               extract zip contents to directory")
    table.insert(lines, "  --benchmark <file.tl[:pat]>   run Benchmark_* functions, report timing")
    table.insert(lines, "  --docs [query]                show documentation for module or symbol")
    table.insert(lines, "  --test <output> <cmd>...      run command, write .got/.out/.err")
    table.insert(lines, "  --report <paths>...           report on test results")
    table.insert(lines, "  --make [dir] [target]         generate Makefile, pipe to make -f -")
    table.insert(lines, "  --welcome                     show welcome message")
    table.insert(lines, "  -h, --help                    show this help message")
    table.insert(lines, "")
    table.insert(lines, "Standard lua options:")
    table.insert(lines, "  -e <stat>                   execute string 'stat'")
    table.insert(lines, "  -l <name>                   require library 'name'")
    table.insert(lines, "  -i                          enter interactive mode")
    table.insert(lines, "  -v, --version               show version information")
    table.insert(lines, "  -E                          ignore environment variables")
    table.insert(lines, "  -W                          turn warnings into errors")
    table.insert(lines, "")

    table.insert(lines, "Environment variables:")
    table.insert(lines, "  COSMIC_NO_REQUIRE_HINTS    disable helpful module-not-found suggestions")
    table.insert(lines, "  COSMIC_NO_WELCOME          suppress welcome message on first run")
    table.insert(lines, "")
    table.insert(lines, "Documentation:")
    table.insert(lines, "  cosmic --docs [query]      look up docs from the command line")
    table.insert(lines, "  help(<query>)              look up docs in the REPL (interactive only)")
    table.insert(lines, "")
    table.insert(lines, "Low-level cosmo.* bindings are available but hidden by default.")
    table.insert(lines, "Use --docs cosmo.<module> to access them directly.")
    table.insert(lines, "")
    table.insert(lines, "Common patterns:")
    table.insert(lines, "  proc.is_main()              guard code that runs only as a script (not when required)")
    table.insert(lines, "")
    table.insert(lines, "For module documentation, use: cosmic-lua --docs [module]")
  end

  -- Show module list with descriptions (only cosmic.* modules, not cosmo.* bindings)
  local docs = require("cosmic.docs")
  if docs.has_docs() then
    local topics = docs.list_topics() -- excludes cosmo.* by default
    if #topics > 0 then
      local cosmic_topics: {{string, string}} = {}

      for _, topic in ipairs(topics) do
        local name: string = topic[1] as string
        if name:match("^cosmic%.") then
          local short_name = name:gsub("^cosmic%.", "")
          local desc: string = topic[2] as string
          table.insert(cosmic_topics, {short_name, desc})
        end
      end

      if #cosmic_topics > 0 then
        table.sort(cosmic_topics, function(a: {string}, b: {string}): boolean
            return a[1] < b[1]
          end)

        -- Find max name length for alignment
        local max_len = 0
        for _, t in ipairs(cosmic_topics) do
          if #t[1] > max_len then
            max_len = #t[1]
          end
        end

        table.insert(lines, "")
        table.insert(lines, "Available modules:")
        for _, t in ipairs(cosmic_topics) do
          local padding = string.rep(" ", max_len - #t[1] + 2)
          local line = "  " .. t[1] .. padding .. t[2]
          table.insert(lines, line)
        end
      end
    end
  end

  return table.concat(lines, "\n")
end

return {generate = generate}
