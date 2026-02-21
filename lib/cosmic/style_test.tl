--- Tests for cosmic.style.

local style = require("cosmic.style")

-- helpers

local function lines(n: integer): string
  local t: {string} = {}
  for i = 1, n do
    t[i] = "-- line " .. tostring(i)
  end
  return table.concat(t, "\n") .. "\n"
end

local function col_line(n: integer): string
  return string.rep("x", n) .. "\n"
end

-- test: lines <= 500 passes

local function test_lines_ok()
  local content = lines(500)
  local result = style.check_content("ok.tl", content)
  assert(result.ok, "expected ok for 500 lines")
  assert(#result.diagnostics == 0, "expected no diagnostics")
end

test_lines_ok()

-- test: lines > 500 detected

local function test_lines_over()
  local content = lines(501)
  local result = style.check_content("over.tl", content)
  assert(not result.ok, "expected failure for 501 lines")
  local found = false
  for _, d in ipairs(result.diagnostics) do
    if d.rule == "line-count" then
      found = true
      assert(d.line == 501, "expected line 501, got " .. tostring(d.line))
    end
  end
  assert(found, "expected line-count diagnostic")
end

test_lines_over()

-- test: column <= 90 passes

local function test_col_ok()
  local result = style.check_content("ok.tl", col_line(90))
  assert(result.ok, "expected ok for 90 cols")
end

test_col_ok()

-- test: column > 90 detected at correct position

local function test_col_over()
  local result = style.check_content("over.tl", col_line(91))
  assert(not result.ok, "expected failure for 91 cols")
  local found = false
  for _, d in ipairs(result.diagnostics) do
    if d.rule == "line-length" then
      found = true
      assert(d.line == 1, "expected line 1, got " .. tostring(d.line))
      assert(
        d.col == 91,
        "expected col 91, got " .. tostring(d.col)
      )
    end
  end
  assert(found, "expected line-length diagnostic")
end

test_col_over()

-- test: non-test file skips test-call check

local function test_non_test_file_skips()
  local content = "local function test_foo()\n"
    .. "  assert(true)\n"
    .. "end\n"
  local result = style.check_content("nottest.tl", content)
  for _, d in ipairs(result.diagnostics) do
    assert(
      d.rule ~= "test-not-called",
      "should not check test-call on non-test file"
    )
  end
end

test_non_test_file_skips()

-- test: test function immediately called passes

local function test_test_called_ok()
  local content = "local function test_foo()\n"
    .. "  assert(true)\n"
    .. "end\n"
    .. "test_foo()\n"
  local result = style.check_content("foo_test.tl", content)
  local found = false
  for _, d in ipairs(result.diagnostics) do
    if d.rule == "test-not-called" then
      found = true
    end
  end
  assert(not found, "expected no test-not-called diagnostic")
end

test_test_called_ok()

-- test: test function not called detected

local function test_test_not_called()
  local content = "local function test_foo()\n"
    .. "  assert(true)\n"
    .. "end\n"
    .. "local x = 1\n"
  local result = style.check_content("foo_test.tl", content)
  local found = false
  for _, d in ipairs(result.diagnostics) do
    if d.rule == "test-not-called" then
      found = true
      assert(d.line == 1, "expected line 1")
    end
  end
  assert(found, "expected test-not-called diagnostic")
end

test_test_not_called()

-- test: test function missing call entirely

local function test_test_missing_call()
  local content = "local function test_bar()\n"
    .. "  assert(false)\n"
    .. "end\n"
  local result = style.check_content("bar_test.tl", content)
  local found = false
  for _, d in ipairs(result.diagnostics) do
    if d.rule == "test-not-called" then
      found = true
    end
  end
  assert(found, "expected test-not-called when no call at all")
end

test_test_missing_call()

-- test: blank line between end and call is a violation

local function test_test_blank_before_call()
  local content = "local function test_baz()\n"
    .. "  assert(true)\n"
    .. "end\n"
    .. "\n"
    .. "test_baz()\n"
  local result = style.check_content("baz_test.tl", content)
  local found = false
  for _, d in ipairs(result.diagnostics) do
    if d.rule == "test-not-called" then
      found = true
    end
  end
  assert(found, "expected test-not-called when blank line before call")
end

test_test_blank_before_call()

-- test: format_issues produces correct output

local function test_format_issues()
  local diagnostics: {style.Diagnostic} = {
    {
      file = "f.tl",
      line = 10,
      col = 91,
      rule = "line-length",
      message = "line is 91 columns (max 90)",
    },
  }
  local out = style.format_issues(diagnostics)
  assert(
    out == "f.tl:10:91: error: [line-length] line is 91 columns (max 90)",
    "unexpected format: " .. out
  )
end

test_format_issues()
