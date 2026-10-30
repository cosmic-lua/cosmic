--- Fuzz properties for [`cosmic.template`], which compiles text it is
--- handed: `compile` is total on any bytes and answers source or a reason
--- that names a line and column; a template with no action compiles to a
--- module that renders its text byte for byte; the two modes agree on what
--- is syntax, and `text` takes whatever `html` does; and the module has
--- the template's lines. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Html = require("cosmic.html")
local Json = require("cosmic.json")
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
  "{{$}}", "{{$.a}}", "{{$x}}", "{{$x.a | m.f}}", "{{range $x := .l}}", "{{range $i, $x := .l}}", "{{range $ := .l}}",
  "{{with $x := .w}}", "{{$x := .a}}", "{{range $i $x := .l}}", ",", ":=", "{{$.}}", "{{$1}}",
}

--- What only the first line may hold, which a template that has a type
--- and a mode already must not repeat.
local HEADERS <const> = { "{{type X from y.z}}", "{{mode text}}", "{{mode html}}" }

local SAMPLES <const> = {
  "{{type T from m.t}}\n<p class=\"{{.a}}\">{{.b}}</p>\n{{range .l}}<a href=\"{{.u}}\">{{.n}}</a>{{end}}\n",
  "{{type T from m.t}}{{mode text}}\n{{if .a}}x{{else if .b}}y{{else}}z{{end}}{{- .c -}} \n",
  "{{type T from m.t}}\n<script>var x = 1;</script>{{with .w}}{{.}}{{end}}\n",
}

--- What [`gen_nodes`] draws from: markup, slots, and the actions drawn
--- in place of a block below the deepest.
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

--- A slot whose value starts from `$` or from a variable of `bound`.
local function gen_variable_slot(src: Fuzz.Source, bound: {string}): string
  local heads: mut {string} = { "$", "$.a" }
  for _, name in ipairs(bound) do
    heads[#heads + 1] = name
    heads[#heads + 1] = name .. ".a"
  end
  local slot = "{{" .. Fuzz.pick(src, heads)
  return slot .. (if src:int(0, 2) == 0 then " | m.f}}" else "}}" end)
end

--- The variables `{{range}}` at `depth` binds, none, one or two, named for
--- the depth so that a nested range never binds a name already seen.
local function gen_bindings(src: Fuzz.Source, depth: integer): {string}
  local kind = src:int(0, 2)
  if kind == 0 then
    return {}
  elseif kind == 1 then
    return { "$x" .. tostring(depth) }
  end
  return { "$i" .. tostring(depth), "$x" .. tostring(depth) }
end

--- Appends a well-formed run of nodes: markup, slots and blocks (to
--- `depth` deep, the arms of each cut at random places in the markup), in
--- which the variables of `bound` are seen.
local function gen_nodes(src: Fuzz.Source, depth: integer, out: mut {string}, kit: Kit, bound: {string})
  while Fuzz.more(src, #out, 14) do
    local kind = src:int(0, 9)
    if kind <= 4 then
      table.insert(out, Fuzz.pick(src, kit.markup))
    elseif kind <= 6 then
      table.insert(out, src:int(0, 3) == 0 and gen_variable_slot(src, bound) or Fuzz.pick(src, kit.slots))
    elseif depth >= 3 then
      table.insert(out, Fuzz.pick(src, kit.loose))
    elseif kind == 7 then
      out[#out + 1] = "{{if .a}}"
      gen_nodes(src, depth + 1, out, kit, bound)
      if src:int(0, 1) == 0 then
        out[#out + 1] = "{{else if .b}}"
        gen_nodes(src, depth + 1, out, kit, bound)
      end
      if src:int(0, 1) == 0 then
        out[#out + 1] = "{{else}}"
        gen_nodes(src, depth + 1, out, kit, bound)
      end
      out[#out + 1] = "{{end}}"
    elseif kind == 8 then
      local names = gen_bindings(src, depth)
      local inner: mut {string} = { table.unpack(bound) }
      for _, name in ipairs(names) do
        inner[#inner + 1] = name
      end
      table.insert(out, if #names == 0 then "{{range .l}}" else "{{range " .. table.concat(names, ", ") .. " := .l}}" end)
      gen_nodes(src, depth + 1, out, kit, inner)
      if src:int(0, 1) == 0 then
        out[#out + 1] = "{{else}}"
        gen_nodes(src, depth + 1, out, kit, bound)
      end
      out[#out + 1] = "{{end}}"
    else
      out[#out + 1] = "{{with .w}}"
      gen_nodes(src, depth + 1, out, kit, bound)
      if src:int(0, 1) == 0 then
        out[#out + 1] = "{{else}}"
        gen_nodes(src, depth + 1, out, kit, bound)
      end
      out[#out + 1] = "{{end}}"
    end
  end
end

--- A template body (no `{{type}}` or `{{mode}}`): mostly well-formed
--- nodes, some a run of pieces in any order, some bytes.
local function gen_body(src: Fuzz.Source): string
  local kind = src:int(0, 7)
  local out: mut {string} = {}
  if kind == 0 then
    return Fuzz.bytes(src, 40)
  elseif kind == 1 then
    while Fuzz.more(src, #out, 30) do
      out[#out + 1] = src:int(0, 7) == 0 and Fuzz.bytes(src, 3) or
        src:int(0, 1) == 0 and Fuzz.pick(src, MARKUP) or Fuzz.pick(src, ACTIONS)
    end
  else
    gen_nodes(src, 0, out, ANY, {})
    table.insert(out, Fuzz.pick(src, CLOSERS))
  end
  return table.concat(out)
end

--- Well-formed nodes, then what ends them in text: no syntax error, so what
--- follows or precedes it is judged for its markup.
local function gen_sound_nodes(src: Fuzz.Source): string
  local out: mut {string} = {}
  gen_nodes(src, 0, out, ANY, {})
  table.insert(out, Fuzz.pick(src, CLOSERS))
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
    local out: mut {string} = {}
    gen_nodes(src, 0, out, PLAIN, {})
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
    requires = { "compiled", "syntax", "slot", "arms", "block", "text mode", "multiline", "bound" },
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
        return false, "the module has " .. tostring(newlines(out)) .. " newlines for the template's " .. tostring(newlines(input))
      end
      if out:find("\r", 1, true) or not out:find("local _module: _Module = {render = render} return _module\n", 1, true) then
        return false, "the module is not shaped as one: " .. out
      end
      if out:find("render(d: ", 1, true) and out:find("local parts: mut {string} = {} ", 1, true) == nil then
        return false, "no parts"
      end
      if input:find("{{mode text}}", 1, true) then Fuzz.label("text mode") end
      if input:find("\n.*{{") then Fuzz.label("multiline") end
      -- `{{` always starts an action, so this is never literal text, and a
      -- range that opens so compiles only as one that binds.
      if input:find("{{range %$[%a_][%w_]*%s*[,:]") then Fuzz.label("bound") end
      return true, ""
    end,
  })
end

--- Text with no action in it, drawn from what quoting must not lose.
local function gen_literal(src: Fuzz.Source): string
  local parts: mut {string} = { Fuzz.pick(src, { "html", "text" }) }
  local text: mut {string} = {}
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
      local head = if mode == "text" then "{{type T from m.t}}{{mode text}}" else "{{type T from m.t}}" end
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
        return false, "lines: " .. tostring(newlines(out)) .. " for " .. tostring(newlines(body))
      end
      Fuzz.label(mode)
      if body:find("\n", 1, true) then Fuzz.label("newline") end
      if body:find('["\\\\]') then Fuzz.label("quote") end
      if body:find("[%c]") then Fuzz.label("control") end
      if body:find("[\128-\255]") then Fuzz.label("high byte") end
      -- What Teal strikes out to leave Lua: the type require and the
      -- annotations, in the one shape a template with no action has.
      local lua = out:gsub("^local type t = require%b() ", "")
      lua = lua:gsub("%(_: t%.T%): [%w%.]+", "()"):gsub("local parts: mut {string}", "local parts")
      lua = lua:gsub("local record _Module .- end local _module: _Module =", "local _module =")
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
            not html_why:find(" reads differently after each", 1, true) and
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
--- as, in order: `t` text, `r` RCDATA text, `f` text inside `<svg>`,
--- `<math>` or `<select>`, `a` attribute, `u` URL, `p` a piece of a URL
--- after text that fixes it, and
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
  { "<a href=\"/i/{{.a}}\">x</a>", "p" },
  { "<a href='/s?q={{.a}}&r={{.a}}#{{.a}}'>x</a>", "ppp" },
  { "<a href=\"/i/{{.a}}{{.a}}\">x</a>", "pp" },
  { "<a href=\"{{.a}}x/{{.a}}\">x</a>", "x" },
  { "<a href=\"{{.a}}x?{{.a}}\">x</a>", "up" },
  { "<a href=\"{{.a}}#{{.a}}\">x</a>", "up" },
  { "<a href=\"{{.a}}{{.a}}\">x</a>", "x" },
  { "<a href=\"{{.a}}x{{.a}}\">x</a>", "x" },
  { "<a href=\"{{.a}}{{if .a}}?{{end}}{{.a}}\">x</a>", "x" },
  { "<a href=\"https://h.example/{{.a}}\">x</a>", "p" },
  { "<a href=\"mailto:{{.a}}\">x</a>", "p" },
  { "<a href=\"?q={{range .l}}{{.a}}{{end}}\">x</a>", "p" },
  { "<a href=\"{{if .a}}/x/{{else}}/y?{{end}}{{.a}}\">x</a>", "p" },
  { "<img src=\"/i/{{.a}}.png\" alt=\"{{.a}}\">", "pa" },
  { "<a href=\"java{{.a}}\">x</a>", "x" },
  { "<a href=\"j{{if .a}}ava{{end}}{{.a}}\">x</a>", "x" },
  { "<a href=\" x{{.a}}\">x</a>", "x" },
  { "<a href=\"https://{{.a}}\">x</a>", "x" },
  { "<a href=\"//{{.a}}\">x</a>", "x" },
  { "<a href=\"javascript:{{.a}}\">x</a>", "x" },
  { "<a href=\"&#106;avascript:{{.a}}\">x</a>", "x" },
  { "<a href=\"/v1.{{.a}}\">x</a>", "p" },
  { "<a href=\"/a/.{{.a}}\">x</a>", "x" },
  { "<a href=\"/a/.%2e{{.a}}\">x</a>", "x" },
  { "<a href=\"/a/%2E%2e{{.a}}\">x</a>", "x" },
  { "<a href=\"/a/%2e{{.a}}\">x</a>", "x" },
  { "<a href=\"/a/%2{{.a}}\">x</a>", "x" },
  { "<a href=\"/a/{{if .a}}.{{else}}%2e{{end}}{{.a}}\">x</a>", "x" },
  { "<a href=\"/a/{{.a}}{{if .a}}.{{end}}{{.a}}\">x</a>", "x" },
  { "<a href=\"/a/.{{.a}}{{.a}}\">x</a>", "x" },
  { "<a href=\"/a/%2e%2e%2e{{.a}}\">x</a>", "p" },
  { "<a href=\"/{{.a}}&sol;{{.a}}\">x</a>", "x" },
  { "<a href=\"/{{.a}}&#47;{{.a}}\">x</a>", "x" },
  { "<a href=\"/{{.a}}&bsol;{{.a}}\">x</a>", "x" },
  { "<a href=\"/{{.a}}&#x5c;{{.a}}\">x</a>", "x" },
  { "<a href=\"/{{.a}}&Tab;/{{.a}}\">x</a>", "x" },
  { "<a href=\"/{{.a}}&NewLine;/{{.a}}\">x</a>", "x" },
  { "<a href=\"/&sol;{{.a}}\">x</a>", "x" },
  { "<a href=\"/&#9;/{{.a}}\">x</a>", "x" },
  { "<a href=\"http:&sol;/{{.a}}\">x</a>", "x" },
  { "<a href=\"http:&#47;&#47;{{.a}}\">x</a>", "x" },
  { "<a href=\"/a/&#46;&#46;{{.a}}\">x</a>", "x" },
  { "<a href=\"/a/&period;{{.a}}\">x</a>", "x" },
  { "<a href=\"{{if .a}}/x{{else}}/&sol;{{end}}{{.a}}\">x</a>", "x" },
  { "<a href=\"/s?a=1&amp;b={{.a}}\">x</a>", "p" },
  { "<a href=\"/s#&sol;{{.a}}\">x</a>", "p" },
  { "<a href=\"/%{{.a}}\">x</a>", "x" },
  { "<a hx-on:click=\"{{.a}}\">x</a>", "x" },
  { "<a data-hx-on-click=\"{{.a}}\">x</a>", "x" },
  { "<a hx-vars=\"{{.a}}\">x</a>", "x" },
  { "<a hx-vals=\"{{.a}}\">x</a>", "x" },
  { "<a hx-headers=\"{{.a}}\">x</a>", "x" },
  { "<a data-hx-request=\"{{.a}}\">x</a>", "x" },
  { "<a HX-TRIGGER=\"{{.a}}\">x</a>", "x" },
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
  { "<svg><text>{{.a}}</text></svg>", "f" },
  { "<math>{{.a}}</math>", "f" },
  { "<select><option>{{.a}}</option></select>", "f" },
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
  local body: mut {string} = {}
  local kinds: mut {string} = {}
  local want = Fuzz.pick(src, { "t", "r", "f", "a", "u", "p", "x" })
  local drawn = 0
  -- Only a template drawn to be refused holds a fragment that is, so the kinds
  -- that compile are not starved by one stray refusal in five.
  local sound: mut {{string}} = {}
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
      local of: mut {{string}} = {}
      for _, unit in ipairs(UNITS) do
        if unit[2]:find(want, 1, true) then
          of[#of + 1] = unit
        end
      end
      first = Fuzz.pick(src, of)
    end
    local wrap = src:int(0, 5)
    -- A slot reads `.a` of dot, `$` (the render argument) or the element a
    -- range binds, which all hold the payload.
    local first_text = first[1]
    local head = "{{range .l}}"
    if (wrap == 2 or wrap == 4) and src:int(0, 1) == 0 then
      head = if src:int(0, 1) == 0 then "{{range $x := .l}}" else "{{range $i, $x := .l}}" end
      first_text = (first_text:gsub("{{%.a}}", "{{$x.a}}"))
    elseif src:int(0, 2) == 0 then
      first_text = (first_text:gsub("{{%.a}}", "{{$.a}}"))
    end
    if wrap == 1 or wrap == 4 then
      local second = Fuzz.pick(src, pool)
      local open = if wrap == 1 then "{{if .a}}" else head end
      body[#body + 1] = open .. first_text .. "{{else}}" .. second[1] .. "{{end}}"
      kinds[#kinds + 1] = first[2] .. second[2]
    else
      local open = wrap == 2 and head or wrap == 3 and "{{with .w}}" or ""
      body[#body + 1] = open .. first_text .. (if open ~= "" then "{{end}}" else "" end)
      kinds[#kinds + 1] = first[2]
    end
  end
  return Fuzz.pack({ Fuzz.pick(src, { "<\"'>& onload=x", "javascript:alert(1)", "\"'\n\t<script>", "/",
    "\\", "/\t", ".", "..", "%2e", "a b/c?d#e&f=g:h@i", "", ".evil.example", "&sol;", "/evil.example",
    "https://api.example.com|.evil.example", "http:|.evil.example", "https:/|.evil.example",
    "https://api.example.com|/evil.example", "https://api.example.com|%2e%2e" }),
    table.concat(kinds), table.concat(body) })
end

local HELPER_KIND <const>: {string: string} = { _text = "t", _rtext = "r", _ftext = "f", _attr = "a", _url = "u", _part = "p" }

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

local record PartRun
  mut calls: integer
  mut only: integer
  mut skip: integer
end

--- Which `url_part` calls of a render answer their value: the `calls` so
--- far, and with `only` set, only that call; with `skip`, all but that one.
local PART_RUN: PartRun = { calls = 0, only = 0, skip = 0 }

--- The core's escapers (cosmic.html), for what they do to bytes, each
--- made value wrapped in marker bytes so a check can tell what came from
--- which: \1 \2 around escaped text, \3 \4 around an attribute value,
--- and \5 ahead of what `href` answered. A payload `A|B` is `A` to a
--- whole-URL slot and `B` to a part, as a template given an origin in one
--- slot and a hostile value in another.
local STAND_IN <const>: {string: function(any): any} = {
  escape = function(s: any): {string: string} return { s = "\1" .. esc(s) .. "\2" } end,
  escape_attr = function(s: any): {string: string} return { s = "\3" .. esc_attr(s) .. "\4" } end,
  href = function(s: any): {string: string}
    local text = s is string and s:match("^[^|]*") or ""
    return { s = "\5" .. (if text:lower():find("^%s*javascript:") then "about:invalid" else text end) }
  end,
  trust = function(s: any): {string: string}
    if not s is string then error("trust: a string is expected, got " .. type(s), 2) end
    return { s = s }
  end,
  -- The bytes of the escaped part between \6 and \7: only unreserved ones
  -- and %XX, except that a whole `.` or `..` is written with its `%` escaped.
  url_part = function(s: any): {string: string}
    local text = tostring(s):match("[^|]*$")
    PART_RUN.calls = PART_RUN.calls + 1
    if PART_RUN.only > 0 and PART_RUN.calls ~= PART_RUN.only or PART_RUN.skip == PART_RUN.calls then
      text = ""
    end
    if text == "." or text == ".." then
      return { s = "\6" .. text:gsub("%.", "%%252E") .. "\7" }
    end
    return { s = "\6" .. text:gsub("[^%w%-._~]", function(c: string): string
      return string.format("%%%02X", c:byte())
    end) .. "\7" }
  end,
  raw_url_part = function(v: any): string
    if not v is {string: string} then
      error("raw_url_part: a made value is expected, got " .. type(v), 2)
    end
    return v.s
  end,
  raw = function(v: any): string
    if not v is {string: string} then
      error("raw: a made value is expected, got " .. type(v), 2)
    end
    return v.s
  end,
  raw_attr = function(v: any): string
    if not v is {string: string} then
      error("raw_attr: a made value is expected, got " .. type(v), 2)
    end
    return v.s
  end,
  raw_url = function(v: any): string
    if not v is {string: string} then
      error("raw_url: a made value is expected, got " .. type(v), 2)
    end
    return v.s
  end,
}

--- The generated source with Teal's types struck out, in the shapes the
--- generator writes, to run as Lua. Those templates have no stage, so
--- `_one` and its `<T>` are never there to strike.
local function lua_of(source: string): string
  local lua = source:gsub("local type [%w_]+ = require%b() ", "")
  lua = lua:gsub("%(([%a_][%w_]*): [^()]-%)", "(%1)")
  lua = lua:gsub("%): [%w%.]+ ", ") ")
  lua = lua:gsub("local v: [^=]+= ", "local v = ")
  lua = lua:gsub("local p: [%w%.]+ ", "local p ")
  lua = lua:gsub("local parts: mut {string} = {}", "local parts = {}")
  lua = lua:gsub("local record _Module .- end local _module: _Module =", "local _module =")
  lua = lua:gsub("if v is (%a+) then", 'if type(v) == "%1" then')
  return lua
end

--- The character references a browser reads in an attribute value, for the
--- names the tests use.
local NAMED <const>: {string: string} = {
  sol = "/", bsol = "\\", Tab = "\t", NewLine = "\n", period = ".", colon = ":", amp = "&", quest = "?", num = "#",
  lpar = "(", rpar = ")", excl = "!",
}

--- `value` with its character references decoded and the bytes a URL
--- parser drops removed, as a browser reads an attribute.
local function decoded(value: string): string
  local text = value:gsub("&#[xX](%x+);", function(n: string): string
    return string.char(tonumber(n, 16) as integer % 256)
  end):gsub("&#(%d+);", function(n: string): string
    return string.char(tonumber(n) as integer % 256)
  end):gsub("&(%a+);", function(name: string): string
    return NAMED[name] or "&" .. name .. ";"
  end)
  return (text:gsub("[\t\n\r]", ""))
end

--- The scheme and the host of `url`, as a browser reads them: after a
--- `http:` or `https:`, and at a leading `//`, any run of `/` and `\`
--- begins the host.
local function origin(url: string): string
  url = url:gsub("^[%z\1-\32]+", "")
  local scheme, rest = url:match("^(%a[%w+.-]*):(.*)$")
  if scheme == nil then
    if url:find("^[/\\][/\\]") then
      return "|" .. url:gsub("^[/\\]+", ""):match("^[^/\\?#]*")
    end
    return "|"
  end
  scheme = scheme:lower()
  if scheme == "http" or scheme == "https" then
    return scheme .. "|" .. rest:gsub("^[/\\]+", ""):match("^[^/\\?#]*")
  end
  return scheme .. "|"
end

--- What is wrong with the attribute `value` (a part between \6 and \7, the
--- rest as the compiled template wrote it) or "": its origin differs from
--- that of the same value with every part empty, or a path segment holding
--- a part decodes to `.` or `..`.
local function assembled_fault(value: string): string
  local text = decoded(value):gsub("[\1-\5]", "")
  local full = text:gsub("[\6\7]", "")
  local bare = text:gsub("\6[^\7]*\7", "")
  if origin(full) ~= origin(bare) then
    return "a URL part changed the origin from " .. origin(bare) .. " to " .. origin(full)
  end
  for segment in (text:match("^[^?#]*"):gsub("[\\]", "/") .. "/"):gmatch("([^/]*)/") do
    if segment:find("\6", 1, true) then
      local name = segment:gsub("[\6\7]", ""):lower():gsub("%%2e", ".")
      if name == "." or name == ".." then
        return "a URL part made a dot segment"
      end
    end
  end
  return ""
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
    requires = { "refused", "text", "rtext", "ftext", "attr", "url", "part", "assembled part", "part after url", "block", "assembled url", "root", "range binding" },
    shares = { refused = 0.01, text = 0.05, rtext = 0.01, ftext = 0.01, attr = 0.01, url = 0.01, part = 0.01 },
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
      local made_kinds: mut {string} = {}
      for helper in source:gmatch("parts%[#parts %+ 1%] = (_%a+)%(v%) end") do
        made_kinds[#made_kinds + 1] = HELPER_KIND[helper] or "?"
      end
      if table.concat(made_kinds) ~= kinds then
        return false, "slots judged as " .. table.concat(made_kinds) .. ", not " .. kinds .. ": " .. body
      end
      if kinds:find("r", 1, true) then Fuzz.label("rtext") end
      if kinds:find("f", 1, true) then Fuzz.label("ftext") end
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
      local render = loaded.render
      local each: {string: any} = { s = "" }
      setmetatable(each, { __index = function(_: any, key: string): any
        if key == "w" then
          return each
        elseif key == "l" then
          return { each }
        end
        return payload
      end })
      -- A list of two runs each range's body; an empty one, its else.
      local function inspect(out: string): boolean, string
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
        -- A part holds only unreserved bytes and %XX, so it cannot end the
        -- attribute, start a scheme, or be a segment that climbs.
        for part in out:gmatch("\6([^\7]*)\7") do
          Fuzz.label("part")
          if part:gsub("%%%x%x", ""):find("[^%w%-._~]") then
            return false, "a byte of a URL part that is not unreserved or %XX: " .. part
          elseif part == "." or part == ".." then
            return false, "a URL part that is a dot segment: " .. part
          end
        end
        -- Whatever a part is given, empty or not, the URL a browser assembles
        -- (character references decoded, tab and line breaks dropped) has the
        -- scheme and host its text and whole-URL slot gave it, and no path
        -- segment a part helped make is a dot segment.
        for _, attr in ipairs({ "href", "src" }) do
          for value in out:gmatch(attr .. '=[\'"]([^\'"]*)[\'"]') do
            if value:find("\6", 1, true) then
              Fuzz.label("assembled part")
              if value:find("\5", 1, true) or value:find("&#5;", 1, true) then
                Fuzz.label("part after url")
              end
              local fault = assembled_fault(value)
              if fault ~= "" then
                return false, fault .. ": " .. value:gsub("[\1-\8]", "#")
              end
            end
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
        return true, ""
      end
      -- A list of two runs each range's body; an empty one, its else. Each is
      -- rendered with every part given its value, then with one part alone
      -- given it and the others empty, and with one part alone empty: a part
      -- may be empty, and the others need not be.
      for _, list in ipairs({ { each, each }, {} } as {{any}}) do
        local runs: mut {{integer}} = { { 0, 0 } }
        local at = 1
        while at <= #runs do
          PART_RUN.calls, PART_RUN.only, PART_RUN.skip = 0, runs[at][1], runs[at][2]
          local ok, made = pcall(render, { a = payload, l = list, w = each })
          if not ok then
            return false, "render raised: " .. tostring(made) .. "\n" .. lua_of(assert(source))
          end
          local good, bad = inspect(made.s)
          if not good then
            return false, bad
          end
          if at == 1 then
            for i = 1, math.min(PART_RUN.calls, 8) do
              runs[#runs + 1] = { i, 0 }
              runs[#runs + 1] = { 0, i }
            end
          end
          at = at + 1
        end
      end
      if body:find("{{range", 1, true) or body:find("{{if", 1, true) or body:find("{{with", 1, true) then
        Fuzz.label("block")
      end
      if body:find("{{$.a}}", 1, true) then
        Fuzz.label("root")
      end
      if body:find("{{range $", 1, true) then
        Fuzz.label("range binding")
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
  "<noscript><style></noscript>", "<noscript><st", "<p title=\"</noscript>", "<?",
  "<svg><style></style></svg>", "<select>", "</select>", "<frameset>", "<noframes>", "</noframes>",
  "<select><title></title></select>",
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
  local out: mut {string} = {}
  while Fuzz.more(src, #out, 12) do
    out[#out + 1] = Fuzz.pick(src, RAW_PIECES)
  end
  return Fuzz.pack({ table.concat(out), tostring(src:int(1, #CUTS)), Fuzz.pick(src, RAW_PIECES) })
end

--- The helpers a compiled template calls, in order.
local function helpers(source: string): string
  local out: mut {string} = {}
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
      Fuzz.label(if kind == 2 then "range" elseif kind == 3 then "with" elseif kind == 4 then "arms" elseif kind == 5 then "string" else "if" end)
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
          return false, "compiled with a cut at " .. tostring(cut) .. " what it refuses whole: " .. body
        elseif helpers(split) ~= helpers(reference) then
          return false, "cut at " .. tostring(cut) .. " gives " .. helpers(split) .. ", not " .. helpers(reference) .. ": " .. body
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
  local out: mut {string} = {}
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
  local fields: mut {string} = {}
  while Fuzz.more(src, #fields // 2, 12) do
    local kind = Fuzz.pick(src, { "t", "q", "q", "s" })
    local run: mut {string} = {}
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
      local body: mut {string} = {}
      local want: mut {string} = {}
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

--- A start tag as the HTML standard's tokenizer reads the text at the start
--- of `s`, apart from the tracker: its name, its attributes (`name=value`,
--- sorted), whether it closes itself, the tokenizer's state where `s` ends
--- ("" once the tag has ended) and all it holds there (`at`), the text after
--- the tag, and where each slot stands. A slot is written `\1<n>\2`.
local record Tag
  mut name: string
  attrs: mut {string}
  mut selfclosing: boolean
  mut state: string
  mut at: string
  mut rest: string
  --- Each slot in the tag, as its number, then what it is: "attr", "url"
  --- or "refuse" (outside a quoted value, or the content of a <meta> that
  --- has http-equiv).
  slots: mut {{string}}
end

local function read_tag(s: string): Tag
  local tag: Tag = { name = "", attrs = {}, selfclosing = false, state = "tag_name", at = "", rest = "", slots = {} }
  local name: string = ""
  local value: string = ""
  local function push()
    tag.attrs[#tag.attrs + 1] = name .. "=" .. value
    name, value = "", ""
  end
  local named: mut {string} = {}
  local i = 2
  while i <= #s and tag.state ~= "" do
    local c = s:sub(i, i)
    local white = c:find("^[ \t\n\f\r]") ~= nil
    local state = tag.state
    local again = false
    if c == "\1" then
      local close = s:find("\2", i, true) or #s
      local id = s:sub(i + 1, close - 1)
      if state == "value_dq" or state == "value_sq" then
        tag.slots[#tag.slots + 1] = { id, if name == "href" and value == "" then "url" else "attr" end }
        named[#tag.slots] = name
        value = value .. s:sub(i, close)
      else
        tag.slots[#tag.slots + 1] = { id, "refuse" }
      end
      i = close
    elseif state == "tag_name" then
      if white then
        tag.state = "before_attr"
      elseif c == "/" then
        tag.state = "selfclosing"
      elseif c == ">" then
        tag.state = ""
      else
        tag.name = tag.name .. c:lower()
      end
    elseif state == "before_attr" then
      if c == "/" then
        tag.state = "selfclosing"
      elseif c == ">" then
        tag.state = ""
      elseif not white then
        name = c:lower()
        tag.state = "attr_name"
      end
    elseif state == "attr_name" then
      if white or c == "/" or c == ">" then
        tag.state, again = "after_attr", true
      elseif c == "=" then
        tag.state = "before_value"
      else
        name = name .. c:lower()
      end
    elseif state == "after_attr" then
      if c == "/" then
        push()
        tag.state = "selfclosing"
      elseif c == "=" then
        tag.state = "before_value"
      elseif c == ">" then
        push()
        tag.state = ""
      elseif not white then
        push()
        tag.state, again = "before_attr", true
      end
    elseif state == "before_value" then
      if c == "\"" then
        tag.state = "value_dq"
      elseif c == "'" then
        tag.state = "value_sq"
      elseif c == ">" then
        push()
        tag.state = ""
      elseif not white then
        tag.state, again = "value_unq", true
      end
    elseif state == "value_dq" or state == "value_sq" then
      if c == (if state == "value_dq" then "\"" else "'" end) then
        push()
        tag.state = "after_value"
      else
        value = value .. c
      end
    elseif state == "after_value" then
      tag.state, again = "before_attr", true
    elseif state == "value_unq" then
      if white then
        push()
        tag.state = "before_attr"
      elseif c == ">" then
        push()
        tag.state = ""
      else
        value = value .. c
      end
    elseif state == "selfclosing" then
      if c == ">" then
        tag.selfclosing = true
        tag.state = ""
      else
        tag.state, again = "before_attr", true
      end
    end
    if not again then
      i = i + 1
    end
  end
  tag.rest = s:sub(i)
  if tag.state ~= "" then
    tag.at = table.concat({ tag.state, tag.name, name, value }, "\0")
  end
  table.sort(tag.attrs)
  local equiv = false
  for _, a in ipairs(tag.attrs) do
    equiv = equiv or a:find("^http%-equiv=") ~= nil
  end
  for n, slot in ipairs(tag.slots) do
    if tag.name == "meta" and equiv and named[n] == "content" then
      slot[2] = "refuse"
    end
  end
  return tag
end

--- What may stand in a tag around a block, and what the block may add.
local TAG_PIECES <const> = { " ", "\n", "/", " name=\"n\"", " type='checkbox'", " a", "b", "=", "chec", "ked",
  " http-equiv", " content=\"{{.x}}\"", " color", " face", " size", " title=\"{{.x}}\"", " href=\"{{.x}}\"" }
local TAG_ARMS <const> = { " checked", "checked ", " checked ", "checked", " disabled", "\nselected\n", " a=\"b\"",
  "=x", "ked", "/", " /", "", " http-equiv", " http-equiv", " color", " title=\"{{.x}}\"", " content=\"{{.x}}\"" }

--- Whether a `<font>` that has one of these attributes takes the parser
--- out of `<svg>`.
local FONT_BREAKS <const>: {string: boolean} = { color = true, face = true, size = true }

--- Whether the opening `<svg>` is there, the tag, the text before a block
--- in it, the block's kind, what its arms write, and the text after it.
local function gen_tag_block(src: Fuzz.Source): string
  local before: mut {string} = {}
  while Fuzz.more(src, #before, 3) do
    before[#before + 1] = Fuzz.pick(src, TAG_PIECES)
  end
  local after: mut {string} = {}
  while Fuzz.more(src, #after, 3) do
    after[#after + 1] = Fuzz.pick(src, TAG_PIECES)
  end
  local lead = Fuzz.pick(src, { "", "", "", "<svg>" })
  local open = if lead ~= "" then "<font" else Fuzz.pick(src, { "<input", "<option", "<br", "<meta", "<font", "<svg" }) end
  if open == "<meta" and src:int(0, 1) == 0 then
    -- A slot in the content before the block, which an arm that names
    -- http-equiv makes a redirect.
    table.insert(before, 1, " content=\"{{.x}}\"")
  end
  return Fuzz.pack({ lead, open, table.concat(before), Fuzz.pick(src, { "if", "if", "else", "range" }),
    Fuzz.pick(src, TAG_ARMS), Fuzz.pick(src, TAG_ARMS), table.concat(after) })
end

--- The attributes `text` writes by itself, `times` over.
local function written(text: string, times: integer): {string}
  local out: mut {string} = {}
  for _ = 1, times do
    for _, a in ipairs(read_tag("<t " .. text .. ">").attrs) do
      out[#out + 1] = a
    end
  end
  return out
end

--- `a` and `b` together, sorted and joined.
local function merged(a: {string}, b: {string}): string
  local all: mut {string} = {}
  for _, x in ipairs(a) do all[#all + 1] = x end
  for _, x in ipairs(b) do all[#all + 1] = x end
  table.sort(all)
  return table.concat(all, " ")
end

-- A block in a tag that compiles adds only the attributes it writes: each
-- way it may run, the tag has the same name and closes itself or not alike,
-- and the attributes the text around the block makes are the same. (Else
-- `<input{{if .a}} checked{{end}}=x>` could be `<input checked=x>` or the
-- tag `<input=x>`.) Text that leaves the block inside a value is the
-- value's, and only compiled; so are the arms of an `{{else}}` that leave
-- the tag where each other does, which the text after reads alike, as
-- `<b{{if .a}}r>{{else}}>{{end}}` does. Every way it runs, each slot is
-- escaped for where the tag puts it, and none stands where nothing escapes.
local function test_a_block_in_a_tag_adds_only_the_attributes_it_writes(tmp: string)
  Fuzz.run({
    name = "template tag block",
    dir = tmp,
    gen = gen_tag_block,
    requires = { "compiled", "refused", "added", "else", "range", "slot", "font in svg", "meta" },
    shares = { added = 0.05, refused = 0.1 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local lead, open, before, kind = fields[1] or "", fields[2] or "<p", fields[3] or "", fields[4] or "if"
      local arm, other, after = fields[5] or "", fields[6] or "", fields[7] or ""
      local closer = ">{{.x}}" .. (if lead ~= "" then "</font></svg>" elseif open == "<svg" then "</svg>" else "" end)
      local block = if kind == "range" then "{{range .l}}" .. arm .. "{{end}}" elseif
        kind == "else" then "{{if .a}}" .. arm .. "{{else}}" .. other .. "{{end}}" else "{{if .a}}" .. arm .. "{{end}}" end
      local body = lead .. open .. before .. block .. after .. closer
      -- What was drawn is labelled before it is compiled: only about one
      -- input in four compiles, too few for every seed's 64 draws to meet a
      -- compiled range, else, <meta> or <svg><font>, and `added`'s share and
      -- `slot` hold the property to compiled inputs that exercise it.
      Fuzz.label(kind)
      if open == "<meta" then
        Fuzz.label("meta")
      end
      if lead ~= "" then
        Fuzz.label("font in svg")
      end
      local source = Template.compile("{{type T from m.t}}" .. body, "t.tmpl") or ""
      if source == "" then
        Fuzz.label("refused")
        return true, ""
      end
      Fuzz.label("compiled")
      -- Each slot numbered in the order the source has it, as the helpers are.
      local count: integer = 0
      local function number(piece: string): string
        return (piece:gsub("{{%.x}}", function(): string
          count = count + 1
          return "\1" .. tostring(count) .. "\2"
        end))
      end
      local n_before, n_arm = number(before), number(arm)
      local n_other = kind == "else" and number(other) or ""
      local n_after, n_closer = number(after), number(closer)
      local kinds: mut {string} = {}
      for made in source:gmatch("parts%[#parts %+ 1%] = _(%a+)%(v%) end") do
        kinds[#kinds + 1] = made
      end
      if #kinds ~= count then
        return false, tostring(#kinds) .. " slots compiled of " .. tostring(count) .. ": " .. body
      end
      -- What each run writes in the block, and the attributes that alone makes.
      local runs: mut {string} = { "", n_arm }
      local own: mut {{string}} = { {}, written(n_arm, 1) }
      if kind == "else" then
        runs[1], own[1] = n_other, written(n_other, 1)
      elseif kind == "range" then
        runs[3], own[3] = n_arm .. n_arm, written(n_arm, 2)
      end
      local tags: mut {Tag} = {}
      for i, run in ipairs(runs) do
        local tag = read_tag(open .. n_before .. run .. n_after .. n_closer)
        tags[i] = tag
        -- The text after the tag is inside `<svg>` unless the tag is an
        -- `<svg>` that closes itself.
        local text = if (lead ~= "" or (tag.name == "svg" and not tag.selfclosing)) then "ftext" else "text" end
        if lead ~= "" then
          for _, a in ipairs(tag.attrs) do
            if FONT_BREAKS[a:match("^[^=]*")] then
              text = "refuse"
            end
          end
        end
        for id in tag.rest:gmatch("\1(%d+)\2") do
          tag.slots[#tag.slots + 1] = { id, text }
        end
        for _, slot in ipairs(tag.slots) do
          local want, made = slot[2], kinds[math.tointeger(tonumber(slot[1])) or 0]
          if want == "refuse" then
            return false, "compiled slot " .. slot[1] .. " where nothing escapes it, as " .. tostring(made) .. ": " ..
              body
          elseif made ~= want then
            return false, "slot " .. slot[1] .. " is " .. tostring(made) .. ", not " .. want .. ": " .. body
          end
          if want ~= text then
            Fuzz.label("slot")
          end
        end
      end
      local state = read_tag(open .. n_before).state
      if state ~= "tag_name" and state ~= "before_attr" and state ~= "attr_name" and state ~= "after_attr" and
          state ~= "selfclosing" then
        return true, ""
      end
      if kind == "else" and read_tag(open .. n_before .. runs[1]).at == read_tag(open .. n_before .. runs[2]).at then
        return true, ""
      end
      for i = 2, #runs do
        if tags[i].name ~= tags[1].name or tags[i].selfclosing ~= tags[1].selfclosing then
          return false, "the block changes the tag: " .. body
        end
        if merged(tags[i].attrs, own[1]) ~= merged(tags[1].attrs, own[i]) then
          return false, "the attributes around the block differ as it runs: " .. table.concat(tags[i].attrs, " ") ..
            " against " .. table.concat(tags[1].attrs, " ") .. ": " .. body
        end
      end
      if arm:find("%a") then
        Fuzz.label("added")
      end
      return true, ""
    end,
  })
end

--- Attributes of the htmx dialect whose slots are selectors, spelled as
--- the page may spell them.
local SELECTOR_ATTRS <const>: {string} = {
  "hx-target", "HX-TARGET", "data-hx-target", "Data-Hx-Select", "hx-select", "hx-select-oob", "hx-include",
  "hx-indicator", "hx-disabled-elt", "hx-sync", "hx-swap-oob", "hx-target-422", "hx-target-error",
}

--- What may stand before a selector slot, and after it. The text before
--- ends in a `#` or `.` or in an identifier after one, and neither holds
--- the quote of the attribute.
local SELECTOR_LEADS <const>: {string} = { "#", ".", "#row-", ".tab-", "closest #card-", "body, #", "#a b > .c-", "p:not(#" }
local SELECTOR_TRAILS <const>: {string} = { "", " p", ", #x", ":abort", ")", " > .y", "\\", "-more" }

--- Values a selector may be given.
local HOSTILE <const>: {string} = {
  "x, body", "a b", "a>b", "a.b", "a#b", "a[b]", "a(b)", "a:b", "a\"b", "a'b", "a<b>c&d", "\\", "\\2c ", "1", "-", "--",
  "", " ", "\n", "\0", "\t", "a,#evil", "é", "\255\254", "a;b", "a*b", "a+b", "a~b", "a|b", "a/*b", "x\\", "%", "@", "{}",
}

local function gen_selector(src: Fuzz.Source): string
  local payload = src:int(0, 2) == 0 and Fuzz.bytes(src, 6) or Fuzz.pick(src, HOSTILE)
  return Fuzz.pack({ payload, Fuzz.pick(src, SELECTOR_ATTRS), Fuzz.pick(src, SELECTOR_LEADS),
    Fuzz.pick(src, SELECTOR_TRAILS), Fuzz.pick(src, { '"', "'" }) })
end

--- `text` with its CSS escapes undone: a backslash, up to six hex digits
--- and one white space after them, or a backslash and the byte after it.
local function css_unescape(text: string): string
  local out = text:gsub("\\(%x%x?%x?%x?%x?%x?)[ \t\n\f\r]?", function(hex: string): string
    local code = tonumber(hex, 16) as integer
    return if code == 0 then "\239\191\189" else utf8.char(code) end
  end)
  return out
end

--- Whether `text` is a run of what CSS reads as part of one identifier:
--- name bytes, and escapes each ended by the one space the escaper writes.
local function in_identifier(text: string): boolean
  local rest = text
  while rest ~= "" do
    local plain = rest:match("^[%w_%-\128-\255]+")
    local escape = rest:match("^\\%x%x?%x?%x?%x?%x? ")
    local step = plain or escape
    if step == nil then
      return false
    end
    rest = rest:sub(#step + 1)
  end
  return true
end

local function test_a_selector_slot_never_leaves_the_identifier_it_stands_in(tmp: string)
  Fuzz.run({
    name = "selector slot",
    dir = tmp,
    gen = gen_selector,
    requires = { "escaped", "plain", "high" },
    shares = { escaped = 0.2 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local payload, attr, lead, trail, quote = fields[1] or "", fields[2] or "", fields[3] or "", fields[4] or "",
        fields[5] or '"'
      local body = "<a " .. attr .. "=" .. quote .. lead .. "{{.a}}" .. trail .. quote .. ">"
      local source, why = Template.compile("{{type T from m.t}}{{use htmx}}" .. body, "t.tmpl")
      if source == nil then
        return false, "refused " .. body .. ": " .. why
      end
      local env: {string: any} = { require = function(name: string): any
        return name == "cosmic.html" and Html or {}
      end, table = table, tostring = tostring, type = type }
      local chunk, trouble = load(lua_of(source), "=module", "t", env)
      if chunk == nil then
        return false, "the module does not load: " .. tostring(trouble)
      end
      local loaded = chunk() as {string: function({string: string}): any}
      local made = Html.raw(loaded.render({ a = payload }) as Html.SafeHtml)
      -- The attribute is a quoted value that holds no quote: the escaper
      -- writes every byte that could end it as a reference.
      local value = made:match("^<a [^=]+=" .. quote .. "([^" .. quote .. "]*)" .. quote .. ">$")
      if value == nil then
        return false, "the attribute is not one quoted value: " .. made
      end
      local css = value:gsub("&#(%d+);", function(n: string): string
        return string.char(tonumber(n) as integer)
      end)
      local at, stop = #lead + 1, #css - #trail
      if css:sub(1, #lead) ~= lead or css:sub(stop + 1) ~= trail then
        return false, "the text around the slot changed: " .. made
      end
      local middle = css:sub(at, stop)
      if not in_identifier(middle) then
        return false, "the slot is more than identifier text: " .. string.format("%q", middle)
      end
      local want = if payload == "" then "" else payload:gsub("%z", "\239\191\189") end
      if css_unescape(middle) ~= want then
        return false, "the slot does not read back as its value: " .. string.format("%q", middle)
      end
      if middle:find("\\", 1, true) then Fuzz.label("escaped") else Fuzz.label("plain") end
      if middle:find("[\128-\255]") then Fuzz.label("high") end
      return true, ""
    end,
  })
end

local function gen_json(src: Fuzz.Source): string
  local payload = src:int(0, 2) == 0 and Fuzz.bytes(src, 6) or Fuzz.pick(src, HOSTILE)
  return Fuzz.pack({ payload, Fuzz.pick(src, { "hx-vals", "hx-headers", "hx-request", "data-hx-vals", "HX-HEADERS" }),
    Fuzz.pick(src, { '"', "'" }), Fuzz.pick(src, { "k", "js:alert(1)", "javascript:x", "}", "\"" }) })
end

local function test_a_json_slot_is_the_attribute_value_it_was_given(tmp: string)
  Fuzz.run({
    name = "json slot",
    dir = tmp,
    gen = gen_json,
    requires = { "encoded", "quoted" },
    shares = { quoted = 0.2 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local payload, attr, quote, key = fields[1] or "", fields[2] or "", fields[3] or '"', fields[4] or ""
      local json = Html.json({ [key] = payload, list = { payload, key }, ["js:" .. payload] = key })
      if json == nil then
        -- Bytes that are not UTF-8 are not JSON text.
        return true, ""
      end
      Fuzz.label("encoded")
      local body = "<a " .. attr .. "=" .. quote .. "{{.j}}" .. quote .. ">"
      local source, why = Template.compile("{{type T from m.t}}{{use htmx}}" .. body, "t.tmpl")
      if source == nil then
        return false, "refused " .. body .. ": " .. why
      end
      local env: {string: any} = { require = function(name: string): any
        return name == "cosmic.html" and Html or {}
      end, table = table, tostring = tostring, type = type }
      local chunk, trouble = load(lua_of(source), "=module", "t", env)
      if chunk == nil then
        return false, "the module does not load: " .. tostring(trouble)
      end
      local loaded = chunk() as {string: function({string: any}): any}
      local made = Html.raw(loaded.render({ j = json }) as Html.SafeHtml)
      local value = made:match("^<a [^=]+=" .. quote .. "([^" .. quote .. "]*)" .. quote .. ">$")
      if value == nil then
        return false, "the attribute is not one quoted value: " .. made
      end
      if value:find("[<>]") then
        return false, "markup in the attribute: " .. value
      end
      -- What a browser reads of the value is the JSON text itself.
      local read = value:gsub("&(%a+);", { quot = '"', amp = "&", lt = "<", gt = ">", apos = "'" }):gsub("&#(%d+);", function(n: string): string
        return string.char(tonumber(n) as integer)
      end)
      if read ~= Html.raw_json(json) then
        return false, "the attribute reads as " .. string.format("%q", read)
      end
      if read:find("^%s*j") or not Json.check(read) then
        return false, "the value could be read as code: " .. read
      end
      if value:find("&quot;", 1, true) or value:find("&#39;", 1, true) then Fuzz.label("quoted") end
      return true, ""
    end,
  })
end

--- Names of attributes a slot in is script, as the page may spell them.
local SCRIPT_ATTRS <const>: {string} = {
  "hx-on", "hx-on:click", "hx-on::after-request", "hx-on--after-request", "hx-on-click", "hx-onx", "hx-vars",
  "hx-trigger", "onclick", "onx", "hx-ws",
}

--- `name` with each letter in either case and, for an attribute of htmx
--- (which reads `data-hx-x` as `hx-x`), a `data-` ahead of it or not.
local function spelled(src: Fuzz.Source, name: string): string
  local out = name:gsub("%a", function(c: string): string
    return src:int(0, 1) == 0 and c:lower() or c:upper()
  end)
  return if name:find("^hx%-") and src:int(0, 1) == 0 then "data-" .. out else out end
end

local function gen_script_attr(src: Fuzz.Source): string
  local name = Fuzz.pick(src, SCRIPT_ATTRS)
  return Fuzz.pack({ spelled(src, name), name, Fuzz.pick(src, { "", "{{use htmx}}" }), Fuzz.pick(src, { '"', "'" }),
    Fuzz.pick(src, { "{{.a}}", "x{{.a}}", "{{.a}}x", "/{{.a}}", "{{if .b}}{{.a}}{{end}}" }) })
end

local function test_a_slot_in_an_attribute_that_is_script_is_refused_whatever_its_spelling(tmp: string)
  Fuzz.run({
    name = "script attribute",
    dir = tmp,
    gen = gen_script_attr,
    requires = { "data", "use" },
    shares = { data = 0.2, use = 0.2 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local spelling, name, use, quote, value = fields[1] or "", fields[2] or "", fields[3] or "", fields[4] or "",
        fields[5] or ""
      if spelling:find("^data%-") then Fuzz.label("data") end
      if use ~= "" then Fuzz.label("use") end
      local body = "<a " .. spelling .. "=" .. quote .. value .. quote .. ">"
      -- `hx-ws` is read by an extension: refused only where a template opts in.
      local out = Template.compile("{{type T from m.t}}" .. use .. body, "t.tmpl")
      if name == "hx-ws" and use == "" then
        return true, ""
      end
      if out ~= nil then
        return false, "compiled a slot in a script attribute: " .. body
      end
      return true, ""
    end,
  })
end
