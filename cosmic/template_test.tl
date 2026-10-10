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
  { "<svg><a xlink:href=\"{{.x}}\"></a></svg>", "_url(" },
  { "<a data-x=\"a\" title=\"{{.x}}\">", "_attr(" },
  { "<textarea>{{.x}}</textarea>", "_rtext(" },
  { "<title>{{.x}}</TITLE>", "_rtext(" },
  { "<svg/><textarea><a href=\"{{.x}}\"></textarea>", "_rtext(" },
  { "<svg><textarea>{{.x}}</textarea></svg>", "_rtext(" },
  { "<svg><text>{{.x}}</text></svg>", "_text(" },
  { "<svg><g><a href=\"{{.x}}\"><path d=\"M0\"/></a></g></svg>", "_url(" },
  { "<svg viewBox=\"0 0 1 1\"><circle r=\"1\"/></svg><p>{{.x}}</p>", "_text(" },
  { "<svg {{if .a}}class=\"b\"{{end}}><g/></svg>{{.x}}", "_text(" },
  { "<select><option>a</option></select><svg></svg>{{.x}}", "_text(" },
  { "<svg/{{if .a}}{{end}}><textarea>{{.x}}</textarea>", "_rtext(" },
  { "<svg><style>.a { fill: red }</style></svg>{{.x}}", "_text(" },
  { "<a title=\"{{range .l}}{{.x}}{{end}}\">", "_attr(" },
  { "<img lowsrc=\"{{.x}}\" dynsrc=\"{{.x}}\">", "_url(" },
  { "<svg></svg>{{.x}}<math></math><title>{{.x}}</title>", "_text(" },
  { "<a href=\"x\" {{if .a}}class=\"b\"{{end}}>{{.x}}", "_text(" },
  { "<p {{if .a}}class=\"c\"{{else}}id=\"d\"{{end}}>{{.x}}", "_text(" },
  { "<a href=\"{{if .a}}{{.x}}{{end}}\">", "_url(" },
  { "<a href=\"{{.x}}x/a:b\">", "_url(" },
  { "<a href=\"{{.x}}\t?q=/\">", "_url(" },
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
  { "<a href=\"{{.url}}/evil.example\">", "2", "18", "protocol-relative" },
  { "<a href=\"{{.url}}\\evil.example\">", "2", "18", "protocol-relative" },
  { "<a href=\"{{.url}}\t\n/evil.example\">", "2", "18", "protocol-relative" },
  { "<a href=\"{{.url}}{{if .a}}{{end}}/evil.example\">", "2", "34", "protocol-relative" },
  { "<a href=\"{{.url}}{{if .a}}x{{end}}/evil.example\">", "2", "35", "protocol-relative" },
  { "<a href=\"{{.url}}{{if .a}}{{end}}\\evil.example\">", "2", "34", "protocol-relative" },
  { "<a href=\"{{range .l}}{{.url}}{{end}}/evil\">", "2", "22", "must begin" },
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
  { "<textarea></textarea{{.x}}><script>{{.y}}</script>", "2", "21", "complete its end tag" },
  { "<textarea></{{.x}}><script>{{.y}}</script>", "2", "13", "complete its end tag" },
  { "<textarea><{{.x}}textarea><script>{{.y}}</script>", "2", "12", "complete its end tag" },
  { "<textarea></tex{{.x}}>", "2", "16", "complete its end tag" },
  { "<textarea></TEXTAREA{{.x}}><a onclick='{{.y}}'>", "2", "21", "complete its end tag" },
  { "<textarea>{{.x}}<{{.y}}", "2", "18", "complete its end tag" },
  { "<title></title{{.x}}><script>{{.y}}</script>", "2", "15", "complete its end tag" },
  { "<title><{{.x}}title><a href={{.y}}>", "2", "9", "complete its end tag" },
  { "<textarea></textarea {{.x}}>", "2", "22", "attribute" },
  { "<svg><textarea></textarea{{.x}}></textarea></svg>", "2", "26", "complete its end tag" },
  { "<a href=\"x\">{{.x}}<a href=\"", "2", "28", "the template ends inside the value of the attribute 'href'" },
  { "<a href=\"x\">\n<a title='", "3", "11", "the template ends inside the value of the attribute 'title'" },
  { "<a ", "2", "4", "the template ends inside a tag" },
  { "<", "2", "2", "the template ends inside a tag" },
  { "a <!-- {", "2", "9", "the template ends inside a comment" },
  { "<script>{{if .a}}x{{end}}", "2", "26", "the template ends inside the text of <script>" },
  { "<textarea>x", "2", "12", "the template ends inside the text of <textarea>" },
  { "<svg><g>", "2", "9", "the template ends inside <svg>" },
  { "<svg><p>", "2", "9", "could not follow" },
  { "<select>", "2", "9", "the template ends inside <select>" },
  { "<p>x</p><select><option>a", "2", "26", "the template ends inside <select>" },
  { "<a title=x", "2", "11", "the template ends inside the value of the attribute 'title'" },
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
  { HEAD .. "{{range .a}}{{else if .b}}{{end}}", "2", "20", "nest an {{if}}" },
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
  assert(out:find("if d.a then", 1, true) and out:find("elseif _one(m.f(d.b)) then", 1, true) and
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
  assert(out:find('local type table_2 = require("site.table")', 1, true), out)
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

local function test_an_html_template_must_end_in_plain_text_since_another_splices_it_into_text()
  -- A SafeHtml goes verbatim into another template's text slot: an inner
  -- template left in a URL would make the outer one's next slot a URL
  -- the outer tracker takes for text.
  local why = refused(HEAD .. "<a href=\"")
  assert(why:find("^t.tmpl:2:10: the template ends inside the value of the attribute 'href'"), why)
  assert(why:find("in another template", 1, true), why)
  assert(refused(HEAD .. "<p>x</p>\n<b"):find("^t.tmpl:3:3: the template ends inside a tag"))
  compiled(HEAD .. "<a href=\"{{.x}}\">x</a>\n")
  compiled(HEAD .. "<svg><g/></svg>")
  compiled(HEAD .. "<select><option>a</option></select>")
  compiled("{{type T from m.t}}{{mode text}}\n<a href=\"")
end

--- What the module [`Template.compile`] makes of `src`, which has no
--- slot, renders: its types struck out, it is run as Lua.
local function rendered(src: string): string
  local lua = compiled(src):gsub("%(_: t%.T%): [%w%.]+", "()"):gsub("local parts: {string}", "local parts")
  local env: {string: any} = {
    require = function(name: string): any
      if name == "cosmic.html" then
        return { trust = function(s: string): string return s end }
      end
      return {}
    end,
    table = table,
  }
  local chunk = assert(load(lua, "=module", "t", env))
  local module = chunk() as {string: function(): string}
  return module.render()
end

local TEXT <const> = "{{type T from m.t}}{{mode text}}\n"

local function test_a_string_action_writes_its_bytes_as_literal_text()
  assert(rendered(TEXT .. '{{"{{"}}') == "\n{{")
  assert(rendered(TEXT .. '{{"}}"}}') == "\n}}")
  assert(rendered(TEXT .. 'a {{"{{.name}}"}} b') == "\na {{.name}} b")
  assert(rendered(TEXT .. '{{"{{"}}{{"}}"}}{{"{{{{"}}}}') == "\n{{}}{{{{}}")
  assert(rendered(TEXT .. '{{ "\\"\\\\" }}') == '\n"\\')
  assert(rendered(TEXT .. 'a\n {{- "{{" -}} \n b') == "\na{{b")
  assert(rendered(TEXT .. '{{""}}x') == "\nx")
  assert(rendered(TEXT .. '{{"if"}} {{"end"}} {{".a | m.f"}}') == "\nif end .a | m.f")
end

local function test_a_string_action_is_literal_text_the_html_tracker_reads()
  assert(rendered(HEAD .. '<p>{{"{{"}}.x}}</p>') == "\n<p>{{.x}}</p>")
  assert(rendered(HEAD .. '<a title="{{"{{"}}">x</a>') == '\n<a title="{{">x</a>')
  assert(rendered(HEAD .. '{{"<b>"}}x</b>') == "\n<b>x</b>")
  local slot = compiled(HEAD .. '<a{{" "}}title="{{.x}}">')
  assert(slot:find("_attr(v)", 1, true), slot)
  local closed = compiled(HEAD .. '<svg/{{""}}><p>{{.x}}</p>')
  assert(closed:find("_text(v)", 1, true), closed)
  local cases: {{string}} = {
    { '<a href="{{"/"}}{{.x}}">', "2:17: ", "must begin" },
    { '<a href="{{.x}}{{"//h"}}">', "2:19: ", "protocol-relative" },
    { '<p {{"onclick"}}="{{.x}}">', "2:19: ", "event handler" },
    { '{{"<script>"}}{{.x}}', "2:15: ", "<script>" },
    { '{{"<!--"}}{{.x}}-->', "2:11: ", "comment" },
    { '<a{{"{{"}}', "2:11: ", "ends inside a tag" },
  }
  for _, case in ipairs(cases) do
    local why = refused(HEAD .. case[1])
    assert(why:find("t.tmpl:" .. case[2], 1, true) and why:find(case[3], 1, true), case[1] .. ": " .. why)
  end
end

local function test_a_string_action_keeps_the_templates_lines()
  local src = TEXT .. "L2 {{\n  \"{{\"\n}} L4\n{{- \"x\" -}}\n\nL6"
  local out = compiled(src)
  assert(newlines(out) == newlines(src) + 1, out)
  local lines: {string} = {}
  for line in out:gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  assert(lines[2]:find('"L2 "', 1, true) and lines[3]:find('"{{"', 1, true), out)
  assert(lines[4]:find('" L4"', 1, true) and lines[5]:find('"x"', 1, true), out)
  assert(lines[7]:find('"L6"', 1, true), out)
end

local STRINGS <const>: {{string}} = {
  { HEAD .. '{{"abc}}', "2", "3", "unterminated string" },
  { HEAD .. '{{"abc', "2", "3", "unterminated string" },
  { HEAD .. '{{"a\nb"}}', "2", "3", "newline" },
  { HEAD .. '{{"a\\nb"}}', "2", "5", "escape" },
  { HEAD .. '{{"\\{"}}', "2", "4", "escape" },
  { HEAD .. '{{"a" | m.f}}', "2", "7", "string" },
  { HEAD .. '{{"a" "b"}}', "2", "7", "string" },
  { HEAD .. '{{.a | "m.f"}}', "2", "8", "string" },
  { HEAD .. '{{.a"b"}}', "2", "5", "string" },
  { HEAD .. '{{if "x"}}{{end}}', "2", "6", "string" },
  { HEAD .. '{{if .a}}{{else if "x"}}{{end}}', "2", "20", "string" },
  { HEAD .. '{{range "x"}}{{end}}', "2", "9", "string" },
  { HEAD .. '{{"x"-}}', "2", "6", "trim marker takes a space" },
  { HEAD .. '{{-"x"-}}', "2", "3", "trim marker takes a space" },
  { '{{type T "from" m.t}}', "1", "1", "write {{type" },
}

local function test_a_string_action_that_is_malformed_or_not_alone_is_refused_where_it_goes_wrong()
  local wrong: {string} = {}
  for _, case in ipairs(STRINGS) do
    local why = refused(case[1])
    local want = "t.tmpl:" .. case[2] .. ":" .. case[3] .. ": "
    if why:sub(1, #want) ~= want or not why:find(case[4], 1, true) then
      wrong[#wrong + 1] = case[1] .. " said " .. why .. ", not " .. want .. "..." .. case[4]
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
end

-- A run of text cut short, by a string action or a block that emits
-- nothing, is read as the text whole: a `<!--` in `<noscript>` text, which
-- the tracker cannot follow, is seen when its bytes come in two runs, and
-- the `<` of an end tag cut short in `<svg><style>` is not taken for text.
local function test_text_in_runs_is_read_as_it_is_whole()
  local cases: {{string}} = {
    { '<noscript><!--</noscript>{{.x}}', '<noscript>{{"<!"}}--</noscript>{{.x}}' },
    { '<noscript><!--</noscript><p title="{{.x}}">--></noscript>',
      '<noscript>{{"<!-"}}-</noscript><p title="{{.x}}">--></noscript>' },
    { '<noscript><!--</noscript>{{.x}}', '<noscript><!{{if .a}}{{end}}--</noscript>{{.x}}' },
  }
  for _, case in ipairs(cases) do
    for _, src in ipairs(case) do
      assert(refused(HEAD .. src):find("<noscript>", 1, true), src)
    end
  end
  for _, src in ipairs({ '<svg><style></style></svg>{{.x}}', '<svg><style></sty{{"le>"}}</svg>{{.x}}',
      '<svg><style></sty{{if .a}}{{end}}le></svg>{{.x}}', '<math><script></scr{{"ipt>"}}</math>{{.x}}' }) do
    assert(compiled(HEAD .. src):find("_text(v)", 1, true), src)
  end
end

--- Templates whose `<noscript>` text a browser with scripting off reads as
--- markup that puts the slot after `</noscript>` somewhere other than text:
--- in `<style>`, `<xmp>`, `<textarea>`, `<plaintext>` or a comment, or in
--- an attribute value.
local NOSCRIPT_MARKUP <const>: {string} = {
  "<noscript><style></noscript>{{.x}}</style>",
  "<noscript><STYLE></noscript>{{.x}}</style>",
  "<noscript><xmp></noscript>{{.x}}",
  "<noscript><textarea></noscript>{{.x}}",
  "<noscript><plaintext></noscript>{{.x}}",
  "<noscript><!--</noscript>{{.x}}-->",
  "<noscript><p title=\"</noscript>{{.x}}\">",
  "<noscript><img src=x onerror=\"</noscript>{{.x}}\">",
  "<noscript></p title=\"</noscript>{{.x}}\">",
  "<noscript><svg><style><p title=\"</style></noscript>{{.x}}\">",
}

--- `src` with an empty block, and then a string action of the one byte
--- there, at each place before its first slot that a cut can go: not
--- beside a brace, which would run into the action's own.
local function cuts_of(src: string): {string}
  local out: {string} = { src }
  local slot = src:find("{{", 1, true) as integer
  for at = 1, slot - 1 do
    if not src:sub(math.max(at - 1, 1), at + 1):find("[{}]") then
      out[#out + 1] = src:sub(1, at) .. "{{if .a}}{{end}}" .. src:sub(at + 1)
      local b = src:sub(at, at)
      if b ~= "\"" then
        out[#out + 1] = src:sub(1, at - 1) .. "{{\"" .. b .. "\"}}" .. src:sub(at + 1)
      end
    end
  end
  return out
end

local function test_markup_in_noscript_that_scripting_off_reads_differently_refuses_a_later_slot()
  local wrong: {string} = {}
  for _, src in ipairs(NOSCRIPT_MARKUP) do
    for _, cut in ipairs(cuts_of(src)) do
      local out, why = Template.compile(HEAD .. cut, "t.tmpl")
      if out ~= nil or not why:find("differently", 1, true) then
        wrong[#wrong + 1] = cut .. ": " .. tostring(why)
      end
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
  local why = refused(HEAD .. "<noscript>{{if .a}}<p title=\"{{end}}</noscript>{{.x}}\">")
  assert(why:find("arms", 1, true), why)
end

--- Templates whose `<noscript>` text a browser with scripting off reads as
--- markup that ends in plain text, so the slot after it stands in text
--- either way.
local NOSCRIPT_PLAIN <const>: {string} = {
  "<noscript>Turn on JavaScript.</noscript>{{.x}}",
  "<noscript>a < b, 1 <2 & 3> 2</noscript><p>{{.x}}</p>",
  "<noscript><</noscript>{{.x}}",
  "<noscript><p>Turn on <b>JavaScript</b>.</p></noscript>{{.x}}",
  "<noscript><img height=\"1\" style=\"display:none\" src=\"/tr?id=1&amp;ev=view\"/></noscript>{{.x}}",
  "<noscript><iframe src=\"/ns.html?id=1\" height=\"0\" width=\"0\"></iframe></noscript>{{.x}}",
  "<noscript><style>.js { display: none }</style></noscript>{{.x}}",
  "<noscript><link rel=\"stylesheet\" href=\"/no-js.css\"></noscript>{{.x}}",
  "<noscript><!-- no script --></noscript>{{.x}}",
  "<noscript><svg><path d=\"M0 0\"/></svg></noscript>{{.x}}",
  "<p>{{.x}}</p><noscript><p>Turn on JavaScript.</p></noscript>",
}

local function test_markup_in_noscript_that_ends_in_text_keeps_the_slots_after_it()
  local wrong: {string} = {}
  for _, src in ipairs(NOSCRIPT_PLAIN) do
    for _, cut in ipairs(cuts_of(src)) do
      local out, why = Template.compile(HEAD .. cut, "t.tmpl")
      if out == nil or not out:find("_text(v)", 1, true) then
        wrong[#wrong + 1] = cut .. ": " .. tostring(why)
      end
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
  local src = HEAD .. "<noscript>{{if .a}}<p>On</p>{{else}}<b>Off</b>{{end}}</noscript>{{.x}}"
  assert(compiled(src):find("_text(v)", 1, true), src)
end

local function test_a_block_may_add_a_whole_attribute_wherever_it_stands_in_a_tag()
  for _, src in ipairs({
      '<input{{if .a}} checked{{end}} name="n">',
      '<input {{if .a}}checked {{end}}name="n">',
      '<input type="checkbox"{{if .a}} checked{{end}} name="n">',
      '<input type="checkbox" {{if .a}}checked {{end}}name="n">',
      '<input type="checkbox"{{if .a}} checked{{end}}>',
      '<input type="checkbox" {{if .a}}checked{{end}}>',
      '<input name=n{{if .a}} checked{{end}} id="i">',
      '<input{{if .a}} checked{{end}}/>',
      '<input{{if .a}} checked{{end}} />',
      '<option{{if .a}} selected{{end}}>x</option>',
      '<input{{if .a}} disabled{{else}} required{{end}} name="n">',
      '<select{{if .a}} multiple{{end}}{{if .b}} disabled{{end}} name="n"></select>',
      '<input{{if .a}} class="c"{{end}} name="n">',
      '<input{{range .l}} checked{{end}} name="n">',
      '<input{{if .a}} checked{{end}}\n  name="n">',
      '<textarea{{if .a}} disabled{{end}}></textarea>',
  }) do
    local out = compiled(HEAD .. src .. "{{.x}}")
    assert(out:find("parts[#parts + 1] = _text(v)", 1, true), src .. ": " .. out)
  end
  local out = compiled(HEAD .. '<input{{if .a}} checked{{end}} title="{{.t}}" src="{{.u}}">')
  assert(out:find("_attr(v)", 1, true) and out:find("_url(v)", 1, true), out)
  out = compiled(HEAD .. '<img{{if .a}} hidden{{end}}{{with .w}} title="{{.t}}"{{end}} src="{{.u}}">')
  assert(out:find("_attr(v)", 1, true) and out:find("_url(v)", 1, true), out)
end

--- Text after a block that adds an attribute, which would read differently
--- after each arm, and where it is refused. Line 1 is the `{{type}}` line.
local APART <const>: {{string}} = {
  -- `checked="x"` in one arm, the tag `<input=x>` in the other.
  { '<input{{if .a}} checked{{end}}=x>', "2", "31", "reads differently" },
  { '<input{{if .a}} checked{{end}}{{"="}}x>', "2", "34", "reads differently" },
  { '<input{{if .a}} checked{{end}} =x>', "2", "32", "reads differently" },
  { '<input{{if .a}} checked{{end}}\n  =x>', "3", "3", "reads differently" },
  -- `checked` in one arm, `ked` in the other.
  { '<input {{if .a}}chec{{end}}ked>', "2", "28", "reads differently" },
  { '<input{{if .a}} checked{{end}}put>', "2", "31", "reads differently" },
  { '<input{{if .a}} name=n{{end}}/>', "2", "30", "reads differently" },
  { '<input{{range .l}} checked{{end}}=x>', "2", "34", "reads differently" },
  { '<meta{{if .a}} http-equiv{{end}} content="{{.c}}">', "2", "33", "reads differently" },
  -- The arm that names http-equiv is the one the `>` ends, not the place kept.
  { '<meta content="{{.c}}"{{if .a}}{{else}} http-equiv{{end}}>', "2", "16", "could be a redirect" },
  { '<input{{range .l}} {{end}}name=x>', "2", "27", "a block before this text" },
  -- Run again, the body's own `a` carries on the `a` the run before wrote.
  { '<input {{range .l}}a{{end}}>', "2", "20", "the {{range}} it is in" },
  { '<input{{if .a}} checked{{end}}{{.x}}>', "2", "31", "a slot" },
  { '<input{{if .a}} checked{{end}}', "2", "31", "the template ends inside a tag" },
  { '<in{{if .a}}put checked{{end}}>', "2", "4", "end in different places" },
  -- An arm that goes on with the name or value the block cut, then adds an attribute.
  { '<input a{{if .a}}checked {{end}}>', "2", "9", "end in different places" },
  { '<input name=n{{if .a}}x checked{{end}}>', "2", "14", "end in different places" },
  { '<input a{{if .a}}=x{{end}}>', "2", "9", "end in different places" },
  { '<input a {{if .a}}=x{{end}}>', "2", "10", "end in different places" },
  { '<input/{{if .a}} checked{{end}}>', "2", "8", "end in different places" },
  { '<p>{{if .a}}<input{{end}} checked>', "2", "4", "end in different places" },
  { '<a{{if .a}} href{{end}}="{{.u}}">', "2", "24", "reads differently" },
  { '<meta{{if .a}} http-equiv="refresh"{{end}} content="{{.c}}">', "2", "6", "end in different places" },
}

local function test_text_that_reads_differently_after_each_arm_of_a_block_is_refused()
  local wrong: {string} = {}
  for _, case in ipairs(APART) do
    local why = refused(HEAD .. case[1])
    local want = "t.tmpl:" .. case[2] .. ":" .. case[3] .. ": "
    if why:sub(1, #want) ~= want or not why:find(case[4], 1, true) then
      wrong[#wrong + 1] = case[1] .. " said " .. why .. ", not " .. want .. "..." .. case[4]
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
end

--- `inner` inside `depth` nested ranges, each over `.l`.
local function nested_ranges(depth: integer, inner: string): string
  return string.rep("{{range .l}}", depth) .. inner .. string.rep("{{end}}", depth)
end

-- Each range walks its body twice, so walking every body again from each
-- place would take time exponential in the depth: 64 levels would never
-- finish. The source is not loaded: Lua's limit on locals is met first
-- (see codegen's block).
local function test_deeply_nested_ranges_compile_without_walking_each_body_again_per_level()
  local out = compiled(HEAD .. "<p title=\"" .. nested_ranges(64, "{{.x}}") .. "\">" .. nested_ranges(64, "<b>{{.y}}</b>"))
  local _, attrs = out:gsub("= _attr%(v%)", "")
  local _, texts = out:gsub("= _text%(v%)", "")
  assert(attrs == 1 and texts == 1, out)
  local _, loops = out:gsub("for _, ", "")
  assert(loops == 128, loops)
end

local function test_nested_ranges_refuse_a_body_that_does_not_end_where_it_began_at_depth()
  local why = refused(HEAD .. nested_ranges(40, "<b class=\"") .. "\">")
  assert(why:find("^t.tmpl:2:469: the body of this {{range}} ends where it did not begin"), why)
  -- The innermost body ends where it began, but a second time round its
  -- URL slot no longer begins the value.
  local url = refused(HEAD .. "<a href=\"" .. nested_ranges(40, "{{.u}}") .. "\">")
  assert(url:find("^t.tmpl:2:490: a slot in a URL must begin"), url)
end

local function test_a_range_takes_an_else_run_when_the_list_is_empty()
  local out = compiled(HEAD .. "{{range .a}}<b>{{.x}}</b>{{else}}<i>{{.y}}</i>{{end}}{{.z}}")
  assert(out:find("do local d2 = d.a if d2[1] ~= nil then for _, d1 in ipairs(d2) do", 1, true), out)
  assert(out:find("end else", 1, true) and out:find("= d.y parts", 1, true) and out:find("end end", 1, true), out)
  assert(out:find("= d1.x parts", 1, true) and out:find("= d.z parts", 1, true), out)
  local unread = compiled(HEAD .. "{{range .a}}x{{else}}y{{end}}")
  assert(unread:find("do local d2 = d.a if d2[1] ~= nil then for _, _ in ipairs(d2) do", 1, true), unread)
end

local function test_a_range_else_keeps_the_templates_lines()
  local src = "{{type T from m.t}}{{mode text}}\n{{range .a}}\nL3 {{.x}}\n{{else}}\nL5 {{.y}}\n{{end}}\nL7"
  local out = compiled(src)
  assert(newlines(out) == newlines(src) + 1, out)
  local lines: {string} = {}
  for line in out:gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  assert(lines[2]:find("ipairs(d2) do", 1, true), lines[2])
  assert(lines[3]:find('"L3 "', 1, true) and lines[3]:find("d1.x", 1, true), lines[3])
  assert(lines[4]:find("end else", 1, true), lines[4])
  assert(lines[5]:find('"L5 "', 1, true) and lines[5]:find("d.y", 1, true), lines[5])
  assert(lines[6]:find("end end", 1, true), lines[6])
  assert(lines[7]:find('"L7"', 1, true), lines[7])
end

local function test_a_range_else_is_judged_from_where_the_range_begins()
  local slots = compiled(HEAD .. "<p title=\"{{range .l}}{{.a}}{{else}}{{.b}}{{end}}\">{{range .l}}<b>{{.c}}</b>" ..
      "{{else}}<i>{{.d}}</i>{{end}}{{.e}}")
  local _, attrs = slots:gsub("= _attr%(v%)", "")
  local _, texts = slots:gsub("= _text%(v%)", "")
  assert(attrs == 2 and texts == 3, slots)
  -- The else arm begins the URL value, as the loop's first time round does.
  local url = compiled(HEAD .. "<a href=\"{{range .l}}/a{{else}}{{.u}}{{end}}\">")
  assert(url:find("_url(v)", 1, true), url)
  local arms = refused(HEAD .. "{{range .l}}x{{else}}<b class=\"{{end}}\">")
  assert(arms:find("^t.tmpl:2:1: the arms of this {{range}} end in different places"), arms)
  local body = refused(HEAD .. "{{range .l}}<b class=\"{{else}}<b class=\"{{end}}\">")
  assert(body:find("^t.tmpl:2:1: the body of this {{range}} ends where it did not begin"), body)
  -- The body runs again after itself, so its URL slot no longer begins the
  -- value; the else arm does not run again.
  local again = refused(HEAD .. "<a href=\"{{range .l}}{{.u}}{{else}}/x{{end}}\">")
  assert(again:find("^t.tmpl:2:22: a slot in a URL must begin"), again)
  -- What follows is judged from where the else arm leaves off too.
  local after = refused(HEAD .. "<a href=\"{{range .l}}x{{else}}{{.u}}{{end}}/evil\">")
  assert(after:find("^t.tmpl:2:44: ") and after:find("protocol-relative", 1, true), after)
end

local function test_a_range_takes_one_else_and_no_else_if()
  local chained = refused(HEAD .. "{{range .a}}{{else if .b}}{{end}}")
  assert(chained:find("^t.tmpl:2:20: {{else}} in a {{range}} takes nothing: nest an {{if}}"), chained)
  local twice = refused(HEAD .. "{{range .a}}{{else}}{{else}}{{end}}")
  assert(twice:find("^t.tmpl:2:21: {{else}} after {{else}}"), twice)
end

local function test_the_records_module_is_required_for_its_types_unless_a_stage_reads_it()
  local typed = compiled("{{type T from m.t}}{{mode text}}{{.x}}")
  assert(typed:find('local type t = require("m.t")', 1, true), typed)
  assert(not typed:find("_one", 1, true), typed)
  local both = compiled("{{type T from m.t}}{{mode text}}{{.x | m.t.f}}")
  assert(both:find('local t = require("m.t")', 1, true), both)
  assert(not both:find("local type", 1, true), both)
  assert(both:find("local function _one<T>(v: T): T return v end", 1, true), both)
  assert(both:find("= _one(t.f(d.x))", 1, true), both)
end

local function test_dollar_is_the_render_argument_anywhere()
  local out = compiled(HEAD .. "{{range .items}}{{.name}}{{$.title}}{{with .owner}}{{$.who | m.f}}{{end}}{{end}}" ..
      "{{if $.admin}}{{$}}{{end}}")
  assert(out:find("= d1.name parts", 1, true) and out:find("= d.title parts", 1, true), out)
  assert(out:find("= _one(m.f(d.who)) parts", 1, true), out)
  assert(out:find("if d.admin then", 1, true) and out:find("= d parts", 1, true), out)
  -- Only `$` reads the argument here, so it must be named.
  local only = compiled(HEAD .. "{{$.x}}")
  assert(only:find("render(d: t.T)", 1, true) and only:find("= d.x parts", 1, true), only)
end

local function test_a_range_binds_its_element_and_its_index()
  local both = compiled(HEAD .. "{{range $i, $x := .items}}{{$i}}{{$x.name}}{{.n}}{{end}}")
  assert(both:find("for d2, d1 in ipairs(d.items) do", 1, true), both)
  assert(both:find("= d2 parts", 1, true) and both:find("= d1.name parts", 1, true) and
      both:find("= d1.n parts", 1, true), both)
  local element = compiled(HEAD .. "{{range $x := .items}}{{$x.name}}{{end}}")
  assert(element:find("for _, d1 in ipairs(d.items) do", 1, true), element)
  local index = compiled(HEAD .. "{{range $i, $x := .items}}{{$i}}{{end}}")
  assert(index:find("for d2, _ in ipairs(d.items) do", 1, true), index)
  local unread = compiled(HEAD .. "{{range $i, $x := .items}}x{{end}}")
  assert(unread:find("for _, _ in ipairs(d.items) do", 1, true), unread)
  local spaced = compiled(HEAD .. "{{range $i,$x:=.items}}{{$i}}{{end}}")
  assert(spaced:find("for d2, _ in ipairs(d.items) do", 1, true), spaced)
end

local function test_a_range_with_bindings_and_an_else_reads_its_list_once()
  local out = compiled(HEAD .. "{{range $i, $x := .a | m.f}}{{$i}}{{$x}}{{else}}{{.y}}{{end}}")
  assert(out:find("do local d3 = _one(m.f(d.a)) if d3[1] ~= nil then for d2, d1 in ipairs(d3) do", 1, true), out)
  assert(out:find("end else", 1, true) and out:find("= d.y parts", 1, true), out)
end

local function test_nested_ranges_name_the_root_and_each_enclosing_element_and_index()
  local out = compiled(HEAD .. "{{range $i, $x := .a}}{{range $j, $y := $x.b}}{{$x.n}}{{$i}}{{$y}}{{$j}}" ..
      "{{$.t}}{{.}}{{end}}{{end}}")
  assert(out:find("for d2, d1 in ipairs(d.a) do", 1, true), out)
  assert(out:find("for d4, d3 in ipairs(d1.b) do", 1, true), out)
  for _, read in ipairs({ "= d1.n parts", "= d2 parts", "= d3 parts", "= d4 parts", "= d.t parts" }) do
    assert(out:find(read, 1, true), read .. " in " .. out)
  end
end

local function test_a_with_keeps_the_root_and_the_enclosing_bindings()
  local out = compiled(HEAD .. "{{range $i, $x := .a}}{{with .w}}{{.}}{{$x}}{{$i}}{{$.t}}{{end}}{{end}}")
  assert(out:find("do local d3 = d1.w if d3 then", 1, true), out)
  assert(out:find("= d3 parts", 1, true) and out:find("= d1 parts", 1, true) and out:find("= d2 parts", 1, true) and
      out:find("= d.t parts", 1, true), out)
end

local function test_a_binding_is_never_named_like_a_generated_name_or_a_module()
  local names = { "html", "d", "d1", "v", "parts", "render", "_one", "_text", "T", "m", "end", "_" }
  for _, name in ipairs(names) do
    local out = compiled(HEAD .. "{{range $" .. name .. " := .l}}{{$" .. name .. " | m.f}}{{end}}")
    assert(out:find("for _, d1 in ipairs(d.l) do", 1, true), name .. ": " .. out)
    assert(out:find("= _one(m.f(d1)) parts", 1, true), name .. ": " .. out)
    assert(not out:find("local " .. name .. " ", 1, true) or name == "m" or name == "html", name .. ": " .. out)
  end
end

local function test_bindings_keep_the_templates_lines()
  local src = "{{type T from m.t}}{{mode text}}\n{{range $i,\n  $x := .a}}\nL4 {{$i}}\n{{else}}\nL6 {{$.y}}\n{{end}}\nL8"
  local out = compiled(src)
  assert(newlines(out) == newlines(src) + 1, out)
  local lines: {string} = {}
  for line in out:gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  assert(lines[2]:find("for d2, _ in ipairs(d3) do", 1, true), lines[2])
  assert(lines[4]:find('"L4 "', 1, true) and lines[4]:find("= d2 ", 1, true), lines[4])
  assert(lines[6]:find('"L6 "', 1, true) and lines[6]:find("= d.y ", 1, true), lines[6])
  assert(lines[8]:find('"L8"', 1, true), lines[8])
end

--- Template source, the line and column it is refused at, and what the
--- reason says, for variables.
local VARIABLE_REFUSALS <const>: {{string}} = {
  { HEAD .. "{{$x}}", "2", "3", "'$x' is not declared here" },
  { HEAD .. "{{range $x := .l}}{{$y.a}}{{end}}", "2", "21", "'$y' is not declared here" },
  { HEAD .. "{{range $item := .l}}\n  {{$itme.name}}{{end}}", "3", "5", "'$itme' is not declared here" },
  { HEAD .. "{{range $x := .l}}{{.}}{{else}}{{$x}}{{end}}", "2", "34", "'$x' is not declared here" },
  { HEAD .. "{{range $i, $x := .l}}{{else}}{{$i}}{{end}}", "2", "33", "'$i' is not declared here" },
  { HEAD .. "{{range $x := .l}}{{end}}{{$x}}", "2", "28", "'$x' is not declared here" },
  { HEAD .. "{{if .a}}{{range $x := .l}}{{end}}{{$x}}{{end}}", "2", "37", "'$x' is not declared here" },
  { HEAD .. "{{range $x := .l}}{{end}}{{range $x := .l}}{{$x}}{{end}}", "2", "1", "" },
  { HEAD .. "{{range $x := .l}}{{range $x := .m}}{{end}}{{end}}", "2", "27", "'$x' is already declared at 2:9" },
  { HEAD .. "{{range $x, $x := .l}}{{end}}", "2", "13", "'$x' is already declared at 2:9" },
  { HEAD .. "{{range $x := $x.l}}{{end}}", "2", "15", "'$x' is not declared here" },
  { HEAD .. "{{with $x := .w}}{{end}}", "2", "11", "only {{range}} binds" },
  { HEAD .. "{{if $x := .w}}{{end}}", "2", "9", "only {{range}} binds" },
  { HEAD .. "{{$x := .w}}", "2", "6", "only {{range}} binds" },
  { HEAD .. "{{.a | m.f, .b}}", "2", "11", "unexpected ','" },
  { HEAD .. "{{.a,b}}", "2", "5", "unexpected ','" },
  { HEAD .. "{{range $i := $x := .a}}{{end}}", "2", "18", "unexpected ':=': a range binds once" },
  { HEAD .. "{{range $x := .a := .b}}{{end}}", "2", "18", "unexpected ':=': a range binds once" },
  { HEAD .. "{{range .a := .b}}{{end}}", "2", "12", "unexpected ':=': a range binds once" },
  { HEAD .. "{{range $ := .l}}{{end}}", "2", "9", "'$' is not a name to bind" },
  { HEAD .. "{{range $x.a := .l}}{{end}}", "2", "9", "'$x.a' is not a name to bind" },
  { HEAD .. "{{range $x .l}}{{end}}", "2", "12", "expected := after $x" },
  { HEAD .. "{{range $x $y}}{{end}}", "2", "12", "expected := after $x" },
  { HEAD .. "{{range $i, $x .l}}{{end}}", "2", "16", "expected := after $x" },
  { HEAD .. "{{range $i, .l}}{{end}}", "2", "13", "expected a variable to bind" },
  { HEAD .. "{{range $i, $x, $y := .l}}{{end}}", "2", "15", "expected := after $x" },
  { HEAD .. "{{range $x :=}}{{end}}", "2", "1", "expected a value" },
  { HEAD .. "{{range := .l}}{{end}}", "2", "9", "not a field path" },
  { HEAD .. "{{$.}}", "2", "3", "not a variable" },
  { HEAD .. "{{$x..a}}", "2", "3", "not a variable" },
  { HEAD .. "{{$1}}", "2", "3", "not a variable" },
  { HEAD .. "{{$$}}", "2", "3", "not a variable" },
  { HEAD .. "{{.a | $.f}}", "2", "8", "module.path.func" },
}

local function test_a_variable_out_of_scope_or_misspelled_is_refused_where_it_stands()
  local wrong: {string} = {}
  for _, case in ipairs(VARIABLE_REFUSALS) do
    local out, why = Template.compile(case[1], "t.tmpl")
    if case[4] == "" then
      if out == nil then
        wrong[#wrong + 1] = case[1] .. " was refused: " .. why
      end
    else
      local want = "t.tmpl:" .. case[2] .. ":" .. case[3] .. ": "
      if out ~= nil or why:sub(1, #want) ~= want or not why:find(case[4], 1, true) then
        wrong[#wrong + 1] = case[1] .. " said " .. tostring(why) .. ", not " .. want .. "..." .. case[4]
      end
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
end
