--- The throw and exit rules: D30 licenses a `cosmic.*` module to throw
--- or exit only where no caller could receive the value — a Lua
--- protocol whose error channel is the throw, a process boundary, or an
--- infallible-by-type contract violated past the checker — and demands
--- the argument written beside the site: `-- throws: <why>` on an
--- `error(` line, `-- exits: <why>` on an `os.exit(`/`unix.exit(`
--- line, trailing or on the line directly above. `throw-justify` and
--- `exit-justify` are that demand as a gate, the way `assert-justify`
--- enforces D23's licence on a library assert.
---
--- Token-exact via the lexer, so an `error(` quoted inside a string or
--- a doc comment never counts — `cosmic/embed/init.tl`'s entry-wrapper
--- SOURCE is a string constant this tree writes rather than runs. The
--- exit rule matches the two receivers the tree exits through, `os`
--- and `unix`: both are process exits, and the quicksand post-fork
--- children reach the OS through the binding rather than the stdlib.
---
--- Two modules are exempt at the file level, exactly as D30 records:
--- `cosmic/check.tl` (its assertions and exits ARE its contract, D23)
--- and `cosmic/rand.tl` (the CSPRNG's throw-on-failure, D22). Their
--- licences are module-wide, so no per-site comment is demanded.

local style = require("_tool.lint")
local tl = require("tl")

local type Diagnostic = style.Diagnostic
local type Token = tl.Token

--- The module-level licences: D23 for check, D22 for rand.
local EXEMPT_MODULES < const >: {string: boolean} = {
  ["cosmic/check.tl"] = true,
  ["cosmic/rand.tl"] = true,
}

--- The receivers whose `.exit(` is a process exit.
local EXIT_RECEIVERS < const >: {string: boolean} = {
  ["os"] = true,
  ["unix"] = true,
}

--- One unjustified-site diagnostic in the rules' shared voice.
--- @param file string The path being linted
--- @param t tl.Token The site's first interesting token
--- @param rule string The rule name
--- @param what string What the site does: `error` throws, `exit` exits
--- @param marker string The marker word the site must carry
--- @return Diagnostic
local function unjustified(file: string, t: Token, rule: string,
    what: string, marker: string): Diagnostic
  return {
    file = file,
    line = t.y,
    col = t.x,
    rule = rule,
    message = string.format(
      "%s:%d: a library `%s` needs D30's licence: no caller may be"
      .. " able to receive the value — a require/loader protocol, a"
      .. " process boundary, or a typed contract violated past the"
      .. " checker. Say which, in a trailing `-- %s: <why>` (or on"
      .. " the line above); if a caller COULD receive it, return"
      .. " `nil, err` instead (see `cosmic --docs guide.lint`)",
      file, t.y, what, marker),
  }
end

--- Every library `error(` or `os.exit(`/`unix.exit(` call that does
--- not carry its D30 justification. One diagnostic per line per rule:
--- a line with two such calls takes one comment, as with `-- cast:`.
--- @param file string Path, for the diagnostic
--- @param content string The file's bytes
--- @param lines {string} The file's lines
--- @return {Diagnostic} One per unjustified line
local function check_throw_justification(file: string, content: string,
    lines: {string}): {Diagnostic}
  if not style.is_library_source(file) or EXEMPT_MODULES[file] then
    return {}
  end
  local tokens = tl.lex(content, file)
  if not tokens then
    return {}
  end
  local diagnostics: {Diagnostic} = {}
  local seen: {string: boolean} = {}
  for i, t in ipairs(tokens) do
    local before = i > 1 and tokens[i - 1].tk or ""
    local after = tokens[i + 1]
    if t.kind == "identifier" and after and after.tk == "(" then
      if t.tk == "error" and before ~= "." and before ~= ":"
      and not seen["throw:" .. t.y] then
        seen["throw:" .. t.y] = true
        if not style.is_justified(lines, t.y, "throws") then
          diagnostics[#diagnostics + 1] =
          unjustified(file, t, "throw-justify", "error", "throws")
        end
      elseif t.tk == "exit" and before == "." and i > 1
      and not seen["exit:" .. t.y] then
        local receiver = tokens[i - 2]
        if receiver and receiver.kind == "identifier"
        and EXIT_RECEIVERS[receiver.tk] then
          seen["exit:" .. t.y] = true
          if not style.is_justified(lines, t.y, "exits") then
            diagnostics[#diagnostics + 1] =
            unjustified(file, t, "exit-justify", "exit", "exits")
          end
        end
      end
    end
  end
  return diagnostics
end

local record ThrowLintModule
  check_throw_justification: function(file: string, content: string,
  lines: {string}): {Diagnostic}
end

local M: ThrowLintModule = {
  check_throw_justification = check_throw_justification,
}

return M
