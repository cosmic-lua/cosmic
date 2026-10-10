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

--- What may follow a body to end it in text, as a template must end.
local CLOSERS <const> = { "\">", "'>", ">", "-->", "</textarea>", "</title>", "</script>", "</style>", "</svg>", "" }

--- Refusals of a slot or of a block's arms, so that a draw reaches them
--- whatever else it holds.
local REFUSING <const> = {
  "<a href={{.a}}>", "<script>{{.a}}</script>", "<p onclick=\"{{.a}}\">", "<!-- {{.a}} -->", "<{{.a}}>",
  "<a href=\"/x/{{.a}}\">", "<textarea></textarea{{.a}}>",
}

--- Blocks whose arms end in different places.
local ARMS <const> = { "{{if .a}}<b {{end}}", "{{range .l}}<a title=\"{{end}}", "{{with .w}}<!--{{end}}" }

--- The heads of an `html` template.
local HTML_HEADS <const> = { HEADS[1], HEADS[3] }

--- Actions, well-formed and not, and braces that are not actions.
local ACTIONS <const> = {
  "{{.a}}", "{{.}}", "{{.b.c | m.f}}", "{{.a | m.f | n.g}}", "{{if .a}}", "{{if .a.b | m.f}}", "{{else}}",
  "{{else if .b}}", "{{end}}", "{{range .l}}", "{{with .w}}", "{{- ", " -}}", "{{-", "-}}", "{{ . }}", "{{.end}}",
  "{{", "}}", "{{foo}}", "{{.a..b}}", "{{.a |}}", "{{.a | f}}", "{{}}", '{{"{{"}}', '{{"}}"}}', '{{ "a\\"b\\\\" }}',
  '{{"', '{{"\\q"}}', '{{- "x" -}}', '{{"x" | m.f}}', '{{if "x"}}', '"',
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
local record Kit
  markup: {string}
  slots: {string}
  loose: {string}
end

local SLOTS <const>: {string} = { "{{.a}}", "{{.}}", "{{.b.c | m.f}}", "{{.a | m.f | n.g}}" }

local ANY <const>: Kit = { markup = MARKUP, slots = SLOTS, loose = ACTIONS }

--- Markup that is never refused, so that a draw compiles.
local PLAIN <const>: Kit = {
  markup = { "<p>", "</p>", "text", "<br/>", " ", "\n", "<a href=\"x\">", "</a>", "<b class=\"c\">", "</b>", "é" },
  slots = SLOTS,
  loose = SLOTS,
}

local function gen_nodes(src: Fuzz.Source, depth: integer, out: {string}, kit: Kit)
  while Fuzz.more(src, #out, 14) do
    local kind = src:int(0, 9)
    if kind <= 4 then
      out[#out + 1] = Fuzz.pick(src, kit.markup)
    elseif kind <= 6 then
      out[#out + 1] = Fuzz.pick(src, kit.slots)
    elseif depth >= 3 then
      out[#out + 1] = Fuzz.pick(src, kit.loose)
    elseif kind == 7 then
      out[#out + 1] = "{{if .a}}"
      gen_nodes(src, depth + 1, out, kit)
      if src:int(0, 1) == 0 then
        out[#out + 1] = "{{else if .b}}"
        gen_nodes(src, depth + 1, out, kit)
      end
      if src:int(0, 1) == 0 then
        out[#out + 1] = "{{else}}"
        gen_nodes(src, depth + 1, out, kit)
      end
      out[#out + 1] = "{{end}}"
    elseif kind == 8 then
      out[#out + 1] = "{{range .l}}"
      gen_nodes(src, depth + 1, out, kit)
      out[#out + 1] = "{{end}}"
    else
      out[#out + 1] = "{{with .w}}"
      gen_nodes(src, depth + 1, out, kit)
      if src:int(0, 1) == 0 then
        out[#out + 1] = "{{else}}"
        gen_nodes(src, depth + 1, out, kit)
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
    gen_nodes(src, 0, out, ANY)
    out[#out + 1] = Fuzz.pick(src, CLOSERS)
  end
  return table.concat(out)
end

--- Well-formed nodes, then what ends them in text: no syntax error, so what
--- follows or precedes it is judged for its markup.
local function gen_sound_nodes(src: Fuzz.Source): string
  local out: {string} = {}
  gen_nodes(src, 0, out, ANY)
  out[#out + 1] = Fuzz.pick(src, CLOSERS)
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
  elseif kind == 5 then
    local out: {string} = {}
    gen_nodes(src, 0, out, PLAIN)
    return Fuzz.pick(src, HEADS) .. table.concat(out)
  elseif kind == 2 or kind == 4 then
    return Fuzz.pick(src, HTML_HEADS) .. Fuzz.pick(src, REFUSING) .. gen_sound_nodes(src)
  elseif kind == 3 then
    return Fuzz.pick(src, HTML_HEADS) .. Fuzz.pick(src, ARMS) .. gen_sound_nodes(src)
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
    shares = { compiled = 0.05, syntax = 0.05, slot = 0.01 },
    check = function(input: string): boolean, string
      local ok, out, why = pcall(Template.compile, input, "t.tmpl")
      if not ok then
        return false, "compile raised: " .. tostring(out)
      end
      if input:find("{{range", 1, true) or input:find("{{with", 1, true) or input:find("{{if", 1, true) then
        Fuzz.label("block")
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
        elseif why:find(": the template ends ", 1, true) then
          Fuzz.label("open end")
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
      if out == nil and mode == "html" and why:find(": the template ends ", 1, true) then
        -- Markup left open is refused in html, and rendered as it stands in text.
        Fuzz.label("html")
        head = "{{type T from m.t}}{{mode text}}"
        out, why = Template.compile(head .. body, "t.tmpl")
        mode = "text"
      end
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
      -- What Teal strikes out to leave Lua: the type require and the
      -- annotations, in the one shape a template with no action has.
      local lua = out:gsub("^local type t = require%b() ", "")
      lua = lua:gsub("%(_: t%.T%): [%w%.]+", "()"):gsub("local parts: {string}", "local parts")
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
            not html_why:find(" ends where it did not", 1, true) and
            not html_why:find("could complete a scheme", 1, true) and
            not html_why:find("protocol-relative", 1, true) and
            not html_why:find(": the template ends ", 1, true) then
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

--- Self-contained fragments, each with the kinds its slots must be judged
--- as, in order: `t` text, `r` RCDATA text, `a` attribute, `u` URL, and
--- `x` for one the compiler must refuse. Each leaves the markup in text,
--- so the kinds of a template are those of its fragments, whatever order
--- they come in. What each says about markup is written down here, apart
--- from the tracker, which the property checks against it.
local UNITS <const>: {{string}} = {
  { "<p>{{.a}}</p>", "t" },
  { "<a href=\"{{.a}}\">x</a>", "u" },
  { "<a href='{{.a}}'>x</a>", "u" },
  { "<a href=\"{{.a}}x/y?z:w\">x</a>", "u" },
  { "<a href=\"{{.a}}?/x\">x</a>", "u" },
  { "<a href=\"{{.a}}/x\">x</a>", "x" },
  { "<a href=\"{{.a}}\\x\">x</a>", "x" },
  { "<a href=\"{{.a}}\n/x\">x</a>", "x" },
  { "<a href=\"{{.a}}{{if .a}}{{end}}//x\">x</a>", "x" },
  { "<img lowsrc=\"{{.a}}\">", "u" },
  { "<p title=\"{{.a}}\">x</p>", "a" },
  { "<textarea>{{.a}}</textarea>", "r" },
  { "<title>{{.a}}</title>", "r" },
  { "<svg><textarea>{{.a}}</textarea></svg>", "r" },
  { "<textarea>{{.a}}</textarea>", "r" },
  { "<img alt=\"{{.a}}\" src=\"{{.a}}\">", "au" },
  { "<meta name=\"d\" content=\"{{.a}}\">", "a" },
  { "<meta content=\"{{.a}}\" name=\"d\">", "a" },
  { "<svg><a href=\"{{.a}}\">x</a></svg>", "u" },
  { "<svg><p></svg><textarea>{{.a}}</textarea>", "x" },
  { "<svg><div></div><textarea>{{.a}}</textarea></svg>", "x" },
  { "<select><svg></svg></select><p>{{.a}}</p>", "x" },
  { "<select></select><svg></svg><p>{{.a}}</p>", "t" },
  { "<svg><br></svg>{{.a}}", "x" },
  { "<svg><font size=1></svg>{{.a}}", "x" },
  { "<svg><font></font></svg>{{.a}}", "t" },
  { "<math><svg></math>{{.a}}", "x" },
  { "<math><svg></svg></math>{{.a}}", "t" },
  { "<svg><math></svg>{{.a}}", "x" },
  { "<svg><text>{{.a}}</text></svg>", "t" },
  { "<svg><g><a href=\"{{.a}}\"><path d=\"M0\"/></a></g></svg>", "u" },
  { "<svg><![CDATA[ > <!-- ]]><a href=\" --> {{.a}}\">", "x" },
  { "<svg {{if .a}}/{{end}}><style><a href=\"</style>{{.a}}\">", "x" },
  { "<svg><foreignObject><div></svg></div></foreignObject><style><a href=\"</style>{{.a}}\">", "x" },
  { "<svg><!-- c --></svg>{{.a}}", "x" },
  { "<svg><g></svg>{{.a}}", "x" },
  { "<svg><desc></desc></svg>{{.a}}", "x" },
  { "<math><mi></mi></math>{{.a}}", "x" },
  { "<svg/>{{.a}}", "t" },
  { "<math/><textarea>{{.a}}</textarea>", "r" },
  { "<a href=\"{{if .a}}{{.a}}{{end}}\">x</a>", "u" },
  { "<a title=\"{{range .l}}{{.a}}{{end}}\">x</a>", "a" },
  { "<p {{if .a}}class=\"c\"{{end}}>{{.a}}</p>", "t" },
  { "<a href={{.a}}>", "x" },
  { "<p onclick=\"{{.a}}\">", "x" },
  { "<p style=\"{{.a}}\">", "x" },
  { "<script>{{.a}}</script>", "x" },
  { "<script src=\"{{.a}}\"></script>", "x" },
  { "<link href=\"{{.a}}\">", "x" },
  { "<!-- {{.a}} -->", "x" },
  { "<meta http-equiv=\"refresh\" content=\"{{.a}}\">", "x" },
  { "<meta content=\"{{.a}}\" http-equiv=\"refresh\">", "x" },
  { "<svg><title>{{.a}}</title></svg>", "x" },
  { "<svg><foreignObject>{{.a}}</foreignObject></svg>", "x" },
  { "<svg><set to=\"{{.a}}\"></svg>", "x" },
  { "<iframe>{{.a}}</iframe>", "x" },
  { "<a href=\"{{range .l}}{{.a}}{{end}}\">x</a>", "x" },
  { "<a href=\"{{.a}}:x\">", "x" },
  { "<a href=\"{{.a}}&#58;x\">", "x" },
  { "<svg><textarea><a href=\"{{.a}}\"></textarea></svg>", "x" },
  { "<textarea></textarea{{.a}}><p>x</p>", "x" },
  { "<title><{{.a}}title>", "x" },
  { "<textarea>x < {{.a}}</textarea>", "r" },
  { "<textarea></text{{if .a}}{{end}}area><script>{{.a}}</script></textarea>", "x" },
  { "<script><!--<script>{{if .a}}{{end}}</script>{{.a}}</script>", "x" },
  { "<textarea></text{{if .a}}{{end}}area>{{.a}}", "t" },
}

--- A payload, the kinds its template's slots must be judged as, and a
--- template of fragments, some inside a block.
local function gen_sound(src: Fuzz.Source): string
  local body: {string} = {}
  local kinds: {string} = {}
  local want = Fuzz.pick(src, { "t", "r", "a", "u", "x" })
  local drawn = 0
  -- Only a template drawn to be refused holds a fragment that is, so the kinds
  -- that compile are not starved by one stray refusal in five.
  local sound: {{string}} = {}
  for _, unit in ipairs(UNITS) do
    if unit[2] ~= "x" then
      sound[#sound + 1] = unit
    end
  end
  local pool = want == "x" and UNITS or sound
  while Fuzz.more(src, #body, 5) do
    drawn = drawn + 1
    local first = Fuzz.pick(src, pool)
    if drawn == 1 then
      -- The first fragment is of a kind drawn first, so every kind is reached however few inputs run.
      local of: {{string}} = {}
      for _, unit in ipairs(UNITS) do
        if unit[2]:find(want, 1, true) then
          of[#of + 1] = unit
        end
      end
      first = Fuzz.pick(src, of)
    end
    local wrap = src:int(0, 5)
    if wrap == 1 then
      local second = Fuzz.pick(src, pool)
      body[#body + 1] = "{{if .a}}" .. first[1] .. "{{else}}" .. second[1] .. "{{end}}"
      kinds[#kinds + 1] = first[2] .. second[2]
    else
      local open = wrap == 2 and "{{range .l}}" or wrap == 3 and "{{with .w}}" or ""
      body[#body + 1] = open .. first[1] .. (open ~= "" and "{{end}}" or "")
      kinds[#kinds + 1] = first[2]
    end
  end
  return Fuzz.pack({ Fuzz.pick(src, { "<\"'>& onload=x", "javascript:alert(1)", "\"'\n\t<script>", "/",
    "\\", "/\t" }),
    table.concat(kinds), table.concat(body) })
end

local HELPER_KIND <const>: {string: string} = { _text = "t", _rtext = "r", _attr = "a", _url = "u" }

local function esc(s: any): string
  if not s is string then
    return ""
  end
  return (s:gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&#34;", ["'"] = "&#39;" }))
end

local function esc_attr(s: any): string
  if not s is string then
    return ""
  end
  return (s:gsub("[\0-\47\58-\64\91-\96\123-\127]", function(c: string): string
    return "&#" .. c:byte() .. ";"
  end))
end

--- The core's escapers (cosmic.html), for what they do to bytes, each
--- made value wrapped in marker bytes so a check can tell what came from
--- which: \1 \2 around escaped text, \3 \4 around an attribute value,
--- and \5 ahead of what `href` answered.
local STAND_IN <const>: {string: function} = {
  escape = function(s: any): {string: string} return { s = "\1" .. esc(s) .. "\2" } end,
  escape_attr = function(s: any): {string: string} return { s = "\3" .. esc_attr(s) .. "\4" } end,
  href = function(s: any): {string: string}
    local text = s is string and s or ""
    return { s = "\5" .. (text:lower():find("^%s*javascript:") and "about:invalid" or text) }
  end,
  trust = function(s: string): {string: string} return { s = s } end,
  raw = function(v: {string: string}): string return v.s end,
  raw_attr = function(v: {string: string}): string return v.s end,
  raw_url = function(v: {string: string}): string return v.s end,
}

--- The generated source with Teal's types struck out, in the shapes the
--- generator writes, to run as Lua. Those templates have no stage, so
--- `_one` and its `<T>` are never there to strike.
local function lua_of(source: string): string
  local lua = source:gsub("local type [%w_]+ = require%b() ", "")
  lua = lua:gsub("%(([%a_][%w_]*): [^()]-%)", "(%1)")
  lua = lua:gsub("%): [%w%.]+ ", ") ")
  lua = lua:gsub("local v: [^=]+= ", "local v = ")
  lua = lua:gsub("local parts: {string} = {}", "local parts = {}")
  lua = lua:gsub("if v is (%a+) then", 'if type(v) == "%1" then')
  return lua
end

-- Whatever a template of markup and slots is made of, and whatever a slot
-- is given (markup characters, quotes, a script URL), the output holds no
-- raw `<`, `>`, quote or space of the data in a place it was escaped for,
-- and a slot that is a URL went through `href`.
local function test_a_value_cannot_get_out_of_where_a_slot_puts_it(tmp: string)
  Fuzz.run({
    name = "template sound",
    dir = tmp,
    gen = gen_sound,
    requires = { "refused", "text", "rtext", "attr", "url", "block", "assembled url" },
    shares = { refused = 0.01, text = 0.05, rtext = 0.01, attr = 0.01, url = 0.01 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local payload = fields[1] or ""
      local kinds = fields[2] or ""
      local body = fields[3] or ""
      local source, why = Template.compile("{{type T from m.t}}" .. body, "t.tmpl")
      if kinds:find("x", 1, true) then
        Fuzz.label("refused")
        if source ~= nil then
          return false, "compiled a template with a slot that must be refused (" .. kinds .. "): " .. body
        end
        return true, ""
      end
      if source == nil then
        return false, "refused " .. body .. ": " .. why
      end
      local made_kinds: {string} = {}
      for helper in source:gmatch("parts%[#parts %+ 1%] = (_%a+)%(v%) end") do
        made_kinds[#made_kinds + 1] = HELPER_KIND[helper] or "?"
      end
      if table.concat(made_kinds) ~= kinds then
        return false, "slots judged as " .. table.concat(made_kinds) .. ", not " .. kinds .. ": " .. body
      end
      if kinds:find("r", 1, true) then Fuzz.label("rtext") end
      local env: {string: any} = {
        require = function(name: string): any
          if name == "cosmic.html" then
            return STAND_IN
          end
          return {}
        end,
        table = table,
        ipairs = ipairs,
        tostring = tostring,
        type = type,
      }
      local chunk, trouble = load(lua_of(source), "=module", "t", env)
      if chunk == nil then
        return false, "the module does not load: " .. tostring(trouble) .. "\n" .. lua_of(source)
      end
      local loaded = chunk()
      if not loaded is { string: function({string: any}): {string: string} } then
        return false, "the module exports no render"
      end
      local each: {string: any} = { s = "" }
      setmetatable(each, { __index = function(_: any, key: string): any
        if key == "w" then
          return each
        elseif key == "l" then
          return { each }
        end
        return payload
      end })
      local ok, made = pcall(loaded.render, { a = payload, l = { each, each }, w = each })
      if not ok then
        return false, "render raised: " .. tostring(made) .. "\n" .. lua_of(source)
      end
      local out = made.s
      for piece in out:gmatch("\1([^\2]*)\2") do
        Fuzz.label("text")
        if piece:find("[<>\"']") then
          return false, "markup character in escaped text: " .. piece
        end
      end
      for piece in out:gmatch("\3([^\4]*)\4") do
        Fuzz.label("attr")
        if piece:gsub("&#%d+;", ""):find("[^%w\128-\255]") then
          return false, "a byte that can end a value in: " .. piece
        end
      end
      if out:find("\3&#5;", 1, true) then
        Fuzz.label("url")
        if out:find("\3&#5;javascript", 1, true) then
          return false, "a URL slot began with the script scheme"
        end
      end
      -- Whatever a URL slot is given, the value the browser assembles from
      -- it and the literal text after it (entities decoded, the bytes a URL
      -- parser drops removed) is not protocol-relative, which `href` refuses.
      for value, after in out:gmatch("\3&#5;([^\4]*)\4([^\"']*)") do
        Fuzz.label("assembled url")
        local url = (value .. after):gsub("&#(%d+);", function(n: string): string
          return string.char(tonumber(n) as integer % 256)
        end):gsub("[\t\n\r]", "")
        if url:find("^[/\\][/\\]") then
          return false, "an assembled URL is protocol-relative: " .. url
        end
      end
      if body:find("{{range", 1, true) or body:find("{{if", 1, true) or body:find("{{with", 1, true) then
        Fuzz.label("block")
      end
      return true, ""
    end,
  })
end

--- The pieces of raw text and RCDATA elements and of what ends them, cut
--- short in places so that two of them can complete a tag or a comment
--- between them.
local RAW_PIECES <const> = {
  "<textarea>", "</textarea>", "</text", "area>", "<title>", "</ti", "tle >", "<style>", "</style>", "</sty", "le>",
  "<script>", "</script>", "</scr", "ipt>", "<scr", "ipt ", "<!--", "<!-", "-", "--", ">", "-->", "<", "</", "/", "!", "x",
  " ", "\n", "<svg>", "</svg>", "<p>", "<a href=\"", "\"", "'", "<noscript>", "</noscript>", "</nos", "<!-",
  -- A whole element, so that a cut inside its tags is drawn at default counts.
  "<textarea></textarea><script>", "<title></title><script>", "<style></style><script>",
  "<script><!--<script></script>", "<script><!--<script></script>--></script>", "<script></script><textarea>", "<noscript><!--</noscript>", "<noscript><!-", "--</noscript>",
  "<svg><style></style></svg>",
}

--- The actions that cut a literal run: blocks that emit nothing, one whose
--- arms emit the same text `X`, and string actions that write `X`, each
--- of which reads as `X` put there.
local CUTS <const>: {string} = { "{{if .a}}{{end}}", "{{range .l}}{{end}}", "{{with .a}}{{end}}", "{{if .a}}X{{else}}X{{end}}",
  "S" }

--- `text` written as string actions, one to a line, its newlines outside them.
local function as_strings(text: string): string
  return (text:gsub("[^\n]+", function(line: string): string
    return '{{"' .. line:gsub('[\\"]', "\\%0") .. '"}}'
  end))
end

--- A literal run, how it is cut (an index of `CUTS`) and the text `X` of a
--- cut whose arms emit it.
local function gen_cut(src: Fuzz.Source): string
  local out: {string} = {}
  while Fuzz.more(src, #out, 12) do
    out[#out + 1] = Fuzz.pick(src, RAW_PIECES)
  end
  return Fuzz.pack({ table.concat(out), tostring(src:int(1, #CUTS)), Fuzz.pick(src, RAW_PIECES) })
end

--- The helpers a compiled template calls, in order.
local function helpers(source: string): string
  local out: {string} = {}
  for helper in source:gmatch("parts%[#parts %+ 1%] = (_%a+)%(v%) end") do
    out[#out + 1] = helper
  end
  return table.concat(out, " ")
end

-- A block that emits nothing, or whose arms emit the same text, or a string
-- action, between any two bytes of the literal text, does not change where
-- a slot after it lands: a template that compiles with the cut compiles
-- without it (with the text it emits put there) and gives its slots the
-- same escaping.
-- (Else a value could be escaped for text where the browser reads script,
-- as in `<textarea></text{{if .a}}{{end}}area><script>{{.b}}`.)
--
-- TODO: compare each slot's context with an independent HTML tokenizer
-- reading the rendered output, as #2741 asks, not with this template's own
-- unsplit reading; waits on an HTML parser in the tree that reports the
-- tokenizer state at a given byte (the html5lib tokenizer test holds a
-- reference tokenizer for the data state only).
local function test_a_cut_in_the_text_does_not_move_where_a_slot_lands(tmp: string)
  Fuzz.run({
    name = "template cut",
    dir = tmp,
    gen = gen_cut,
    requires = { "agreed", "cut refused", "raw text", "script slot refused", "range", "with", "arms", "string" },
    shares = { agreed = 0.2, ["raw text"] = 0.3, ["cut refused"] = 0.05, ["script slot refused"] = 0.02 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local literal = fields[1] or ""
      local kind = math.tointeger(tonumber(fields[2])) or 1
      local extra = fields[3] or ""
      local head = "{{type T from m.t}}"
      local tail = "{{.a}}{{.b}}"
      local whole, why = Template.compile(head .. literal .. tail, "t.tmpl")
      if literal:find("<script", 1, true) or literal:find("<textarea", 1, true) or literal:find("<title", 1, true) or
          literal:find("<style", 1, true) then
        Fuzz.label("raw text")
      end
      if whole == nil and why:find("<script>", 1, true) then
        Fuzz.label("script slot refused")
      end
      Fuzz.label(kind == 2 and "range" or kind == 3 and "with" or kind == 4 and "arms" or kind == 5 and "string" or "if")
      local block = kind == 5 and as_strings(extra) or (CUTS[kind]:gsub("X", function(): string
        return extra
      end))
      for cut = 0, #literal do
        local body = literal:sub(1, cut) .. block .. literal:sub(cut + 1) .. tail
        local split = Template.compile(head .. body, "t.tmpl")
        local reference = whole
        if kind >= 4 then
          reference = Template.compile(head .. literal:sub(1, cut) .. extra .. literal:sub(cut + 1) .. tail, "t.tmpl")
        end
        if split == nil then
          Fuzz.label("cut refused")
        elseif reference == nil then
          return false, "compiled with a cut at " .. cut .. " what it refuses whole: " .. body
        elseif helpers(split) ~= helpers(reference) then
          return false, "cut at " .. cut .. " gives " .. helpers(split) .. ", not " .. helpers(reference) .. ": " .. body
        else
          Fuzz.label("agreed")
        end
      end
      return true, ""
    end,
  })
end

--- What may follow a URL slot in a value: text that begins a path, an
--- authority, a scheme or an entity, bytes a URL parser drops, and blocks
--- that emit nothing or something.
local SUFFIX <const> = {
  "/", "\\", "\t", "\n", "\r", "x", "?", "#", "/x", "//", ":", "&", "&#47;", "&sol;", "&bsol;", "&Tab;", ".", "evil",
  "{{if .a}}{{end}}", "{{if .a}}x{{end}}", "{{if .a}}/{{end}}", "{{.b}}", " ",
}

local function gen_suffix(src: Fuzz.Source): string
  local out: {string} = {}
  while Fuzz.more(src, #out, 8) do
    out[#out + 1] = Fuzz.pick(src, SUFFIX)
  end
  return table.concat(out)
end

-- A URL attribute built from a slot and literal text compiles only when the
-- text cannot make the assembled value protocol-relative (`//host`) or
-- complete a scheme, whatever the slot's value: the text, with the blocks
-- struck out and the bytes a URL parser drops removed, begins with neither
-- `/` nor `\`, and holds no `:` or `&` before its first `/`, `?` or `#`.
local function test_a_url_suffix_cannot_make_the_assembled_value_leave_the_policy(tmp: string)
  Fuzz.run({
    name = "template url suffix",
    dir = tmp,
    gen = gen_suffix,
    requires = { "compiled", "refused" },
    shares = { compiled = 0.1, refused = 0.1 },
    check = function(suffix: string): boolean, string
      local body = "<a href=\"{{.u}}" .. suffix .. "\">x</a>"
      local source = Template.compile("{{type T from m.t}}" .. body, "t.tmpl")
      if source == nil then
        Fuzz.label("refused")
        return true, ""
      end
      Fuzz.label("compiled")
      -- Only literal text counts: the arms of a block that emit text are
      -- struck out whole, as the compiler treats them as text of their own.
      local literal = suffix:gsub("{{if %.a}}(.-){{end}}", "%1"):gsub("{{[^}]*}}", ""):gsub("[\t\n\r]", "")
      if literal:find("^[/\\]") then
        return false, "compiled a suffix that begins with a slash: " .. body
      end
      local cut = literal:find("[/?#]")
      if (cut and literal:sub(1, cut - 1) or literal):find("[:&]") then
        return false, "compiled a suffix that could complete a scheme: " .. body
      end
      return true, ""
    end,
  })
end

--- Text with braces, quotes and backslashes in it, cut into runs: each
--- written as it is or as a string action, or a slot. Packed as a kind
--- (`t` text, `q` string, `s` slot) and its text for each run.
local function gen_quoted(src: Fuzz.Source): string
  local fields: {string} = {}
  while Fuzz.more(src, #fields // 2, 12) do
    local kind = Fuzz.pick(src, { "t", "q", "q", "s" })
    local run: {string} = {}
    while kind ~= "s" and Fuzz.more(src, #run, 4) do
      local pick = src:int(0, 4)
      run[#run + 1] = pick == 0 and Fuzz.bytes(src, 3) or
        pick == 1 and Fuzz.pick(src, { "{{", "}}", "{", "\"", "\\", "{{.a}}", "-}}", "{{- ", "|" }) or
        Fuzz.pick(src, MARKUP)
    end
    fields[#fields + 1] = kind
    fields[#fields + 1] = table.concat(run)
  end
  return Fuzz.pack(fields)
end

-- A `text` template renders the bytes its string actions quote, exactly,
-- whatever they hold: braces, quotes, backslashes, newlines (kept outside
-- them), control and high bytes. Where else a string action may cut text
-- is the cut property's to check, against the text whole.
local function test_a_string_action_renders_the_bytes_it_quotes(tmp: string)
  Fuzz.run({
    name = "template string",
    dir = tmp,
    gen = gen_quoted,
    requires = { "brace", "escape", "newline", "slot" },
    shares = { brace = 0.1, escape = 0.1 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local body: {string} = {}
      local want: {string} = {}
      for at = 1, #fields - 1, 2 do
        local kind = fields[at]
        local text = fields[at + 1]
        if kind == "s" then
          Fuzz.label("slot")
          body[#body + 1] = "{{.a}}"
          want[#want + 1] = "P"
        else
          -- A `{` outside a string could start an action with the next one.
          body[#body + 1] = kind == "q" and as_strings(text) or (text:gsub("{", '{{"{"}}'))
          want[#want + 1] = text
          if text:find("{{", 1, true) then Fuzz.label("brace") end
          if text:find('["\\]') then Fuzz.label("escape") end
          if text:find("\n", 1, true) then Fuzz.label("newline") end
        end
      end
      local src = "{{type T from m.t}}{{mode text}}" .. table.concat(body)
      local source, why = Template.compile(src, "t.tmpl")
      if source == nil then
        return false, "refused: " .. why
      end
      if newlines(source) ~= newlines(src) + 1 then
        return false, "the module does not have the template's lines"
      end
      local env: {string: any} = { require = function(_: string): any return {} end, table = table,
        tostring = tostring, type = type }
      local chunk, trouble = load(lua_of(source), "=module", "t", env)
      if chunk == nil then
        return false, "the module does not load: " .. tostring(trouble) .. "\n" .. lua_of(source)
      end
      local loaded = chunk() as {string: function({string: string}): string}
      local made = loaded.render({ a = "P" })
      if made ~= table.concat(want) then
        return false, "rendered " .. string.format("%q", made) .. " for " .. string.format("%q", table.concat(want))
      end
      return true, ""
    end,
  })
end
