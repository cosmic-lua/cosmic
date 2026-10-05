local Template = require("cosmic.template")

local HEAD <const> = "{{type T from m.t}}\n"

--- The source [`Template.compile`] makes of `src`, which must compile.
local function compiled(src: string): string
  local out, why = Template.compile(src, "t.tmpl")
  assert(out ~= nil, why)
  return out
end

--- What [`Template.compile`] refuses `src` with, which it must.
local function refused(src: string): string
  local out, why = Template.compile(src, "t.tmpl")
  assert(out == nil, "compiled: " .. tostring(out))
  return why
end

--- The number of newlines in `s`.
local function newlines(s: string): integer
  local _, count = s:gsub("\n", "")
  return count
end

local function test_a_text_template_returns_a_string_and_needs_no_html()
  local out = compiled("{{type Page from site.page}}\n{{mode text}}\nHi {{.name}}!\n")
  assert(out:find('require("site.page")', 1, true), out)
  assert(not out:find("cosmic.html", 1, true), out)
  assert(out:find("render(d: page.Page): string", 1, true), out)
  assert(out:find("= d.name parts[#parts + 1] = _text(v)", 1, true), out)
  assert(out:find("local function _text(v: string | number): string", 1, true), out)
  assert(not out:find("_attr", 1, true) and not out:find("_url", 1, true), out)
end

local function test_html_is_the_default_mode_and_returns_safehtml()
  local out = compiled(HEAD .. "<p>{{.x}}</p>")
  assert(out:find('local html = require("cosmic.html")', 1, true), out)
  assert(out:find("render(d: t.T): html.SafeHtml", 1, true), out)
  assert(out:find("return html.trust(table.concat(parts))", 1, true), out)
  local same = compiled("{{type T from m.t}}{{mode html}}\n<p>{{.x}}</p>")
  assert(same:find("html.SafeHtml", 1, true), same)
end

local function test_a_template_without_actions_does_not_read_its_argument()
  local out = compiled(HEAD .. "<p>hi</p>\n")
  assert(out:find("render(_: t.T)", 1, true), out)
  assert(not out:find("_text", 1, true), out)
end

local SLOTS <const>: {{string}} = {
  { "<p>{{.x}}</p>", "_text(" },
  { "a < b {{.x}}", "_text(" },
  { "<a title=\"{{.x}}\">", "_attr(" },
  { "<a title='{{.x}}'>", "_attr(" },
  { "<a TITLE = \"{{.x}}\" >", "_attr(" },
  { "<a href=\"{{.x}}\">", "_url(" },
  { "<A HREF='{{.x}}'>", "_url(" },
  { "<a  href  =  \"  {{.x}}\">", "_url(" },
  { "<img alt=\"x\" src=\"{{.x}}\">", "_url(" },
  { "<form action=\"{{.x}}\">", "_url(" },
  { "<button formaction=\"{{.x}}\">", "_url(" },
  { "<svg><a xlink:href=\"{{.x}}\">", "_url(" },
  { "<a data-x=\"a\" title=\"{{.x}}\">", "_attr(" },
  { "<textarea>{{.x}}</textarea>", "_rtext(" },
  { "<title>{{.x}}</TITLE>", "_rtext(" },
  { "<svg/><textarea><a href=\"{{.x}}\">", "_rtext(" },
  { "<svg><textarea>{{.x}}</textarea></svg>", "_rtext(" },
  { "<svg><text>{{.x}}</text></svg>", "_text(" },
  { "<svg><g><a href=\"{{.x}}\"><path d=\"M0\"/></a></g></svg>", "_url(" },
  { "<svg viewBox=\"0 0 1 1\"><circle r=\"1\"/></svg><p>{{.x}}</p>", "_text(" },
  { "<svg {{if .a}}class=\"b\"{{end}}><g/></svg>{{.x}}", "_text(" },
  { "<select><option>a</option></select><svg></svg>{{.x}}", "_text(" },
  { "<svg/{{if .a}}{{end}}><textarea>{{.x}}", "_rtext(" },
  { "<svg><style>.a { fill: red }</style></svg>{{.x}}", "_text(" },
  { "<a title=\"{{range .l}}{{.x}}{{end}}\">", "_attr(" },
  { "<img lowsrc=\"{{.x}}\" dynsrc=\"{{.x}}\">", "_url(" },
  { "<svg></svg>{{.x}}<math></math><title>{{.x}}</title>", "_text(" },
  { "<a href=\"x\" {{if .a}}class=\"b\"{{end}}>{{.x}}", "_text(" },
  { "<p {{if .a}}class=\"c\"{{else}}id=\"d\"{{end}}>{{.x}}", "_text(" },
  { "<a href=\"{{if .a}}{{.x}}{{end}}\">", "_url(" },
  { "<a href=\"{{.x}}/a:b\">", "_url(" },
  { "<a href=\"{{.x}}?q=a:b#c:d\">", "_url(" },
  { "<meta name=\"d\" content=\"{{.x}}\">", "_attr(" },
  { "<meta content=\"{{.x}}\" name=\"d\">", "_attr(" },
  { "<iframe></iframe>{{.x}}<noscript></noscript>{{.x}}<xmp></xmp>{{.x}}", "_text(" },
  { "<script>var a = 1 < 2;</script>{{.x}}", "_text(" },
  { "<style>a > b {}</STYLE >{{.x}}", "_text(" },
  { "<script><!-- </script>{{.x}}", "_text(" },
  { "<!-- c -->{{.x}}", "_text(" },
  { "<!--> {{.x}}", "_text(" },
  { "<!---> {{.x}}", "_text(" },
  { "<!-- a --!> {{.x}}", "_text(" },
  { "<!DOCTYPE html>{{.x}}", "_text(" },
  { "<a href=\"a\" title=\"{{.x}}\">", "_attr(" },
  { "<a href=x title=\"{{.x}}\">", "_attr(" },
  { "<br/>{{.x}}", "_text(" },
  { "<svg><a href=\"{{.x}}\"></a></svg>", "_url(" },
  { "<a title=\"a>b\">{{.x}}", "_text(" },
}

local function test_each_slot_is_escaped_for_the_place_it_stands_in()
  for _, case in ipairs(SLOTS) do
    local out = compiled(HEAD .. case[1])
    assert(out:find(case[2], 1, true), case[1] .. " did not use " .. case[2])
    for _, other in ipairs({ "_text(", "_attr(", "_url(" }) do
      if other ~= case[2] then
        local _, uses = out:gsub("parts%[#parts %+ 1%] = " .. other:gsub("%p", "%%%0"), "")
        assert(uses == 0, case[1] .. " used " .. other)
      end
    end
  end
end

--- Template source, the line and column it is refused at, and what the
--- reason says. Line 1 is the `{{type}}` line.
local REFUSALS <const>: {{string}} = {
  { "<a href={{.x}}>", "2", "9", "unquoted" },
  { "<a title=x{{.x}}>", "2", "11", "unquoted" },
  { "<{{.x}}>", "2", "2", "tag name" },
  { "<di{{.x}}>", "2", "4", "tag name" },
  { "</{{.x}}>", "2", "3", "tag name" },
  { "<a {{.x}}>", "2", "4", "attribute" },
  { "<a b{{.x}}=1>", "2", "5", "attribute" },
  { "<a b {{.x}}>", "2", "6", "attribute" },
  { "<a b=\"c\"{{.x}}>", "2", "9", "attribute" },
  { "<a onclick=\"{{.x}}\">", "2", "13", "event handler" },
  { "<a ONMOUSEOVER='{{.x}}'>", "2", "17", "event handler" },
  { "<a style=\"{{.x}}\">", "2", "11", "'style'" },
  { "<iframe srcdoc=\"{{.x}}\">", "2", "17", "'srcdoc'" },
  { "<img srcset=\"{{.x}}\">", "2", "14", "list of URLs" },
  { "<a ping=\"{{.x}}\">", "2", "10", "list of URLs" },
  { "<meta http-equiv=\"refresh\" content=\"0;{{.x}}\">", "2", "39", "<meta>" },
  { "<!-- {{.x}} -->", "2", "6", "comment" },
  { "<!--{{.x}}-->", "2", "5", "comment" },
  { "<!{{.x}}>", "2", "3", "comment" },
  { "<!-{{.x}}>", "2", "4", "comment" },
  { "<?php {{.x}} ?>", "2", "7", "comment" },
  { "</ {{.x}}>", "2", "4", "comment" },
  { "<!-- a -- {{.x}}", "2", "11", "comment" },
  { "<script>{{.x}}</script>", "2", "9", "<script>" },
  { "<a =\"{{.x}}\">", "2", "6", "attribute" },
  { "<svg><p><textarea>{{.x}}</textarea>", "2", "19", "differently" },
  { "<svg><div></div><textarea>{{.x}}", "2", "27", "differently" },
  { "<svg><br><textarea>{{.x}}", "2", "20", "differently" },
  { "<svg><font size=1><textarea>{{.x}}", "2", "29", "differently" },
  { "<select><svg><textarea>{{.x}}", "2", "24", "differently" },
  { "<math><svg></math><textarea>{{.x}}", "2", "29", "differently" },
  { "<svg><math></svg><textarea>{{.x}}", "2", "28", "differently" },
  { "<svg></math><textarea>{{.x}}", "2", "23", "differently" },
  { "<svg>{{if .a}}<p>{{end}}<textarea>{{.x}}", "2", "6", "the arms" },
  { "<svg><![CDATA[ > <!-- ]]><a href=\" --> {{.p}}\">", "2", "40", "differently" },
  { "<svg {{if .a}}/{{end}}><style><a href=\"</style>{{.p}}\">", "2", "6", "the arms" },
  { "<svg><foreignObject><div></svg></div></foreignObject><style><a href=\"</style>{{.p}}\">", "2", "78", "differently" },
  { "<svg><!-- c --></svg>{{.x}}", "2", "22", "differently" },
  { "<svg><g></svg>{{.x}}", "2", "15", "differently" },
  { "<svg><a></g></a></svg>{{.x}}", "2", "23", "differently" },
  { "<svg><desc></desc></svg>{{.x}}", "2", "25", "differently" },
  { "<math><mi></mi></math>{{.x}}", "2", "23", "differently" },
  { "<svg><?x ?></svg>{{.x}}", "2", "18", "differently" },
  { "<svg><p></p></svg>{{.x}}", "2", "19", "differently" },
  { "<svg><svg></svg><textarea><a href=\"{{.x}}\">", "2", "36", "differently" },
  { "<svg><textarea><a title=\"{{.x}}\">", "2", "26", "differently" },
  { "<svg><textarea></svg>{{.x}}", "2", "22", "differently" },
  { "<svg><script><!-- </script>{{.x}}", "2", "28", "differently" },
  { "<svg><style><b></style>{{.x}}", "2", "24", "differently" },
  { "<noscript><!-- </noscript>{{.x}}", "2", "27", "differently" },
  { "<plaintext></plaintext>{{.x}}", "2", "24", "<plaintext>" },
  { "<a href=\"{{.x}}&colon;alert(1)\">", "2", "16", "complete a scheme" },
  { "<a href=\"{{.x}}&#58;alert(1)\">", "2", "16", "complete a scheme" },
  { "<meta charset=\"{{.x}}\">", "2", "16", "charset" },
  { "<script type=\"{{.x}}\">", "2", "15", "<script>" },
  { "<object classid=\"{{.x}}\">", "2", "18", "<object>" },
  { "<applet codebase=\"{{.x}}\">", "2", "19", "<applet>" },
  { "<a href=\"{{range .l}}{{.x}}{{end}}\">", "2", "22", "must begin" },
  { "<a href=\"{{range .l}}{{.x}}:{{end}}\">", "2", "28", "complete a scheme" },
  { "<svg><script>{{.x}}</script>", "2", "14", "<script>" },
  { "<svg><g><a title=x{{.x}}", "2", "19", "unquoted" },
  { "<svg><foreignObject>{{.x}}</foreignObject></svg>", "2", "21", "differently" },
  { "<svg><desc>{{.x}}</desc></svg>", "2", "12", "differently" },
  { "<svg><title>{{.x}}</title></svg>", "2", "13", "differently" },
  { "<svg><svg></svg><title>{{.x}}</title>", "2", "24", "differently" },
  { "<math><annotation-xml>{{.x}}</annotation-xml>", "2", "23", "differently" },
  { "<math><mi><a title=\"{{.x}}\">", "2", "21", "differently" },
  { "<svg><set attributeName=\"href\" to=\"{{.x}}\">", "2", "36", "animate" },
  { "<svg><ANIMATE values=\"{{.x}}\">", "2", "23", "animate" },
  { "<animateMotion path=\"{{.x}}\">", "2", "22", "animate" },
  { "<xmp>{{.x}}</xmp>", "2", "6", "<xmp>" },
  { "<iframe>{{.x}}</iframe>", "2", "9", "<iframe>" },
  { "<noscript>{{.x}}</noscript>", "2", "11", "<noscript>" },
  { "<noembed>{{.x}}", "2", "10", "<noembed>" },
  { "<noframes>{{.x}}", "2", "11", "<noframes>" },
  { "<plaintext>{{.x}}", "2", "12", "<plaintext>" },
  { "<meta http-equiv=\"refresh\" content=\"{{.x}}\">", "2", "37", "http-equiv" },
  { "<meta content=\"{{.x}}\" http-equiv=\"refresh\">", "2", "16", "http-equiv" },
  { "<meta content=\"{{.x}}\" HTTP-EQUIV=refresh>", "2", "16", "http-equiv" },
  { "<meta content=\"{{.x}}\" http-equiv=\"refresh\"><p>x</p>", "2", "16", "http-equiv" },
  { "<a href=\"{{.p}}:alert(1)\">", "2", "16", "complete a scheme" },
  { "<a href=\"{{.p}}java\nscript:x\">", "2", "16", "complete a scheme" },
  { "<a href=\"{{.p}}{{if .a}}:x{{end}}\">", "2", "25", "complete a scheme" },
  { "<a href=\"{{.p}}\"><b>x</b></a>{{if .a}}<a href=\"{{.q}}:{{end}}", "2", "54", "complete a scheme" },
  { "<SCRIPT type=\"x\">a{{.x}}", "2", "19", "<script>" },
  { "<style>{{.x}}</style>", "2", "8", "<style>" },
  { "<script><!-- <script> </script> {{.x}} </script>", "2", "33", "<script>" },
  { "<script>\n{{.x}}", "3", "1", "<script>" },
  { "<script/>{{.x}}", "2", "10", "<script>" },
  { "<a href=\"/a/{{.x}}\">", "2", "13", "must begin" },
  { "<a href=\"{{.x}}{{.y}}\">", "2", "16", "must begin" },
  { "<script src=\"{{.x}}\">", "2", "14", "<script>" },
  { "<link href=\"{{.x}}\">", "2", "13", "<link>" },
  { "<object data=\"{{.x}}\">", "2", "15", "<object>" },
  { "<a title=\"x\">\n<a\n  b={{.y}}>", "4", "5", "unquoted" },
}

local function test_a_slot_with_no_escaping_is_refused_at_its_line_and_column()
  local wrong: {string} = {}
  for _, case in ipairs(REFUSALS) do
    local why = refused(HEAD .. case[1])
    local want = "t.tmpl:" .. case[2] .. ":" .. case[3] .. ": "
    if why:sub(1, #want) ~= want or not why:find(case[4], 1, true) then
      wrong[#wrong + 1] = case[1] .. " said " .. why .. ", not " .. want .. "..." .. case[4]
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
end

local function test_the_same_slots_stand_in_a_text_template()
  compiled("{{type T from m.t}}{{mode text}}\n<script>{{.x}}</script><a href={{.y}} onclick='{{.z}}'>")
end

local function test_the_arms_of_a_branch_must_end_in_the_same_place()
  local why = refused(HEAD .. "{{if .a}}<b class=\"{{else}}<i class=\"{{end}}x")
  assert(why:find("^t.tmpl:2:1: the arms of this {{if}} end in different places"), why)
  assert(refused(HEAD .. "{{if .a}}<b {{end}}x"):find("^t.tmpl:2:1: the arms of this {{if}}"))
  assert(refused(HEAD .. "{{with .a}}<!--{{else}}x{{end}}"):find("^t.tmpl:2:1: the arms of this {{with}}"))
  assert(refused(HEAD .. "{{range .a}}<b class=\"{{end}}"):find("^t.tmpl:2:1: the body of this {{range}}"))
  compiled(HEAD .. "{{if .a}}<b class=\"x\">{{else}}<i>{{end}}{{.y}}")
  compiled(HEAD .. "<b class=\"{{if .a}}p{{else}}{{.q}}{{end}}\">")
  compiled(HEAD .. "{{range .a}}<li class=\"c\">{{.n}}</li>{{end}}")
  compiled(HEAD .. "{{if .a}}<script>1</script>{{else}}<p>x</p>{{end}}{{.y}}")
end

local function test_a_slot_that_begins_a_url_is_judged_by_where_its_branch_left_off()
  compiled(HEAD .. "<a href=\"{{if .a}}{{.x}}{{else}}{{.y}}{{end}}\">")
  compiled(HEAD .. "<a href=\"{{if .a}}{{.x}}{{end}}\">")
  local why = refused(HEAD .. "<a href=\"{{if .a}}{{.x}}{{end}}{{.y}}\">")
  assert(why:find("t.tmpl:2:", 1, true) and why:find("must begin", 1, true), why)
end

local SYNTAX <const>: {{string}} = {
  { "", "1", "1", "starts with {{type" },
  { "text\n{{type T from m.t}}", "1", "1", "starts with {{type" },
  { "{{.x}}", "1", "1", "starts with {{type" },
  { "{{type T}}", "1", "1", "write {{type" },
  { "{{type T from m.t extra}}", "1", "1", "write {{type" },
  { "{{type end from m.t}}", "1", "8", "not a type name" },
  { "{{type 1T from m.t}}", "1", "8", "not a type name" },
  { "{{type T from m..t}}", "1", "15", "not an import path" },
  { "{{type T from m.t}}{{mode}}", "1", "20", "write {{mode" },
  { "{{type T from m.t}}{{mode json}}", "1", "20", "write {{mode" },
  { "{{type T from m.t}}x{{mode text}}", "1", "21", "directly follow" },
  { "{{type T from m.t}}{{type U from m.u}}", "1", "20", "first action" },
  { HEAD .. "a {{.x", "2", "3", "unterminated action" },
  { HEAD .. "{{if .x}}\nabc", "2", "1", "never closed" },
  { HEAD .. "{{range .x}}{{with .y}}\n{{end}}", "2", "1", "never closed" },
  { HEAD .. "x{{end}}", "2", "2", "without a block" },
  { HEAD .. "x{{else}}", "2", "2", "without a block" },
  { HEAD .. "{{if .a}}{{else}}{{else}}{{end}}", "2", "18", "after {{else}}" },
  { HEAD .. "{{if .a}}{{else}}{{else if .b}}{{end}}", "2", "18", "after {{else}}" },
  { HEAD .. "{{range .a}}{{else}}{{end}}", "2", "13", "not supported" },
  { HEAD .. "{{with .a}}{{else if .b}}{{end}}", "2", "19", "nest an {{if}}" },
  { HEAD .. "{{if .a}}{{else foo}}{{end}}", "2", "17", "takes nothing" },
  { HEAD .. "{{if .a}}{{end x}}", "2", "10", "takes nothing" },
  { HEAD .. "{{}}", "2", "1", "expected a value" },
  { HEAD .. "{{if}}{{end}}", "2", "1", "expected a value" },
  { HEAD .. "{{foo}}", "2", "3", "not a field path" },
  { HEAD .. "{{.a..b}}", "2", "3", "not a field path" },
  { HEAD .. "{{.a.}}", "2", "3", "not a field path" },
  { HEAD .. "{{.1a}}", "2", "3", "not a field path" },
  { HEAD .. "{{.a b}}", "2", "6", "expected |" },
  { HEAD .. "{{.a |}}", "2", "6", "expected a function" },
  { HEAD .. "{{.a | f}}", "2", "8", "module.path.func" },
  { HEAD .. "{{.a | .b}}", "2", "8", "module.path.func" },
  { HEAD .. "{{.a | m.f x}}", "2", "12", "expected |" },
  { HEAD .. "{{.a | m..f}}", "2", "8", "module.path.func" },
  { HEAD .. "{{if .a | }}{{end}}", "2", "9", "expected a function" },
  { HEAD .. "{{ -.x}}", "2", "4", "not a field path" },
  { HEAD .. "{{.x -}", "2", "1", "unterminated" },
}

local function test_a_template_that_does_not_parse_is_refused_where_it_goes_wrong()
  local wrong: {string} = {}
  for _, case in ipairs(SYNTAX) do
    local why = refused(case[1])
    local want = "t.tmpl:" .. case[2] .. ":" .. case[3] .. ": "
    if why:sub(1, #want) ~= want or not why:find(case[4], 1, true) then
      wrong[#wrong + 1] = case[1] .. " said " .. why .. ", not " .. want .. "..." .. case[4]
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
end

local function test_blank_text_may_come_before_type_and_between_type_and_mode()
  local out = compiled("\n  \n{{type T from m.t}}\n{{mode text}}\n{{.x}}")
  assert(out:find("render(d: t.T): string", 1, true), out)
  local out2 = compiled("{{type T from m.t}}\n<p>{{.x}}</p>")
  assert(out2:find('parts[#parts + 1] = "\\n"', 1, true), out2)
end

local function test_the_module_has_the_templates_lines()
  local src = "\n{{type T from m.t}}\n{{mode text}}\nL4 {{.a\n   | m.f\n}} L6\n{{if .a}}\nL8\n{{else if .b}}\nL10\n" ..
    "{{else}}\nL12\n{{end}}\n{{range .c}}{{- .d -}}\nL15\n  {{end}}\n{{with .e}}\n L18\n{{end}}\nL20"
  local out = compiled(src)
  assert(newlines(out) == newlines(src) + 1, "lines: " .. newlines(out) .. " for " .. newlines(src))
  local lines: {string} = {}
  for line in out:gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  for number = 1, 20 do
    local mark = "L" .. number
    local at = 0
    for index, line in ipairs(lines) do
      if line:find('"' .. mark, 1, true) or line:find(" " .. mark, 1, true) then
        at = index
      end
    end
    if src:find(mark .. "%D") or src:find(mark .. "$") then
      assert(at == number, mark .. " is on line " .. at .. " of the module:\n" .. out)
    end
  end
  assert(lines[#lines]:find("end return {render = render}", 1, true), "last line: " .. lines[#lines])
  assert(lines[#lines]:find('"L20" return table.concat(parts) end', 1, true), "last line: " .. lines[#lines])
end

local function test_trimmed_whitespace_keeps_its_lines()
  local src = "{{type T from m.t}}{{mode text}}\n  a\n  {{- .x -}}\n  \n b\n"
  local out = compiled(src)
  assert(newlines(out) == newlines(src) + 1, out)
end

local function test_each_loop_and_with_has_a_dot_of_its_own()
  local out = compiled(HEAD .. "{{range .a}}{{range .b}}{{with .c}}{{.d}}{{end}}{{.e}}{{end}}{{end}}{{.f}}")
  for _, name in ipairs({ "for _, d1 in", "for _, d2 in", "local d3 = " }) do
    local _, count = out:gsub(name, "")
    assert(count == 1, name .. " " .. count .. " times in " .. out)
  end
  assert(out:find("= d3.d parts[#parts + 1] = _text(v)", 1, true) and out:find("= d2.e parts[#parts + 1] = _text(v)", 1, true) and
      out:find("= d.f parts[#parts + 1] = _text(v)", 1, true), out)
end

local function test_a_dot_nothing_reads_is_not_named()
  local out = compiled(HEAD .. "{{range .a}}x{{end}}{{with .b}}y{{end}}")
  assert(out:find("for _, _ in ipairs(d.a) do", 1, true), out)
  assert(out:find("local d2 = d.b if d2 then", 1, true), out)
end

local function test_a_condition_chain_is_one_if()
  local out = compiled(HEAD .. "{{if .a}}1{{else if .b | m.f}}2{{else}}3{{end}}")
  assert(out:find("if d.a then", 1, true) and out:find("elseif m.f(d.b) then", 1, true) and
      out:find(" else ", 1, true), out)
  assert(out:find('require("m")', 1, true), out)
end

local function test_a_with_that_is_empty_runs_its_else()
  local out = compiled(HEAD .. "{{with .a}}1{{else}}2{{end}}")
  assert(out:find("do local d1 = d.a if d1 then", 1, true) and out:find("else", 1, true) and
      out:find("end end", 1, true), out)
end

local function test_a_field_named_like_a_keyword_is_indexed()
  local out = compiled(HEAD .. "{{.end}}{{.a.function}}{{.x | m.if}}")
  assert(out:find('d["end"]', 1, true) and out:find('d.a["function"]', 1, true) and
      out:find('m["if"](d.x)', 1, true), out)
end

local function test_a_module_is_named_by_its_last_word_unless_that_is_taken()
  local out = compiled("{{type Page from site.table}}\n{{.a | site.html.f}}{{.b | other.html.g}}{{.c | a.d.v}}{{.e | b.d.d1}}")
  assert(out:find('local table_2 = require("site.table")', 1, true), out)
  assert(out:find('local html = require("cosmic.html")', 1, true), out)
  assert(out:find('local html_2 = require("site.html")', 1, true), out)
  assert(out:find('local html_3 = require("other.html")', 1, true), out)
  assert(out:find('local d_2 = require("a.d")', 1, true), out)
  assert(out:find('local d_3 = require("b.d")', 1, true), out)
end

local function test_literal_text_is_quoted_byte_for_byte()
  local out = compiled(HEAD .. 'q" b\\ t\t cr\r nul\0 bell\7 é \\n')
  assert(out:find('"q\\" b\\\\ t\\t cr\\r nul\\000 bell\\007 é \\\\n"', 1, true), out)
  assert(newlines(out) == 2, out)
end

local function test_a_crlf_template_counts_lines_by_the_line_feed()
  local out = compiled("{{type T from m.t}}\r\n<p>\r\n{{.x}}\r\n</p>\r\n")
  assert(newlines(out) == 5, out)
  assert(out:find('"<p>\\r\\n"', 1, true) and out:find('"</p>\\r\\n"', 1, true), out)
end

local function test_trim_markers_drop_whitespace_and_a_dash_without_space_is_no_marker()
  local out = compiled("{{type T from m.t}}{{mode text}}\na \n {{- .x -}} \n b{{- .y}}\t{{.z -}}\n\n c")
  assert(out:find('"a"', 1, true) and out:find('"b"', 1, true) and out:find('"c"', 1, true), out)
  assert(not out:find('"a ', 1, true) and not out:find('" b', 1, true), out)
  assert(refused("{{type T from m.t}}{{mode text}}{{-.x}}"):find("not a field path", 1, true))
end

local function test_a_module_is_never_named_like_a_global()
  local names = { "string", "math", "os", "io", "utf8", "coroutine", "debug", "package", "table", "next", "pairs",
    "ipairs", "select", "print", "type", "tostring", "tonumber", "error", "assert", "pcall", "require",
    "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "rawlen", "load", "arg", "_G", "_ENV" }
  for _, name in ipairs(names) do
    local out = compiled(HEAD .. "{{.x | util." .. name .. ".f}}")
    assert(not out:find("local " .. name .. " = ", 1, true), name .. ": " .. out)
    assert(out:find('local ' .. name .. '_2 = require("util.' .. name .. '")', 1, true), name .. ": " .. out)
  end
end

local function test_a_block_inside_and_after_svg_keeps_its_place()
  compiled(HEAD .. "<svg>{{if .a}}<g></g>{{else}}<g/>{{end}}</svg>{{if .a}}<textarea>{{.x}}</textarea>{{end}}")
  local why = refused(HEAD .. "<svg>{{if .a}}</svg>{{end}}<p>")
  assert(why:find("t.tmpl:2:6: the arms of this {{if}}", 1, true), why)
end
