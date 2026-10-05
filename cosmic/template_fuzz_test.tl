--- Fuzz properties for [`cosmic.template`], which compiles text it is
--- handed: `compile` is total on any bytes and answers source or a reason
--- that names a line and column; a template with no action compiles to a
--- module that renders its text byte for byte; the two modes agree on what
--- is syntax, and `text` takes whatever `html` does; and the module has
--- the template's lines. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Template = require("cosmic.template")

local HEADS <const> = { "{{type T from m.t}}", "{{type T from m.t}}{{mode text}}", "{{type T from m.t}}\n{{mode html}}\n" }

--- Markup in the states a slot may or may not stand in, and plain text.
local MARKUP <const> = {
  "<p>", "</p>", "<a href=\"", "<a title='", "\"", "'", ">", "<", "</", "<!--", "-->", "--!>", "<!", "<?", "<script>",
  "</script>", "</SCRIPT >", "<style>", "</style>", "<textarea>", "</textarea>", " onclick=\"", " style=\"", " x=",
  " x=y ", "=", "/", " ", "\t", "\r\n", "\n", "text", "&", "é", "\0", "\\", "{", "}", "<img src=\"",
  "<script src=\"", "<meta content=\"", "<TITLE>", "</title>", "<a ", "<a b", "<a b=\"c\"", "<a b=c", "<div class=\"",
  "<a href=\"/x/", "<br/>", "<a href=\"http://h\">",
}

--- Actions, well-formed and not, and braces that are not actions.
local ACTIONS <const> = {
  "{{.a}}", "{{.}}", "{{.b.c | m.f}}", "{{.a | m.f | n.g}}", "{{if .a}}", "{{if .a.b | m.f}}", "{{else}}",
  "{{else if .b}}", "{{end}}", "{{range .l}}", "{{with .w}}", "{{- ", " -}}", "{{-", "-}}", "{{ . }}", "{{.end}}",
  "{{", "}}", "{{foo}}", "{{.a..b}}", "{{.a |}}", "{{.a | f}}", "{{}}",
}

--- What only the first line may hold, which a template that has a type
--- and a mode already must not repeat.
local HEADERS <const> = { "{{type X from y.z}}", "{{mode text}}", "{{mode html}}" }

local SAMPLES <const> = {
  "{{type T from m.t}}\n<p class=\"{{.a}}\">{{.b}}</p>\n{{range .l}}<a href=\"{{.u}}\">{{.n}}</a>{{end}}\n",
  "{{type T from m.t}}{{mode text}}\n{{if .a}}x{{else if .b}}y{{else}}z{{end}}{{- .c -}} \n",
  "{{type T from m.t}}\n<script>var x = 1;</script>{{with .w}}{{.}}{{end}}\n",
}

--- Appends a well-formed run of nodes: markup, slots and blocks (to
--- `depth` deep, the arms of each cut at random places in the markup).
local function gen_nodes(src: Fuzz.Source, depth: integer, out: {string})
  while Fuzz.more(src, #out, 14) do
    local kind = src:int(0, 9)
    if kind <= 4 then
      out[#out + 1] = Fuzz.pick(src, MARKUP)
    elseif kind <= 6 then
      out[#out + 1] = Fuzz.pick(src, { "{{.a}}", "{{.}}", "{{.b.c | m.f}}", "{{.a | m.f | n.g}}" })
    elseif depth >= 3 then
      out[#out + 1] = Fuzz.pick(src, ACTIONS)
    elseif kind == 7 then
      out[#out + 1] = "{{if .a}}"
      gen_nodes(src, depth + 1, out)
      if src:int(0, 1) == 0 then
        out[#out + 1] = "{{else if .b}}"
        gen_nodes(src, depth + 1, out)
      end
      if src:int(0, 1) == 0 then
        out[#out + 1] = "{{else}}"
        gen_nodes(src, depth + 1, out)
      end
      out[#out + 1] = "{{end}}"
    elseif kind == 8 then
      out[#out + 1] = "{{range .l}}"
      gen_nodes(src, depth + 1, out)
      out[#out + 1] = "{{end}}"
    else
      out[#out + 1] = "{{with .w}}"
      gen_nodes(src, depth + 1, out)
      if src:int(0, 1) == 0 then
        out[#out + 1] = "{{else}}"
        gen_nodes(src, depth + 1, out)
      end
      out[#out + 1] = "{{end}}"
    end
  end
end

--- A template body (no `{{type}}` or `{{mode}}`): mostly well-formed
--- nodes, some a run of pieces in any order, some bytes.
local function gen_body(src: Fuzz.Source): string
  local kind = src:int(0, 7)
  local out: {string} = {}
  if kind == 0 then
    return Fuzz.bytes(src, 40)
  elseif kind == 1 then
    while Fuzz.more(src, #out, 30) do
      out[#out + 1] = src:int(0, 7) == 0 and Fuzz.bytes(src, 3) or
        src:int(0, 1) == 0 and Fuzz.pick(src, MARKUP) or Fuzz.pick(src, ACTIONS)
    end
  else
    gen_nodes(src, 0, out)
  end
  return table.concat(out)
end

--- A whole template: a head and a body, or a sample cut and mixed, or
--- the body with a header where none belongs.
local function gen_template(src: Fuzz.Source): string
  local kind = src:int(0, 7)
  if kind == 0 then
    return Fuzz.mutate(src, Fuzz.pick(src, SAMPLES), 4)
  elseif kind == 1 then
    return Fuzz.pick(src, HEADS) .. gen_body(src) .. Fuzz.pick(src, HEADERS) .. gen_body(src)
  end
  return Fuzz.pick(src, HEADS) .. gen_body(src)
end

local function newlines(s: string): integer
  local _, count = s:gsub("\n", "")
  return count
end

--- Whether `reason` names a template, a line and a column.
local function places(reason: string): boolean
  return reason:find("^t%.tmpl:%d+:%d+: ") ~= nil
end

-- Whatever the bytes, `compile` answers module source with the template's
-- lines or a reason that names a place; it never raises, and answers one
-- thing each time.
local function test_compile_is_total_and_keeps_the_lines_on_any_bytes(tmp: string)
  Fuzz.run({
    name = "template total",
    dir = tmp,
    gen = gen_template,
    requires = { "compiled", "syntax", "slot", "arms", "block", "text mode", "multiline" },
    shares = { compiled = 0.1, syntax = 0.05, slot = 0.05 },
    check = function(input: string): boolean, string
      local ok, out, why = pcall(Template.compile, input, "t.tmpl")
      if not ok then
        return false, "compile raised: " .. tostring(out)
      end
      local again = Template.compile(input, "t.tmpl")
      if again ~= out then
        return false, "compile answered differently the second time"
      end
      if out == nil then
        if not places(why) then
          return false, "no place in: " .. why
        end
        if why:find(": a slot ", 1, true) then
          Fuzz.label("slot")
        elseif why:find(" end in different places", 1, true) or why:find(" ends where it did not", 1, true) then
          Fuzz.label("arms")
        else
          Fuzz.label("syntax")
        end
        return true, ""
      end
      Fuzz.label("compiled")
      if newlines(out) ~= newlines(input) + 1 then
        return false, "the module has " .. newlines(out) .. " newlines for the template's " .. newlines(input)
      end
      if out:find("\r", 1, true) or not out:find("end return {render = render}\n", 1, true) then
        return false, "the module is not shaped as one: " .. out
      end
      if out:find("render(d: ", 1, true) and out:find("local parts: {string} = {} ", 1, true) == nil then
        return false, "no parts"
      end
      if input:find("{{range", 1, true) or input:find("{{with", 1, true) or input:find("{{if", 1, true) then
        Fuzz.label("block")
      end
      if input:find("{{mode text}}", 1, true) then Fuzz.label("text mode") end
      if input:find("\n.*{{") then Fuzz.label("multiline") end
      return true, ""
    end,
  })
end

--- Text with no action in it, drawn from what quoting must not lose.
local function gen_literal(src: Fuzz.Source): string
  local parts: {string} = { Fuzz.pick(src, { "html", "text" }) }
  local text: {string} = {}
  while Fuzz.more(src, #text, 30) do
    text[#text + 1] = src:int(0, 3) == 0 and Fuzz.bytes(src, 4) or Fuzz.pick(src, MARKUP)
  end
  local joined = table.concat(text)
  while joined:find("{{", 1, true) do
    joined = joined:gsub("{{", "{ {")
  end
  parts[2] = joined
  return Fuzz.pack(parts)
end

-- A template with no action renders its text, byte for byte, whatever the
-- bytes: the module, with its types struck out, is run.
local function test_literal_text_is_rendered_byte_for_byte(tmp: string)
  Fuzz.run({
    name = "template literal",
    dir = tmp,
    gen = gen_literal,
    requires = { "newline", "quote", "control", "high byte", "html", "text" },
    shares = { newline = 0.1, quote = 0.2, html = 0.3, text = 0.3 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local mode = fields[1] or "html"
      local body = fields[2] or ""
      local head = mode == "text" and "{{type T from m.t}}{{mode text}}" or "{{type T from m.t}}"
      local out, why = Template.compile(head .. body, "t.tmpl")
      if out == nil then
        return false, "refused text with no action: " .. why
      end
      if newlines(out) ~= newlines(body) + 1 then
        return false, "lines: " .. newlines(out) .. " for " .. newlines(body)
      end
      Fuzz.label(mode)
      if body:find("\n", 1, true) then Fuzz.label("newline") end
      if body:find('["\\\\]') then Fuzz.label("quote") end
      if body:find("[%c]") then Fuzz.label("control") end
      if body:find("[\128-\255]") then Fuzz.label("high byte") end
      -- What Teal strikes out to leave Lua: the annotations, in the one
      -- shape a template with no action has.
      local lua = out:gsub("%(_: t%.T%): [%w%.]+", "()"):gsub("local parts: {string}", "local parts")
      local env: {string: any} = {
        require = function(name: string): any
          if name == "cosmic.html" then
            return { trust = function(s: string): string return s end }
          end
          return {}
        end,
        table = table,
      }
      local chunk, trouble = load(lua, "=module", "t", env)
      if chunk == nil then
        return false, "the module does not load: " .. tostring(trouble) .. "\n" .. lua
      end
      local loaded = chunk()
      if not loaded is {string: function(): string} then
        return false, "the module exports no render"
      end
      local rendered = loaded.render()
      if rendered ~= body then
        return false, "rendered " .. string.format("%q", rendered) .. " for " .. string.format("%q", body)
      end
      return true, ""
    end,
  })
end

-- The two modes read the same syntax: what `html` compiles, `text` does,
-- with the same lines; and a template `text` refuses, `html` does, for
-- the same reason (a slot's or a branch's refusal comes only from `html`).
local function test_modes_agree_on_syntax_and_text_takes_what_html_does(tmp: string)
  Fuzz.run({
    name = "template modes",
    dir = tmp,
    gen = gen_body,
    requires = { "both refuse", "html refuses", "both compile" },
    shares = { ["both compile"] = 0.1, ["html refuses"] = 0.03, ["both refuse"] = 0.05 },
    check = function(input: string): boolean, string
      local as_html, html_why = Template.compile("{{type T from m.t}}" .. input, "t.tmpl")
      local as_text, text_why = Template.compile("{{type T from m.t}}{{mode text}}" .. input, "t.tmpl")
      if as_html ~= nil then
        Fuzz.label("both compile")
        if as_text == nil then
          return false, "text refused what html took: " .. text_why
        end
        if newlines(as_html) ~= newlines(as_text) then
          return false, "the two modes' modules have different lines"
        end
      elseif as_text ~= nil then
        Fuzz.label("html refuses")
        if not html_why:find(": a slot ", 1, true) and not html_why:find(" end in different places", 1, true) and
            not html_why:find(" ends where it did not", 1, true) then
          return false, "html refused what text takes, and not for its markup: " .. html_why
        end
      else
        Fuzz.label("both refuse")
        if not places(html_why) or not places(text_why) then
          return false, "no place: " .. html_why .. " / " .. text_why
        end
      end
      return true, ""
    end,
  })
end
