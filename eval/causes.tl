--- What the checker's refusals of the agent's snippets come from, and which names the model guessed that do not
--- exist: the two reads [`eval/agent`]'s report makes of a refused run's text.
---
--- A refusal is a text of lines `run.tl:LINE:COL: MESSAGE (CODE): FIX`. The code says what rule was broken, and
--- hides the cause: one code (`alternatives_as_value`) is a call used as a value in one snippet and `Json.get(x)!` in
--- another, and only the second is a language rule too narrow. [`Causes.of`] reads the code and the message, and
--- names a cause and the layer whose change would remove it:
---
--- - `lang`: a rule of the language or checker, where a better rule, narrowing or message would help every program
---   (`cosmic -e` and files too), not the agent alone.
--- - `stdlib`: a name or shape the standard library lacks, so a function, an alias or a better hint would remove it.
--- - `prompt`: the language and the stdlib are as they should be, and only the wording of the run text prevents it.
--- - `untagged`: no rule names it yet; the report lists it by its code so that a rule can be added.
---
--- The tag is a judgment, held in [`RULES`] with the reason beside each rule: change a rule when a cause is traced
--- further. A cause is counted once for each refused snippet.
local record Causes
  --- The layer a cause is removed in.
  enum Tag
    --- A rule of the language or checker.
    "lang"
    --- A name or shape the standard library lacks.
    "stdlib"
    --- Wording of the run text.
    "prompt"
    --- No rule names the cause.
    "untagged"
  end

  --- A cause: its name, and the layer it is removed in.
  record Cause
    name: string
    tag: Tag
  end

  --- A finding of a refusal: the checker's code, its message, and the cause the code and the message give.
  record Finding
    code: string
    message: string
    cause: Cause
  end
end

local type Tag = Causes.Tag
local type Cause = Causes.Cause
local type Finding = Causes.Finding

--- One rule: the code it holds for, the text the message must hold (plain, any when nil), the cause it names.
local record Rule
  code: string
  says?: string
  name: string
  tag: Tag
end

--- Rules, first match first. A code with no rule here, but that the lexer or parser reports, is a `prompt` cause
--- (a Lua habit the language does not have); any other is `untagged`.
local RULES <const>: {Rule} = {
  -- `!` is `assert`, so a call whose first value may be `false` (a Json.Value) is refused: lang-bang-nil-only.
  { code = "alternatives_as_value", says = "`assert` tells none", name = "`!` on a call whose first value may be false",
    tag = "lang" },
  -- A call that fails with a Failure has no form that raises where the model wants a value.
  { code = "alternatives_as_value", name = "a call that may fail used as a value", tag = "stdlib" },
  { code = "failure_ignored", name = "a failing call dropped as a statement", tag = "prompt" },
  -- The language reads an index and an optional as maybe nil; the models write the plain form.
  { code = "index_may_be_nil", name = "an index read may be nil", tag = "lang" },
  { code = "nil_not_allowed", name = "an optional used where its value is wanted", tag = "lang" },
  { code = "condition_type", name = "a condition that is neither boolean nor optional", tag = "lang" },
  -- A name the model made up.
  { code = "field_unknown", name = "a function or field the stdlib lacks", tag = "stdlib" },
  { code = "require_unknown", name = "a module the stdlib lacks", tag = "stdlib" },
  { code = "unknown_variable", says = "is used before", name = "a name used above its declaration", tag = "prompt" },
  { code = "unknown_variable", says = "require its module", name = "a stdlib module used without `require`",
    tag = "prompt" },
  { code = "unknown_variable", name = "a name that is declared nowhere", tag = "stdlib" },
  -- Documented in the run text.
  { code = "view_written", name = "a collection written that is not declared `mut`", tag = "prompt" },
  { code = "view_as_mut", name = "a collection passed as `mut` that is not", tag = "prompt" },
  { code = "map_field", name = "a record read or written as a map", tag = "prompt" },
  { code = "record_index", name = "a record read or written as a map", tag = "prompt" },
  { code = "record_as_map", name = "a record read or written as a map", tag = "prompt" },
  { code = "compare_disjoint", name = "a comparison of types that cannot meet", tag = "prompt" },
  { code = "and_ternary", name = "`a and b or c` as a conditional", tag = "prompt" },
  { code = "or_mix", name = "`or` mixed with another type", tag = "prompt" },
  { code = "concat_type", name = "a non-string joined with `..`", tag = "prompt" },
  { code = "operand_type", name = "an operator on the wrong type", tag = "prompt" },
  { code = "arity", name = "a call with the wrong number of arguments", tag = "prompt" },
  { code = "overload_none", name = "no overload of a function fits the call", tag = "prompt" },
  { code = "not_assignable", name = "a value of the wrong type", tag = "prompt" },
  { code = "cannot_infer", name = "a type the checker cannot infer", tag = "prompt" },
  { code = "literal_missing", name = "a record literal that lacks a field", tag = "prompt" },
}

--- Codes of the lexer and the parser (but for the scopes' `unknown_variable`): the text is not the language.
local SYNTAX <const>: {string: boolean} = {
  label_or_goto = true, long_comment = true, unterminated_long_comment = true, digit_separator = true,
  hex_float = true, malformed_number = true, unterminated_string = true, unterminated_long_string = true,
  bad_escape = true, stray_byte = true, semicolon = true, reserved_word = true, nil_union = true,
  method_in_record = true, continue_outside_loop = true, break_outside_loop = true, continue_skips_local = true,
  unclosed = true, expected_token = true, expected_name = true, expected_expression = true, expected_type = true,
  unexpected_token = true, not_a_statement = true, bad_target = true, statement_after_return = true,
  chained_optional = true, chained_is = true, is_union = true, bare_function = true, bare_declaration = true,
  function_path = true, global_in_program = true, if_needs_else = true, trailing_comma = true,
  arm_on_same_line = true, unknown_type = true, shadows = true, const_assigned = true,
}

--- True where the finding's owner is a module (`Json`, [`cosmic.fs`]), not a value or record of the snippet's own:
--- `text` starts "`Owner` has no field ...", and an owner is a module's name where it is capitalised with a small letter
--- after it, or starts `cosmic.`.
function Causes.of_module(text: string): boolean
  local owner = text:match("^`([^`]+)` has no field")
  if owner == nil then return false end
  return owner:find("^%u%l[%w_]*$") ~= nil or owner:find("^cosmic%.") ~= nil
end

--- The cause of a refusal with `code`, whose line (after its place) is `text`: the message, the code and the fix.
function Causes.of(code: string, text: string): Cause
  if code == "field_unknown" and not Causes.of_module(text) then
    return { name = "a field of the program's own value that is not there", tag = "prompt" }
  end
  for _, rule in ipairs(RULES) do
    local says = rule.says
    if rule.code == code and (says == nil or text:find(says, 1, true) ~= nil) then
      return { name = rule.name, tag = rule.tag }
    end
  end
  if SYNTAX[code] == true then
    return { name = "a Lua habit the parser refuses", tag = "prompt" }
  end
  return { name = "other: " .. code, tag = "untagged" }
end

--- The findings of the text of a refusal, in order. A line `FILE:LINE[:COL]: MESSAGE (CODE): FIX` is one; the
--- closing line `FILE: N errors of CODE ...` is not.
function Causes.findings(text: string): {Finding}
  local found: mut {Finding} = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local rest = line:match("^[%w_.%-]+:%d+:[%d:]* (.*)$")
    local message, code = (rest or ""):match("^(.-) %(([%l_]+)%):")
    if rest ~= nil and message ~= nil and code ~= nil then
      found[#found + 1] = { code = code, message = message, cause = Causes.of(code, rest) }
    end
  end
  return found
end

--- The name a model tried that does not exist, as "NAME (CODE)", or nil: from a finding of `field_unknown`
--- (`Json.nothere`), `require_unknown` (`cosmic.nothere`) or `unknown_variable` (`foo`).
function Causes.guess(found: Finding): string?
  local code, message = found.code, found.message
  if code == "field_unknown" then
    local owner, field = message:match("^`([^`]+)` has no field `([^`]+)`")
    if owner ~= nil and field ~= nil and Causes.of_module(message) then
      return owner .. "." .. field .. " (" .. code .. ")"
    end
  elseif code == "require_unknown" then
    local module = message:match("has no module `([^`]+)`")
    if module ~= nil then return module .. " (" .. code .. ")" end
  elseif code == "unknown_variable" then
    local name = message:match("^`([^`]+)` is not declared")
    if name ~= nil then return name .. " (" .. code .. ")" end
  end
  return nil
end

return Causes
