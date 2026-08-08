--- Go-style executable example testing.
--- Parses Example_* functions from Teal files, runs them, and verifies output.

local tl = require("tl")
local scan = require("cosmic.doc.scan")

--- A parsed example function with its expected output.
local record Example
  name: string
  body: string
  expected_output: string
  line: integer
end

--- Result from running a single example.
local record ExampleResult
  name: string
  passed: boolean
  expected: string
  actual: string
  error: string | nil
end

--- Result from running all examples in a file (#992: `message` is
--- the runners' shared shape — what went wrong with the RUN; per-
--- example failures are on each result).
local record RunResult
  exit_code: integer
  results: {ExampleResult}
  message: string | nil
end

--- Options for `run` (#992: the runners share this shape; `filter`
--- has benchmark's contract — a plain SUBSTRING matched against the
--- function name, not a pattern).
local record RunOptions
  filter: string
end

--- Parse a .tl file and extract Example_* functions with their expected output.
--- Finds all local functions named Example_* and extracts their code and -- Output: comments.
--- @param source string The source code to parse
--- @return {Example} List of parsed examples
local function parse_examples(source: string): {Example}
  local examples: {Example} = {}

  -- Pattern to find local function Example_* definitions
  -- Captures: function name, function body (everything until matching end)
  local pos = 1
  local line_num = 1

  while true do
    -- Find next Example_* function definition
    local func_start, func_end, func_name = source:find("local%s+function%s+(Example[%w_]*)%s*%(%s*%)", pos)
    if not func_start then
      break
    end

    line_num = line_num + scan.count_lines(source, pos, func_start)
    local example_line = line_num

    -- Find the function body - need to track nested end keywords
    local body_start = func_end + 1
    local body_end, i = scan.find_block_end(source, body_start)
    local body = source:sub(body_start, body_end)

    -- Extract expected output from -- Output: comment block
    local expected: string = nil
    local output_start = body:find("%-%-%s*Output:")
    if output_start then
      local lines: {string} = {}
      local output_pos = output_start
      -- Skip the "-- Output:" line
      local line_end = body:find("\n", output_pos)
      if line_end then
        output_pos = line_end + 1
        -- Collect subsequent comment lines
        while true do
          local line_start, _, prefix, content = body:find("^([ \t]*%-%-[ \t]?)([^\n]*)", output_pos)
          if line_start == output_pos and prefix then
            table.insert(lines, content)
            output_pos = output_pos + #prefix + #content
            if body:sub(output_pos, output_pos) == "\n" then
              output_pos = output_pos + 1
            else
              break
            end
          else
            break
          end
        end
      end
      expected = table.concat(lines, "\n")
      if #lines > 0 then
        expected = expected .. "\n"
      end
    end

    table.insert(examples, {
        name = func_name,
        body = body,
        expected_output = expected,
        line = example_line,
      })

    pos = i
  end

  return examples
end

--- Run a single example and capture its output.
--- Executes the example code and compares actual output with expected output.
--- @param example Example The example to run
--- @return ExampleResult Result with pass/fail status and output comparison
local function run_example(example: Example): ExampleResult
  local result: ExampleResult = {
    name = example.name,
    passed = false,
    expected = example.expected_output or "",
    actual = "",
    error = nil,
  }

  -- If no expected output specified, it's a skip (example exists but no output check)
  if not example.expected_output then
    result.passed = true
    return result
  end

  -- Build a script that executes the example body
  -- Compile through Teal first to handle type annotations
  local teal_source = example.body

  -- Initialize Teal environment (lax, compat off, 5.4 target — same
  -- settings cosmic.teal's make_env uses) and process the source.
  -- process_string always returns a Result; failures land in its
  -- syntax_errors field, not a second return.
  local env = tl.init_env(true, "off", "5.4")
  local tl_result = tl.process_string(teal_source, true, env, "@" .. example.name)

  if tl_result.syntax_errors and #tl_result.syntax_errors > 0 then
    result.error = "syntax error: " .. tl_result.syntax_errors[1].msg
    return result
  end

  -- tl.generate's second argument is the target STRING, not an options
  -- table; passing a table silently fell back to the default (non-5.4)
  -- target, which rejects 5.4-only features like <close> attributes.
  local lua_code = tl.generate(tl_result.ast, "5.4")

  if not lua_code then
    result.error = "compile error: code generation failed"
    return result
  end

  -- No loader prelude: the cosmic dispatcher's runtime .tl searcher
  -- already resolves require statements in example bodies.
  local script = lua_code

  -- Execute using load
  local chunk, load_err = load(script, example.name)
  if not chunk then
    result.error = "load error: " .. (load_err or "unknown")
    return result
  end

  -- Capture stdout by replacing print and io.write
  local old_print = print
  local old_write = io.write
  local output_chunks: {string} = {}

  local function capture_print(...: any)
    local args = {...}
    local parts: {string} = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring(args[i])
    end
    table.insert(output_chunks, table.concat(parts, "\t") .. "\n")
  end

  local function capture_write(...: any): FILE, string, integer
    local args = {...}
    for _, v in ipairs(args) do
      table.insert(output_chunks, tostring(v))
    end
    return io.stdout
  end

  _G.print = capture_print
  io.write = capture_write

  local ok, run_err = pcall(chunk)

  _G.print = old_print
  io.write = old_write

  if not ok then
    result.error = "runtime error: " .. tostring(run_err)
    return result
  end

  result.actual = table.concat(output_chunks)

  -- Compare output (strip trailing whitespace like Go)
  local expected_normalized = result.expected:gsub("%s+$", "")
  local actual_normalized = result.actual:gsub("%s+$", "")
  if actual_normalized == expected_normalized then
    result.passed = true
  end

  return result
end

--- Run all examples in a file.
--- Parses and executes all Example_* functions, returning aggregated results.
--- @param file_path string Path to the Teal file containing examples
--- @param opts RunOptions? filter substring on Example_* names
--- @return RunResult Result with exit code (0=pass, 1=fail, 2=skip), results, and a message
local function run(file_path: string, opts?: RunOptions): RunResult
  local f, err = io.open(file_path, "r")
  if not f then
    return {
      exit_code = 1,
      results = {},
      message = "cannot open file: " .. (err or "unknown"),
    }
  end

  local source = f:read("*a")
  f:close()

  local all_examples = parse_examples(source)
  local filter = opts and opts.filter

  local examples: {Example} = {}
  if filter then
    for _, example in ipairs(all_examples) do
      if example.name:find(filter, 1, true) then
        table.insert(examples, example)
      end
    end
  else
    examples = all_examples
  end

  if #examples == 0 then
    -- No examples found (or none matched the filter) - a skip (exit code 2)
    if filter and #all_examples > 0 then
      return {
        exit_code = 2,
        results = {},
        message = "no examples matching '" .. filter .. "' (found "
        .. #all_examples .. " total)",
      }
    end
    return {
      exit_code = 2,
      results = {},
      message = nil,
    }
  end

  local results: {ExampleResult} = {}
  local all_passed = true

  for _, example in ipairs(examples) do
    local result = run_example(example)
    table.insert(results, result)
    if not result.passed then
      all_passed = false
    end
  end

  return {
    exit_code = all_passed and 0 or 1,
    results = results,
    message = nil,
  }
end

--- Format results for human-readable output.
--- Creates formatted test output showing PASS/FAIL/SKIP with expected vs actual output.
--- @param file_path string Path to the file that was tested
--- @param run_result RunResult Results from running examples
--- @return string Formatted output for display
local function format_results(file_path: string, run_result: RunResult): string
  local lines: {string} = {}

  if run_result.message then
    table.insert(lines, file_path .. ": ERROR: " .. run_result.message)
    return table.concat(lines, "\n")
  end

  if run_result.exit_code == 2 then
    table.insert(lines, file_path .. ": SKIP (no examples)")
    return table.concat(lines, "\n")
  end

  for _, result in ipairs(run_result.results) do
    if result.passed then
      if result.expected == "" then
        table.insert(lines, file_path .. ": " .. result.name .. ": SKIP (no output check)")
      else
        table.insert(lines, file_path .. ": " .. result.name .. ": PASS")
      end
    else
      table.insert(lines, file_path .. ": " .. result.name .. ": FAIL")
      if result.error then
        table.insert(lines, "  error: " .. result.error)
      else
        table.insert(lines, "  expected:")
        for line in result.expected:gmatch("[^\n]*") do
          if line ~= "" then
            table.insert(lines, "    " .. line)
          end
        end
        table.insert(lines, "  actual:")
        for line in result.actual:gmatch("[^\n]*") do
          if line ~= "" then
            table.insert(lines, "    " .. line)
          end
        end
      end
    end
  end

  return table.concat(lines, "\n")
end

local record ExampleModule
  type RunOptions = RunOptions
  type RunResult = RunResult

  run: function(file_path: string, opts?: RunOptions): RunResult
  parse_examples: function(source: string): {Example}
  format_results: function(file_path: string, run_result: RunResult): string
end

local M: ExampleModule = {
  run = run,
  parse_examples = parse_examples,
  format_results = format_results,
}

return M
