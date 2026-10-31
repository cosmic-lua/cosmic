local Template = require("cosmic.template")

local HEAD <const> = "{{type T from m.t}}\n"

local record Expect source: string want: string end

local record Refusal source: string line: string column: string reason: string end

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

local SLOTS <const>: {Expect} = {
  { source = "<p>{{.x}}</p>", want = "_text(" },
  { source = "a < b {{.x}}", want = "_text(" },
  { source = "<a title=\"{{.x}}\">", want = "_attr(" },
  { source = "<a title='{{.x}}'>", want = "_attr(" },
  { source = "<a TITLE = \"{{.x}}\" >", want = "_attr(" },
  { source = "<a href=\"{{.x}}\">", want = "_url(" },
  { source = "<A HREF='{{.x}}'>", want = "_url(" },
  { source = "<a  href  =  \"  {{.x}}\">", want = "_url(" },
  { source = "<img alt=\"x\" src=\"{{.x}}\">", want = "_url(" },
  { source = "<form action=\"{{.x}}\">", want = "_url(" },
  { source = "<button formaction=\"{{.x}}\">", want = "_url(" },
  { source = "<svg><a xlink:href=\"{{.x}}\"></a></svg>", want = "_url(" },
  { source = "<a data-x=\"a\" title=\"{{.x}}\">", want = "_attr(" },
  { source = "<textarea>{{.x}}</textarea>", want = "_rtext(" },
  { source = "<title>{{.x}}</TITLE>", want = "_rtext(" },
  { source = "<svg/><textarea><a href=\"{{.x}}\"></textarea>", want = "_rtext(" },
  { source = "<svg><textarea>{{.x}}</textarea></svg>", want = "_rtext(" },
  { source = "<svg><text>{{.x}}</text></svg>", want = "_ftext(" },
  { source = "<math>{{.x}}</math>", want = "_ftext(" },
  { source = "<svg><g>{{if .a}}<g/>{{end}}{{.x}}</g></svg>", want = "_ftext(" },
  { source = "<select>{{.x}}</select>", want = "_ftext(" },
  { source = "<select><option>{{.x}}</option></select>", want = "_ftext(" },
  { source = "<select><option title=\"{{.x}}\">a</option></select>", want = "_attr(" },
  { source = "<select><textarea>{{.x}}</textarea></select>", want = "_rtext(" },
  { source = "<svg><g><a href=\"{{.x}}\"><path d=\"M0\"/></a></g></svg>", want = "_url(" },
  { source = "<svg viewBox=\"0 0 1 1\"><circle r=\"1\"/></svg><p>{{.x}}</p>", want = "_text(" },
  { source = "<svg {{if .a}}class=\"b\"{{end}}><g/></svg>{{.x}}", want = "_text(" },
  { source = "<select><option>a</option></select><svg></svg>{{.x}}", want = "_text(" },
  { source = "<svg/{{if .a}}{{end}}><textarea>{{.x}}</textarea>", want = "_rtext(" },
  { source = "<svg><style>.a { fill: red }</style></svg>{{.x}}", want = "_text(" },
  { source = "<a title=\"{{range .l}}{{.x}}{{end}}\">", want = "_attr(" },
  { source = "<img lowsrc=\"{{.x}}\" dynsrc=\"{{.x}}\">", want = "_url(" },
  { source = "<svg></svg>{{.x}}<math></math><title>{{.x}}</title>", want = "_text(" },
  { source = "<a href=\"x\" {{if .a}}class=\"b\"{{end}}>{{.x}}", want = "_text(" },
  { source = "<p {{if .a}}class=\"c\"{{else}}id=\"d\"{{end}}>{{.x}}", want = "_text(" },
  { source = "<a href=\"{{if .a}}{{.x}}{{end}}\">", want = "_url(" },
  { source = "<a href=\"{{.x}}x/a:b\">", want = "_url(" },
  { source = "<a href=\"{{.x}}\t?q=/\">", want = "_url(" },
  { source = "<a href=\"{{.x}}?q=a:b#c:d\">", want = "_url(" },
  { source = "<meta name=\"d\" content=\"{{.x}}\">", want = "_attr(" },
  { source = "<meta content=\"{{.x}}\" name=\"d\">", want = "_attr(" },
  { source = "<iframe></iframe>{{.x}}<noscript></noscript>{{.x}}<xmp></xmp>{{.x}}", want = "_text(" },
  { source = "<script>var a = 1 < 2;</script>{{.x}}", want = "_text(" },
  { source = "<style>a > b {}</STYLE >{{.x}}", want = "_text(" },
  { source = "<script><!-- </script>{{.x}}", want = "_text(" },
  { source = "<!-- c -->{{.x}}", want = "_text(" },
  { source = "<!--> {{.x}}", want = "_text(" },
  { source = "<!---> {{.x}}", want = "_text(" },
  { source = "<!-- a --!> {{.x}}", want = "_text(" },
  { source = "<!DOCTYPE html>{{.x}}", want = "_text(" },
  { source = "<a href=\"a\" title=\"{{.x}}\">", want = "_attr(" },
  { source = "<a href=x title=\"{{.x}}\">", want = "_attr(" },
  { source = "<br/>{{.x}}", want = "_text(" },
  { source = "<svg><a href=\"{{.x}}\"></a></svg>", want = "_url(" },
  { source = "<a title=\"a>b\">{{.x}}", want = "_text(" },
}

local function test_each_slot_is_escaped_for_the_place_it_stands_in()
  for _, case in ipairs(SLOTS) do
    local out = compiled(HEAD .. case.source)
    assert(out:find(case.want, 1, true), case.source .. " did not use " .. case.want)
    for _, other in ipairs({ "_text(", "_ftext(", "_attr(", "_url(" }) do
      if other ~= case.want then
        local _, uses = out:gsub("parts%[#parts %+ 1%] = " .. other:gsub("%p", "%%%0"), "")
        assert(uses == 0, case.source .. " used " .. other)
      end
    end
  end
end

--- Template source, the line and column it is refused at, and what the
--- reason says. Line 1 is the `{{type}}` line.
local REFUSALS <const>: {Refusal} = {
  { source = "<a href={{.x}}>", line = "2", column = "9", reason = "unquoted" },
  { source = "<a title=x{{.x}}>", line = "2", column = "11", reason = "unquoted" },
  { source = "<{{.x}}>", line = "2", column = "2", reason = "tag name" },
  { source = "<di{{.x}}>", line = "2", column = "4", reason = "tag name" },
  { source = "</{{.x}}>", line = "2", column = "3", reason = "tag name" },
  { source = "<a {{.x}}>", line = "2", column = "4", reason = "attribute" },
  { source = "<a b{{.x}}=1>", line = "2", column = "5", reason = "attribute" },
  { source = "<a b {{.x}}>", line = "2", column = "6", reason = "attribute" },
  { source = "<a b=\"c\"{{.x}}>", line = "2", column = "9", reason = "attribute" },
  { source = "<a onclick=\"{{.x}}\">", line = "2", column = "13", reason = "event handler" },
  { source = "<a ONMOUSEOVER='{{.x}}'>", line = "2", column = "17", reason = "event handler" },
  { source = "<a style=\"{{.x}}\">", line = "2", column = "11", reason = "'style'" },
  { source = "<iframe srcdoc=\"{{.x}}\">", line = "2", column = "17", reason = "'srcdoc'" },
  { source = "<img srcset=\"{{.x}}\">", line = "2", column = "14", reason = "list of URLs" },
  { source = "<a ping=\"{{.x}}\">", line = "2", column = "10", reason = "list of URLs" },
  { source = "<meta http-equiv=\"refresh\" content=\"0;{{.x}}\">", line = "2", column = "39", reason = "<meta>" },
  { source = "<!-- {{.x}} -->", line = "2", column = "6", reason = "comment" },
  { source = "<!--{{.x}}-->", line = "2", column = "5", reason = "comment" },
  { source = "<!{{.x}}>", line = "2", column = "3", reason = "comment" },
  { source = "<!-{{.x}}>", line = "2", column = "4", reason = "comment" },
  { source = "<?php {{.x}} ?>", line = "2", column = "7", reason = "comment" },
  { source = "</ {{.x}}>", line = "2", column = "4", reason = "comment" },
  { source = "<!-- a -- {{.x}}", line = "2", column = "11", reason = "comment" },
  { source = "<script>{{.x}}</script>", line = "2", column = "9", reason = "<script>" },
  { source = "<a =\"{{.x}}\">", line = "2", column = "6", reason = "attribute" },
  { source = "<svg><p><textarea>{{.x}}</textarea>", line = "2", column = "19", reason = "differently" },
  { source = "<svg><div></div><textarea>{{.x}}", line = "2", column = "27", reason = "differently" },
  { source = "<svg><br><textarea>{{.x}}", line = "2", column = "20", reason = "differently" },
  { source = "<svg><font size=1><textarea>{{.x}}", line = "2", column = "29", reason = "differently" },
  { source = "<select><svg><textarea>{{.x}}", line = "2", column = "24", reason = "differently" },
  { source = "<frameset><title></title>{{.x}}", line = "2", column = "26", reason = "differently" },
  { source = "<math><svg></math><textarea>{{.x}}", line = "2", column = "29", reason = "differently" },
  { source = "<svg><math></svg><textarea>{{.x}}", line = "2", column = "28", reason = "differently" },
  { source = "<svg></math><textarea>{{.x}}", line = "2", column = "23", reason = "differently" },
  { source = "<svg>{{if .a}}<p>{{end}}<textarea>{{.x}}", line = "2", column = "6", reason = "the arms" },
  { source = "<svg><![CDATA[ > <!-- ]]><a href=\" --> {{.p}}\">", line = "2", column = "40", reason = "differently" },
  { source = "<svg {{if .a}}/{{end}}><style><a href=\"</style>{{.p}}\">", line = "2", column = "6", reason = "the arms" },
  { source = "<svg><foreignObject><div></svg></div></foreignObject><style><a href=\"</style>{{.p}}\">", line = "2", column = "78", reason = "differently" },
  { source = "<svg><!-- c --></svg>{{.x}}", line = "2", column = "22", reason = "differently" },
  { source = "<svg><g></svg>{{.x}}", line = "2", column = "15", reason = "differently" },
  { source = "<svg><a></g></a></svg>{{.x}}", line = "2", column = "23", reason = "differently" },
  { source = "<svg><desc></desc></svg>{{.x}}", line = "2", column = "25", reason = "differently" },
  { source = "<math><mi></mi></math>{{.x}}", line = "2", column = "23", reason = "differently" },
  { source = "<svg><?x ?></svg>{{.x}}", line = "2", column = "18", reason = "differently" },
  { source = "<svg><p></p></svg>{{.x}}", line = "2", column = "19", reason = "differently" },
  { source = "<svg><svg></svg><textarea><a href=\"{{.x}}\">", line = "2", column = "36", reason = "differently" },
  { source = "<svg><textarea><a title=\"{{.x}}\">", line = "2", column = "26", reason = "differently" },
  { source = "<svg><textarea></svg>{{.x}}", line = "2", column = "22", reason = "differently" },
  { source = "<svg><script><!-- </script>{{.x}}", line = "2", column = "28", reason = "differently" },
  { source = "<svg><style><b></style>{{.x}}", line = "2", column = "24", reason = "differently" },
  { source = "<noscript><!-- </noscript>{{.x}}", line = "2", column = "27", reason = "differently" },
  { source = "<plaintext></plaintext>{{.x}}", line = "2", column = "24", reason = "<plaintext>" },
  { source = "<a href=\"{{.url}}/evil.example\">", line = "2", column = "18", reason = "protocol-relative" },
  { source = "<a href=\"{{.url}}\\evil.example\">", line = "2", column = "18", reason = "protocol-relative" },
  { source = "<a href=\"{{.url}}\t\n/evil.example\">", line = "2", column = "18", reason = "protocol-relative" },
  { source = "<a href=\"{{.url}}{{if .a}}{{end}}/evil.example\">", line = "2", column = "34", reason = "protocol-relative" },
  { source = "<a href=\"{{.url}}{{if .a}}x{{end}}/evil.example\">", line = "2", column = "35", reason = "protocol-relative" },
  { source = "<a href=\"{{.url}}{{if .a}}{{end}}\\evil.example\">", line = "2", column = "34", reason = "protocol-relative" },
  { source = "<a href=\"{{range .l}}{{.url}}{{end}}/evil\">", line = "2", column = "22", reason = "fixes where the URL goes" },
  { source = "<a href=\"{{.url}}{{.p}}/evil.example\">", line = "2", column = "18", reason = "follows a whole-URL slot" },
  { source = "<a href=\"{{.url}}{{.p}}:x\">", line = "2", column = "18", reason = "follows a whole-URL slot" },
  { source = "<a href=\"{{.x}}&colon;alert(1)\">", line = "2", column = "16", reason = "complete a scheme" },
  { source = "<a href=\"{{.x}}&#58;alert(1)\">", line = "2", column = "16", reason = "complete a scheme" },
  { source = "<meta charset=\"{{.x}}\">", line = "2", column = "16", reason = "charset" },
  { source = "<script type=\"{{.x}}\">", line = "2", column = "15", reason = "<script>" },
  { source = "<object classid=\"{{.x}}\">", line = "2", column = "18", reason = "<object>" },
  { source = "<applet codebase=\"{{.x}}\">", line = "2", column = "19", reason = "<applet>" },
  { source = "<a href=\"{{range .l}}{{.x}}{{end}}\">", line = "2", column = "22", reason = "fixes where the URL goes" },
  { source = "<a href=\"{{range .l}}{{.x}}:{{end}}\">", line = "2", column = "28", reason = "complete a scheme" },
  { source = "<svg><script>{{.x}}</script>", line = "2", column = "14", reason = "<script>" },
  { source = "<svg><g><a title=x{{.x}}", line = "2", column = "19", reason = "unquoted" },
  { source = "<svg><foreignObject>{{.x}}</foreignObject></svg>", line = "2", column = "21", reason = "differently" },
  { source = "<svg><desc>{{.x}}</desc></svg>", line = "2", column = "12", reason = "differently" },
  { source = "<svg><title>{{.x}}</title></svg>", line = "2", column = "13", reason = "differently" },
  { source = "<svg><svg></svg><title>{{.x}}</title>", line = "2", column = "24", reason = "differently" },
  { source = "<math><annotation-xml>{{.x}}</annotation-xml>", line = "2", column = "23", reason = "differently" },
  { source = "<math><mi><a title=\"{{.x}}\">", line = "2", column = "21", reason = "differently" },
  { source = "<svg><set attributeName=\"href\" to=\"{{.x}}\">", line = "2", column = "36", reason = "animate" },
  { source = "<svg><ANIMATE values=\"{{.x}}\">", line = "2", column = "23", reason = "animate" },
  { source = "<animateMotion path=\"{{.x}}\">", line = "2", column = "22", reason = "animate" },
  { source = "<xmp>{{.x}}</xmp>", line = "2", column = "6", reason = "<xmp>" },
  { source = "<iframe>{{.x}}</iframe>", line = "2", column = "9", reason = "<iframe>" },
  { source = "<noscript>{{.x}}</noscript>", line = "2", column = "11", reason = "<noscript>" },
  { source = "<noembed>{{.x}}", line = "2", column = "10", reason = "<noembed>" },
  { source = "<noframes>{{.x}}", line = "2", column = "11", reason = "<noframes>" },
  { source = "<plaintext>{{.x}}", line = "2", column = "12", reason = "<plaintext>" },
  { source = "<meta http-equiv=\"refresh\" content=\"{{.x}}\">", line = "2", column = "37", reason = "http-equiv" },
  { source = "<meta content=\"{{.x}}\" http-equiv=\"refresh\">", line = "2", column = "16", reason = "http-equiv" },
  { source = "<meta content=\"{{.x}}\" HTTP-EQUIV=refresh>", line = "2", column = "16", reason = "http-equiv" },
  { source = "<meta content=\"{{.x}}\" http-equiv=\"refresh\"><p>x</p>", line = "2", column = "16", reason = "http-equiv" },
  { source = "<a href=\"{{.p}}:alert(1)\">", line = "2", column = "16", reason = "complete a scheme" },
  { source = "<a href=\"{{.p}}java\nscript:x\">", line = "2", column = "16", reason = "complete a scheme" },
  { source = "<a href=\"{{.p}}{{if .a}}:x{{end}}\">", line = "2", column = "25", reason = "complete a scheme" },
  { source = "<a href=\"{{.p}}\"><b>x</b></a>{{if .a}}<a href=\"{{.q}}:{{end}}", line = "2", column = "54", reason = "complete a scheme" },
  { source = "<SCRIPT type=\"x\">a{{.x}}", line = "2", column = "19", reason = "<script>" },
  { source = "<style>{{.x}}</style>", line = "2", column = "8", reason = "<style>" },
  { source = "<script><!-- <script> </script> {{.x}} </script>", line = "2", column = "33", reason = "<script>" },
  { source = "<script>\n{{.x}}", line = "3", column = "1", reason = "<script>" },
  { source = "<script/>{{.x}}", line = "2", column = "10", reason = "<script>" },
  { source = "<a href=\"java{{.x}}\">", line = "2", column = "14", reason = "fixes where the URL goes" },
  { source = "<a href=\"a{{.x}}\">", line = "2", column = "11", reason = "fixes where the URL goes" },
  { source = "<a href=\"x &{{.x}}\">", line = "2", column = "13", reason = "fixes where the URL goes" },
  { source = "<a href=\"java&#115;cript:{{.x}}\">", line = "2", column = "26", reason = "fixes where the URL goes" },
  { source = "<a href=\"&sol;{{.x}}\">", line = "2", column = "15", reason = "fixes where the URL goes" },
  { source = "<a href=\"javascript:{{.x}}\">", line = "2", column = "21", reason = "fixes where the URL goes" },
  { source = "<a href=\"data:text/html,{{.x}}\">", line = "2", column = "25", reason = "fixes where the URL goes" },
  { source = "<a href=\"tel:{{.x}}\">", line = "2", column = "14", reason = "fixes where the URL goes" },
  { source = "<a href=\"//{{.x}}\">", line = "2", column = "12", reason = "fixes where the URL goes" },
  { source = "<a href=\"\\\\{{.x}}\">", line = "2", column = "12", reason = "fixes where the URL goes" },
  { source = "<a href=\"https://{{.x}}/a\">", line = "2", column = "18", reason = "fixes where the URL goes" },
  { source = "<a href=\"https:{{.x}}\">", line = "2", column = "16", reason = "fixes where the URL goes" },
  { source = "<a href=\"https://host{{.x}}\">", line = "2", column = "22", reason = "fixes where the URL goes" },
  { source = "<a href=\"{{if .a}}/x/{{else}}y{{end}}{{.z}}\">", line = "2", column = "38", reason = "fixes where the URL goes" },
  { source = "<a href=\"{{if .a}}https://{{else}}/x/{{end}}{{.z}}\">", line = "2", column = "45", reason = "fixes where the URL goes" },
  { source = "<a href=\"/{{if .a}}{{end}}/{{.x}}\">", line = "2", column = "28", reason = "fixes where the URL goes" },
  { source = "<a href=\"/a/.{{.x}}\">", line = "2", column = "14", reason = "'..' segment" },
  { source = "<a href=\"/a/%{{.x}}\">", line = "2", column = "14", reason = "'..' segment" },
  { source = "<a href=\"/a/%2{{.x}}\">", line = "2", column = "15", reason = "'..' segment" },
  { source = "<a href=\"/a/{{.x}}/.{{if .a}}{{end}}.{{.y}}\">", line = "2", column = "38", reason = "'..' segment" },
  { source = "<a href=\"/a/..\t{{.x}}\">", line = "2", column = "16", reason = "'..' segment" },
  { source = "<a href=\"{{.u}}.{{.x}}\">", line = "2", column = "17", reason = "follows a whole-URL slot" },
  { source = "<a hx-on:click=\"{{.x}}\">", line = "2", column = "17", reason = "would be script" },
  { source = "<a hx-on::after-request=\"{{.x}}\">", line = "2", column = "26", reason = "would be script" },
  { source = "<a hx-on-click=\"{{.x}}\">", line = "2", column = "17", reason = "would be script" },
  { source = "<a data-hx-on:click=\"{{.x}}\">", line = "2", column = "22", reason = "would be script" },
  { source = "<a HX-ON:Click=\"{{.x}}\">", line = "2", column = "17", reason = "would be script" },
  { source = "<a hx-vars=\"{{.x}}\">", line = "2", column = "13", reason = "would be script" },
  { source = "<a data-hx-vars=\"{{.x}}\">", line = "2", column = "18", reason = "would be script" },
  { source = "<a hx-vals=\"{{.x}}\">", line = "2", column = "13", reason = "{{use htmx}}" },
  { source = "<a data-hx-vals='{\"a\": \"{{.x}}\"}'>", line = "2", column = "25", reason = "{{use htmx}}" },
  { source = "<a hx-vals=\"x\" hx-get=\"/a\" hx-on:click=\"a{{if .a}}b{{end}}{{.x}}\">", line = "2", column = "59", reason = "would be script" },
  { source = "<script src=\"{{.x}}\">", line = "2", column = "14", reason = "<script>" },
  { source = "<link href=\"{{.x}}\">", line = "2", column = "13", reason = "<link>" },
  { source = "<object data=\"{{.x}}\">", line = "2", column = "15", reason = "<object>" },
  { source = "<a title=\"x\">\n<a\n  b={{.y}}>", line = "4", column = "5", reason = "unquoted" },
  { source = "<textarea></textarea{{.x}}><script>{{.y}}</script>", line = "2", column = "21", reason = "complete its end tag" },
  { source = "<textarea></{{.x}}><script>{{.y}}</script>", line = "2", column = "13", reason = "complete its end tag" },
  { source = "<textarea><{{.x}}textarea><script>{{.y}}</script>", line = "2", column = "12", reason = "complete its end tag" },
  { source = "<textarea></tex{{.x}}>", line = "2", column = "16", reason = "complete its end tag" },
  { source = "<textarea></TEXTAREA{{.x}}><a onclick='{{.y}}'>", line = "2", column = "21", reason = "complete its end tag" },
  { source = "<textarea>{{.x}}<{{.y}}", line = "2", column = "18", reason = "complete its end tag" },
  { source = "<title></title{{.x}}><script>{{.y}}</script>", line = "2", column = "15", reason = "complete its end tag" },
  { source = "<title><{{.x}}title><a href={{.y}}>", line = "2", column = "9", reason = "complete its end tag" },
  { source = "<textarea></textarea {{.x}}>", line = "2", column = "22", reason = "attribute" },
  { source = "<svg><textarea></textarea{{.x}}></textarea></svg>", line = "2", column = "26", reason = "complete its end tag" },
  { source = "<a href=\"x\">{{.x}}<a href=\"", line = "2", column = "28", reason = "the template ends inside the value of the attribute 'href'" },
  { source = "<a href=\"x\">\n<a title='", line = "3", column = "11", reason = "the template ends inside the value of the attribute 'title'" },
  { source = "<a ", line = "2", column = "4", reason = "the template ends inside a tag" },
  { source = "<", line = "2", column = "2", reason = "the template ends inside a tag" },
  { source = "a <!-- {", line = "2", column = "9", reason = "the template ends inside a comment" },
  { source = "<script>{{if .a}}x{{end}}", line = "2", column = "26", reason = "the template ends inside the text of <script>" },
  { source = "<textarea>x", line = "2", column = "12", reason = "the template ends inside the text of <textarea>" },
  { source = "<svg><g>", line = "2", column = "9", reason = "the template ends inside <svg>" },
  { source = "<svg><p>", line = "2", column = "9", reason = "could not follow" },
  { source = "<select>", line = "2", column = "9", reason = "the template ends inside <select>" },
  { source = "<p>x</p><select><option>a", line = "2", column = "26", reason = "the template ends inside <select>" },
  { source = "<a title=x", line = "2", column = "11", reason = "the template ends inside the value of the attribute 'title'" },
}

local function test_a_slot_with_no_escaping_is_refused_at_its_line_and_column()
  local wrong: mut {string} = {}
  for _, case in ipairs(REFUSALS) do
    local why = refused(HEAD .. case.source)
    local want = "t.tmpl:" .. case.line .. ":" .. case.column .. ": "
    if why:sub(1, #want) ~= want or not why:find(case.reason, 1, true) then
      wrong[#wrong + 1] = case.source .. " said " .. why .. ", not " .. want .. "..." .. case.reason
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

--- Templates whose slot stands after text that fixes the URL: a part.
local PARTS <const>: {string} = {
  "<a href=\"/items/{{.x}}\">",
  "<a href=\"/s?q={{.x}}\">",
  "<a href=\"/s#{{.x}}\">",
  "<a href=\"?q={{.x}}\">",
  "<a href=\"#{{.x}}\">",
  "<a href=\"./{{.x}}\">",
  "<a href=\"../{{.x}}\">",
  "<a href=\"items/{{.x}}\">",
  "<a href=\"a:b\" title=\"x\"><a href=' /{{.x}}'>",
  "<a href=\"//example.com/{{.x}}\">",
  "<a href=\"https://example.com/{{.x}}\">",
  "<a href=\"HTTP://example.com?q={{.x}}\">",
  "<a href=\"ht\ntps://example.com/{{.x}}\">",
  "<a href=\"mailto:{{.x}}\">",
  "<a href=\"mailto:a@b.example?subject={{.x}}\">",
  "<a href=\"/a/{{.x}}{{.y}}\">",
  "<a href=\"/a/{{.x}}/b/{{.y}}?c={{.z}}#{{.w}}\">",
  "<a href=\"{{.u}}?q={{.x}}\">",
  "<a href=\"/x/{{range .l}}{{.}}{{end}}\">",
  "<a href=\"/x/{{range .l}}{{.}}/{{end}}\">",
  "<a href=\"{{if .a}}/x/{{else}}/y/{{end}}{{.z}}\">",
  "<a href=\"{{if .a}}https://h/{{else}}/y?{{end}}{{.z}}\">",
  "<a href=\"{{.u}}?a&amp;b={{.x}}\">",
  "<a href=\"{{.u}}x#{{.x}}\">",
  "<a href=\"/s?a=1&amp;b={{.x}}\">",
  "<a href=\"/s#a&sol;{{.x}}\">",
  "<a href=\"/a/.b{{.x}}\">",
  "<a href=\"/a/b.{{.x}}\">",
  "<a href=\"/a/...{{.x}}\">",
  "<a href=\"/a/...%2e{{.x}}\">",
  "<a href=\"/a/%2e%2e%2e{{.x}}\">",
  "<a href=\"/a/..\n/{{.x}}\">",
  "<a href=\"/a%20{{.x}}\">",
  "<a href=\"/a.b/{{.x}}\">",
  "<a href=\"/a/b.{{if .a}}c{{end}}/{{.x}}\">",
  "<img src=\"/i/{{.x}}.png\">",
  "<form action=\"/f/{{.x}}\">",
  "<svg><a xlink:href=\"/a/{{.x}}\"></a></svg>",
  "<a href=\"/a/{{.x}}\">{{.y}}</a>",
  "<a href='/a/{{.x}}'>",
}

local function test_a_slot_after_text_that_fixes_the_url_is_one_part_of_it()
  for _, src in ipairs(PARTS) do
    local out = compiled(HEAD .. src)
    assert(out:find("_part(v)", 1, true), src .. ": " .. out)
  end
  local out = compiled(HEAD .. "<a href=\"/a/{{.x}}\">")
  assert(out:find("local function _part(v: string | number | html.SafeUrlPart): string", 1, true), out)
  assert(out:find("do local v: string | number | html.SafeUrlPart = d.x ", 1, true), out)
  assert(not out:find("_url(v", 1, true), out)
end

--- Templates whose part slot could, with the browser's own decoding of the
--- text before it, be a host or a dot segment, with the reason refused.
local DECODED <const>: {Expect} = {
  { source = "<a href=\"/{{.a}}&sol;{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"/{{.a}}&#47;{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"/{{.a}}&bsol;{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"/{{.a}}&#x5c;{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"/{{.a}}&Tab;/{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"/{{.a}}&NewLine;/{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"/&sol;{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"/&#9;/{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"http:&sol;/{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"http:&#47;&#47;{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"/a/&#46;&#46;{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"/a&amp;b/{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"{{if .a}}/&sol;{{else}}/x/{{end}}{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"{{if .a}}/x/{{else}}/&sol;{{end}}{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"/{{range .l}}&sol;{{end}}{{.b}}\">", want = "'&' in the path" },
  { source = "<a href=\"/x/{{range .l}}&#47;{{.i}}{{end}}\">", want = "'&' in the path" },
  { source = "<a href=\"/a/.%2e{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"/a/%2e%2e{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"/a/%2E%2E{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"/a/%2e.{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"/a/.%2E{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"/a/%2e{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"/a/.%{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"/a/%2e%2{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"/a/.{{.x}}{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"/a/.{{if .a}}{{.x}}{{end}}{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"/a/{{if .a}}.{{else}}%{{end}}{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"/a/{{if .a}}.{{else}}%{{end}}2e{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"/a/{{if .a}}.{{else}}x{{end}}.{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"/a/{{range .l}}.{{end}}{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"/a/\\.{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"?.{{.b}}\">", want = "'..' segment" },
  { source = "<a href=\"{{.u}}{{.b}}\">", want = "follows a whole-URL slot" },
  { source = "<a href=\"{{.u}}a{{.b}}\">", want = "follows a whole-URL slot" },
  { source = "<a href=\"{{.u}}.{{.b}}\">", want = "follows a whole-URL slot" },
  { source = "<a href=\"{{.u}}{{if .a}}?{{end}}{{.b}}\">", want = "follows a whole-URL slot" },
  { source = "<a href=\"{{.u}}{{if .a}}?q={{.b}}{{end}}\">", want = "" },
}

local function test_a_part_after_decoded_text_or_a_whole_url_slot_is_refused()
  for _, case in ipairs(DECODED) do
    local src, why = case.source, case.want
    local out, err = Template.compile(HEAD .. src, "t.tmpl")
    if why == "" then
      assert(out ~= nil, src .. ": " .. tostring(err))
    else
      assert(out == nil, "compiled: " .. src)
      assert(err:find(why, 1, true), src .. ": " .. err)
    end
  end
end

local function test_an_ampersand_in_a_query_or_fragment_keeps_the_part_slot()
  compiled(HEAD .. "<a href=\"/s?a=1&amp;b={{.x}}&amp;c={{.y}}\">")
  compiled(HEAD .. "<a href=\"/s#x&amp;{{.x}}\">")
  compiled(HEAD .. "<a href=\"?a&sol;{{.x}}\">")
  compiled(HEAD .. "<a href=\"{{.u}}?a&amp;{{.x}}\">")
end

local function test_a_slot_in_an_htmx_json_attribute_is_refused_without_use_htmx()
  for _, attr in ipairs({ "hx-vals", "hx-headers", "hx-request", "data-hx-headers", "DATA-HX-REQUEST", "Hx-Vals" }) do
    local why = refused(HEAD .. "<a " .. attr .. "=\"{{.x}}\">")
    assert(why:find("{{use htmx}}", 1, true), attr .. ": " .. why)
    why = refused(HEAD .. "<a " .. attr .. "='x {{.x}}'>")
    assert(why:find("{{use htmx}}", 1, true), attr .. ": " .. why)
  end
end

local function test_a_slot_in_hx_trigger_is_refused_with_and_without_use_htmx()
  for _, use in ipairs({ "", "{{use htmx}}\n" }) do
    for _, attr in ipairs({ "hx-trigger", "data-hx-trigger", "Hx-Trigger" }) do
      for _, value in ipairs({ "{{.x}}", "click[{{.x}}]", "every {{.n}}s" }) do
        local why = refused(HEAD .. use .. "<a " .. attr .. "=\"" .. value .. "\">")
        assert(why:find("'" .. attr:lower() .. "' attribute would be a trigger", 1, true), attr .. ": " .. why)
      end
    end
  end
end

--- The classes a slot has in each attribute with `{{use htmx}}`: the
--- helper its generated code writes, or "" for a refusal.
local HTMX_CLASSES <const>: {Expect} = {
  { source = "hx-get=\"{{.u}}\"", want = "_lurl" },
  { source = "hx-post=\"{{.u}}\"", want = "_lurl" },
  { source = "hx-put=\"{{.u}}\"", want = "_lurl" },
  { source = "hx-patch=\"{{.u}}\"", want = "_lurl" },
  { source = "hx-delete=\"{{.u}}\"", want = "_lurl" },
  { source = "hx-push-url=\"{{.u}}\"", want = "_lurl" },
  { source = "hx-replace-url=\"{{.u}}\"", want = "_lurl" },
  { source = "sse-connect=\"{{.u}}\"", want = "_lurl" },
  { source = "ws-connect=\"{{.u}}\"", want = "_lurl" },
  { source = "hx-get=\"/items/{{.id}}\"", want = "_part" },
  { source = "hx-delete=\"/items/{{.id}}?x={{.x}}#{{.f}}\"", want = "_part" },
  { source = "hx-push-url=\"/items/{{.id}}\"", want = "_part" },
  { source = "hx-get=\"{{.u}}?q={{.q}}\"", want = "_lurl" },
  { source = "hx-vals='{{.v}}'", want = "_json" },
  { source = "hx-headers=\"{{.v}}\"", want = "_json" },
  { source = "hx-request='{{.v}}'", want = "_json" },
  { source = "hx-target=\"#row-{{.id}}\"", want = "_sel" },
  { source = "hx-select=\".tab-{{.id}} p\"", want = "_sel" },
  { source = "hx-select-oob=\"#a-{{.id}}:outerHTML,#b-{{.id}}\"", want = "_sel" },
  { source = "hx-include=\"closest form, #f-{{.id}}\"", want = "_sel" },
  { source = "hx-indicator=\"#spin-{{.id}}\"", want = "_sel" },
  { source = "hx-disabled-elt=\"find button.b-{{.id}}\"", want = "_sel" },
  { source = "hx-sync=\"#f-{{.id}}:abort\"", want = "_sel" },
  { source = "hx-swap=\"innerHTML scroll:#top-{{.id}}:top\"", want = "" },
  { source = "hx-swap-oob=\"outerHTML:#x-{{.id}}\"", want = "_sel" },
  { source = "hx-target-422=\"#err-{{.id}}\"", want = "_sel" },
  { source = "hx-target-error=\"#err-{{.id}}\"", want = "_sel" },
  { source = "hx-confirm=\"{{.x}}\"", want = "_attr" },
  { source = "hx-prompt=\"{{.x}}\"", want = "_attr" },
  { source = "hx-boost=\"{{.x}}\"", want = "" },
  { source = "hx-params=\"{{.x}}\"", want = "" },
  { source = "hx-encoding=\"{{.x}}\"", want = "_attr" },
  { source = "hx-ext=\"{{.x}}\"", want = "" },
  { source = "hx-history=\"{{.x}}\"", want = "_attr" },
  { source = "hx-preserve=\"{{.x}}\"", want = "_attr" },
  { source = "hx-validate=\"{{.x}}\"", want = "_attr" },
  { source = "hx-disable=\"{{.x}}\"", want = "" },
  { source = "hx-disinherit=\"{{.x}}\"", want = "_attr" },
  { source = "sse-swap=\"{{.x}}\"", want = "_attr" },
  { source = "ws-send=\"{{.x}}\"", want = "_attr" },
  { source = "hx-trigger=\"{{.x}}\"", want = "" },
  { source = "hx-vars=\"{{.x}}\"", want = "" },
  { source = "hx-on:click=\"{{.x}}\"", want = "" },
  { source = "hx-ws=\"{{.x}}\"", want = "" },
}

--- The helpers `out` calls for the slots in its body, in order.
local function helpers_called(out: string): {string}
  local calls: mut {string} = {}
  for name in out:gmatch("parts%[#parts %+ 1%] = (_[a-z]+)%(v%)") do
    calls[#calls + 1] = name
  end
  return calls
end

local function test_with_use_htmx_each_attribute_has_its_class()
  for _, case in ipairs(HTMX_CLASSES) do
    local src = HEAD .. "{{use htmx}}\n<a " .. case.source .. ">"
    if case.want == "" then
      refused(src)
    else
      local calls = helpers_called(compiled(src))
      assert(calls[1] == case.want, case.source .. ": " .. table.concat(calls, " "))
    end
  end
end

local function test_without_use_htmx_only_the_script_and_json_attributes_are_refused()
  for _, case in ipairs(HTMX_CLASSES) do
    local src = HEAD .. "<a " .. case.source .. ">"
    local out, why = Template.compile(src, "t.tmpl")
    local attr = case.source:match("^[%w:-]+")
    if attr == "hx-trigger" or attr == "hx-vars" or attr == "hx-on:click" or attr == "hx-vals" or
        attr == "hx-headers" or attr == "hx-request" or attr == "hx-ws" then
      assert(out == nil, case.source)
      assert(why:find("'" .. attr .. "' attribute", 1, true), why)
    else
      -- A plain attribute, attribute-escaped as before.
      assert(out ~= nil, case.source .. ": " .. why)
      for _, call in ipairs(helpers_called(out)) do
        assert(call == "_attr", case.source .. ": " .. call)
      end
    end
  end
end

local function test_every_attribute_is_classified_alike_in_upper_case_and_with_data()
  for _, case in ipairs(HTMX_CLASSES) do
    local name, rest = case.source:match("^([%w:-]+)(.*)$")
    for _, spelled in ipairs({ name:upper(), "data-" .. name, "DATA-" .. name:upper() }) do
      local src = HEAD .. "{{use htmx}}\n<a " .. spelled .. rest .. ">"
      if case.want == "" then
        refused(src)
      else
        assert(helpers_called(compiled(src))[1] == case.want, spelled .. rest)
      end
    end
  end
end

local function test_an_hx_swap_spec_and_the_attributes_that_change_a_subtree_are_the_authors()
  -- U+00A0 passes the attribute escaper raw and splits a swap spec in htmx.
  for _, src in ipairs({
      "<a hx-swap=\"innerHTML scroll:#{{.id}}:top\">",
      "<a hx-swap=\"swap:{{.t}}\">",
      "<a hx-swap=\"{{.style}}\">",
      "<a hx-ext=\"ignore:{{.x}}\">",
      "<a hx-disable=\"{{.x}}\">",
      "<a hx-boost=\"{{.x}}\">",
      "<a hx-params=\"{{.x}}\">",
  }) do
    local why = refused(HEAD .. "{{use htmx}}\n" .. src)
    assert(why:find("author", 1, true), src .. ": " .. why)
    -- Literal text is the author's own.
    compiled(HEAD .. "{{use htmx}}\n" .. src:gsub("{{[^}]*}}", "x"))
  end
end

local function test_the_attribute_forms_htmx_reads_are_classified_alike()
  for _, form in ipairs({ "hx-vals", "data-hx-vals", "HX-VALS", "Data-Hx-Vals", "dAtA-hX-vAlS" }) do
    local calls = helpers_called(compiled(HEAD .. "{{use htmx}}\n<a " .. form .. "='{{.v}}'>"))
    assert(calls[1] == "_json", form)
  end
  for _, form in ipairs({ "hx-target", "data-hx-target", "HX-TARGET", "DATA-HX-TARGET" }) do
    local calls = helpers_called(compiled(HEAD .. "{{use htmx}}\n<a " .. form .. "='#a{{.v}}'>"))
    assert(calls[1] == "_sel", form)
  end
  for _, form in ipairs({ "hx-on:click", "hx-on::after-request", "hx-on--after-request", "hx-on", "HX-ON:CLICK",
      "data-hx-on:click", "DATA-HX-ON--click", "data-hx-on-click", "hx-vars", "data-hx-vars", "hx-onclick" }) do
    for _, use in ipairs({ "", "{{use htmx}}\n" }) do
      local why = refused(HEAD .. use .. "<a " .. form .. "=\"{{.x}}\">")
      assert(why:find("would be script", 1, true), form .. ": " .. why)
    end
  end
  -- Only the families htmx reads with a `data-` prefix: this is not one.
  compiled(HEAD .. "{{use htmx}}\n<a data-data-hx-get=\"{{.x}}\" data-hxget=\"{{.x}}\" xhx-get=\"{{.x}}\">")
end

local function test_a_whole_url_slot_in_an_htmx_request_url_is_checked_as_local()
  local out = compiled(HEAD .. "{{use htmx}}\n<a hx-get=\"{{.u}}\" href=\"{{.u}}\">")
  assert(out:find("html.local_href(v)", 1, true), out)
  assert(helpers_called(out)[1] == "_lurl" and helpers_called(out)[2] == "_url", out)
  -- The same rules as an href for the text beside a whole-URL slot.
  assert(refused(HEAD .. "{{use htmx}}\n<a hx-get=\"{{.u}}{{.v}}\">"):find("follows a whole-URL slot", 1, true))
  assert(refused(HEAD .. "{{use htmx}}\n<a hx-get=\"{{.u}}:x\">"):find("complete a scheme", 1, true))
  assert(refused(HEAD .. "{{use htmx}}\n<a hx-post=\"java{{.x}}\">"):find("fixes where the URL goes", 1, true))
  assert(refused(HEAD .. "{{use htmx}}\n<a hx-post=\"/a/.{{.x}}\">"):find("'..' segment", 1, true))
  assert(refused(HEAD .. "{{use htmx}}\n<link hx-get=\"{{.u}}\">"):find("<link>", 1, true))
  -- A literal host is the author's own.
  compiled(HEAD .. "{{use htmx}}\n<a hx-get=\"//example.com/{{.x}}\" hx-post=\"https://example.com/{{.x}}\">")
end

local function test_a_url_part_in_an_htmx_url_follows_the_rules_of_href()
  for _, src in ipairs(PARTS) do
    local swapped = src:gsub("<a href=", "<a hx-get=")
    local calls = helpers_called(compiled(HEAD .. "{{use htmx}}\n" .. swapped))
    local part = false
    for _, call in ipairs(calls) do
      part = part or call == "_part"
    end
    assert(part, swapped .. ": " .. table.concat(calls, " "))
  end
  for _, case in ipairs(DECODED) do
    if case.want ~= "" then
      local swapped = case.source:gsub("href=", "hx-get=")
      local why = refused(HEAD .. "{{use htmx}}\n" .. swapped)
      assert(why:find(case.want, 1, true), swapped .. ": " .. why)
    end
  end
end

local function test_a_json_slot_is_the_whole_value()
  compiled(HEAD .. "{{use htmx}}\n<a hx-vals='{{.v}}'>")
  compiled(HEAD .. "{{use htmx}}\n<a hx-vals=' {{.v}}\n'>")
  compiled(HEAD .. "{{use htmx}}\n<a hx-vals='{{if .a}}{{.v}}{{else}}{\"a\": 1}{{end}}'>")
  local cases: {Expect} = {
    { source = "<a hx-vals='{\"a\":{{.v}}}'>", want = "must be the whole value" },
    { source = "<a hx-vals='x{{.v}}'>", want = "must be the whole value" },
    { source = "<a hx-vals='{{.v}}{{.v}}'>", want = "must be the whole value" },
    { source = "<a hx-vals='{{.v}}x'>", want = "text after a JSON slot" },
    { source = "<a hx-vals='{{.v}} x'>", want = "text after a JSON slot" },
    { source = "<a hx-vals='{{if .a}}{{.v}}{{end}}x'>", want = "text after a JSON slot" },
    { source = "<a hx-vals='{{.v}}{{if .a}}x{{end}}'>", want = "text after a JSON slot" },
    { source = "<a hx-vals='{{if .a}}x{{end}}{{.v}}'>", want = "must be the whole value" },
    { source = "<a hx-vals='{{range .l}}{{.}}{{end}}'>", want = "must be the whole value" },
    { source = "<a hx-vals=\"{{.v}}'\">", want = "text after a JSON slot" },
    { source = "<a hx-headers=unquoted{{.v}}>", want = "unquoted" },
    -- The next attribute's quote must not forget text after the slot.
    { source = "<a hx-vals='{{.v}}x' title='q'>", want = "text after a JSON slot" },
    { source = "<a hx-vals='{{.v}}}' title='q'>", want = "text after a JSON slot" },
    { source = "<a hx-vals='{{.v}}x'><b title='q'>", want = "text after a JSON slot" },
    { source = "<a hx-vals='{{.v}}x' hx-get='/a'>", want = "text after a JSON slot" },
    { source = "<a hx-vals='{{.v}}x\"y' title=\"q\">", want = "text after a JSON slot" },
    { source = "<a hx-vals='{{.v}}\n x' title='q'>", want = "text after a JSON slot" },
    { source = "<a hx-vals='{{if .a}}{{.v}}{{end}}x' title='q'>", want = "text after a JSON slot" },
    { source = "<a hx-vals='{{if .a}}{{.v}}x' title='q'{{else}}'{{end}}>", want = "text after a JSON slot" },
    { source = "<a hx-vals='{{if .a}}{{.v}}{{else}}{{.v}}x{{end}}' title='q'>", want = "text after a JSON slot" },
    { source = "<a hx-vals='{{.v}}{{if .a}}x' title='q'{{else}}'{{end}}>", want = "text after a JSON slot" },
    { source = "<a hx-vals='{{range .l}}{{.v}}x' title='q'{{end}}>", want = "text after a JSON slot" },
  }
  for _, case in ipairs(cases) do
    local why = refused(HEAD .. "{{use htmx}}\n" .. case.source)
    assert(why:find(case.want, 1, true), case.source .. ": " .. why)
  end
end

local function test_a_refusal_after_a_json_slot_is_placed_at_the_byte_that_ends_it()
  local why = refused(HEAD .. "{{use htmx}}\n<a hx-vals='{{.v}}ab' title='q'>")
  assert(why:find("t.tmpl:3:21:", 1, true) and why:find("text after a JSON slot", 1, true), why)
  -- Blanks after the slot, then the closing quote: the whole value still.
  compiled(HEAD .. "{{use htmx}}\n<a hx-vals='{{.v}} ' title='q'>")
  compiled(HEAD .. "{{use htmx}}\n<a hx-vals='{{.v}}' title='q' hx-vals='{{.v}}'>")
  compiled(HEAD .. "{{use htmx}}\n<a hx-vals='{{if .a}}{{.v}}{{end}}' title='q'>")
end

local function test_a_selector_slot_stands_only_inside_an_identifier_after_a_hash_or_dot()
  for _, src in ipairs({
      "<a hx-target=\"#row-{{.id}}\">",
      "<a hx-target=\"body, #x{{.i}}\">",
      "<a hx-target=\"#a-{{.x}}{{.y}}\">",
      "<a hx-target=\"#a-{{.x}}-b-{{.y}}\">",
      "<a hx-target=\"#a-{{.x}}-b.c-{{.y}}\">",
      "<a hx-target=\"#a-{{.x}}\u{e9}{{.y}}\">",
      "<a hx-target=\"#a-{{if .x}}b{{else}}{{.y}}{{end}}{{.z}}\">",
      "<a hx-target=\"#a-{{if .x}}{{.y}}{{end}}{{.z}}\">",
      "<a hx-target=\"#a-{{range .l}}{{.}}-{{end}}{{.z}}\">",
      "<a hx-target=\"#{{.id}}\">",
      "<a hx-target=\"closest #card-{{.id}} .x-{{.n}}\">",
      "<a hx-target='#a-{{.x}}' hx-select='.b-{{.y}}'>",
  }) do
    assert(helpers_called(compiled(HEAD .. "{{use htmx}}\n" .. src))[1] == "_sel", src)
  end
  for _, src in ipairs({
      "<a hx-target=\"{{.sel}}\">",
      "<a hx-target=\" {{.sel}}\">",
      "<a hx-target=\"body, {{.sel}}\">",
      "<a hx-target=\"#a, b{{.sel}}\">",
      "<a hx-target=\"#a {{.sel}}\">",
      "<a hx-target=\"#a >{{.sel}}\">",
      "<a hx-target=\"[data-id='{{.id}}']\">",
      "<a hx-target='[data-id=\"{{.id}}\"]'>",
      "<a hx-target=\"#a:not({{.sel}})\">",
      "<a hx-target=\"#a:{{.sel}}\">",
      "<a hx-target=\"#a\\2c {{.sel}}\">",
      "<a hx-target=\"#a[{{.sel}}]\">",
      "<a hx-target=\"closest {{.sel}}\">",
      "<a hx-target=\"#a-{{.x}}, {{.y}}\">",
      "<a hx-target=\"#a-{{.x}} {{.y}}\">",
      "<a hx-target=\"#a-{{.x}}.{{.y}}-{{.z}} {{.w}}\">",
      "<a hx-target=\"#a-{{if .x}}b{{else}} {{end}}{{.z}}\">",
      "<a hx-target=\"#a-{{if .x}}{{.y}}{{else}}, {{end}}{{.z}}\">",
      "<a hx-target=\"#a-{{if .x}}b{{end}}{{if .y}}, {{end}}{{.z}}\">",
      "<a hx-swap-oob=\"{{.style}}:#x\">",
  }) do
    local why = refused(HEAD .. "{{use htmx}}\n" .. src)
    assert(why:find("part of a CSS selector", 1, true), src .. ": " .. why)
  end
end

local function test_the_dialect_names_are_checked_in_the_header()
  local function header(extra: string): string
    return "{{type T from m.t}}" .. extra .. "\n<p>{{.x}}</p>"
  end
  compiled(header("{{use htmx}}"))
  compiled(header("\n{{mode html}}\n{{use htmx}}"))
  compiled(header("\n{{use htmx}}\n{{mode html}}"))
  compiled(header("{{use htmx}}{{mode html}}"))
  compiled("\n{{type T from m.t}}\n\n{{use htmx}}\n\n<p>{{.x}}</p>")
  assert(refused(header("{{mode text}}{{use htmx}}")):find("t.tmpl:1:", 1, true))
  assert(refused(header("{{use htmx}}{{mode text}}")):find("a text template has no attributes", 1, true))
  assert(refused(header("{{use htmx}}{{use htmx}}")):find("t.tmpl:1:", 1, true))
  assert(refused(header("{{use htmx}}\n{{use htmx}}")):find("t.tmpl:2:1: {{use htmx}} is given once", 1, true))
  assert(refused(header("{{mode html}}{{mode text}}")):find("{{mode}} is given once", 1, true))
  assert(refused(header("\n{{use alpine}}")):find("t.tmpl:2:7: unknown dialect 'alpine' (known: htmx)", 1, true))
  assert(refused(header("{{use}}")):find("write {{use name}}", 1, true))
  assert(refused(header("{{use htmx extra}}")):find("write {{use name}}", 1, true))
  assert(refused(header("{{use \"htmx\"}}")):find("write {{use name}}", 1, true))
  assert(refused("{{type T from m.t}}\n<p>{{.x}}</p>{{use htmx}}"):find("t.tmpl:2:", 1, true))
  assert(refused(header("{{if .a}}{{use htmx}}{{end}}")):find("must directly follow", 1, true))
  local after = refused(header("text\n{{use htmx}}"))
  assert(after:find("{{use}} must directly follow {{type}} or {{mode}}", 1, true), after)
end

local function test_a_use_adds_nothing_to_a_template_that_has_no_hx_attribute()
  local plain = compiled(HEAD .. "<a href=\"/a/{{.x}}\" class=\"{{.c}}\">{{.t}}</a>\n")
  local used = compiled("{{type T from m.t}}{{use htmx}}\n<a href=\"/a/{{.x}}\" class=\"{{.c}}\">{{.t}}</a>\n")
  assert(plain == used, used)
end

local function test_a_project_dialect_replaces_the_registry()
  local alpine: Template.Dialect = {
    name = "alpine",
    targets = "3",
    exact = { ["x-html"] = { class = "refused", why = "would be markup Alpine inserts" },
      ["x-link"] = { class = "url_local", why = "" } },
    prefixes = { { prefix = "@", rule = { class = "refused", why = "would be script" } } },
    families = { "x-" },
    plain = {},
  }
  local options: Template.Options = { dialects = { alpine = alpine } }
  local function compile(src: string): string?, string
    return Template.compile("{{type T from m.t}}{{use alpine}}\n" .. src, "t.tmpl", options)
  end
  local out = assert(compile("<a x-link=\"{{.u}}\" data-x-link=\"/a/{{.i}}\">"))
  assert(helpers_called(out)[1] == "_lurl" and helpers_called(out)[2] == "_part", out)
  local html, why = compile("<a data-x-html=\"{{.u}}\">")
  assert(html == nil and why:find("'data-x-html' attribute would be markup Alpine inserts", 1, true), tostring(why))
  local click, click_why = compile("<a @click=\"{{.u}}\">")
  assert(click == nil and click_why:find("would be script", 1, true), tostring(click_why))
  -- The always-on refusals hold, and the built-in registry is not there.
  local on, on_why = compile("<a hx-on:click=\"{{.u}}\">")
  assert(on == nil and on_why:find("would be script", 1, true), tostring(on_why))
  local gone, gone_why = Template.compile("{{type T from m.t}}{{use htmx}}\n", "t.tmpl", options)
  assert(gone == nil and gone_why:find("unknown dialect 'htmx' (known: alpine)", 1, true), tostring(gone_why))
  -- Two dialects must agree on an attribute they both name.
  local other: Template.Dialect = {
    name = "other",
    targets = "1",
    exact = { ["x-link"] = { class = "json", why = "" } },
    prefixes = {},
    families = {},
    plain = {},
  }
  local clash, clash_why = Template.compile("{{type T from m.t}}{{use alpine}}{{use other}}\n", "t.tmpl",
    { dialects = { alpine = alpine, other = other } })
  assert(clash == nil and clash_why:find("dialects 'alpine' and 'other' give 'x-link' different rules", 1, true),
    tostring(clash_why))
end

local function test_a_slot_that_begins_a_url_is_judged_by_where_its_branch_left_off()
  compiled(HEAD .. "<a href=\"{{if .a}}{{.x}}{{else}}{{.y}}{{end}}\">")
  compiled(HEAD .. "<a href=\"{{if .a}}{{.x}}{{end}}\">")
  local why = refused(HEAD .. "<a href=\"{{if .a}}{{.x}}{{end}}{{.y}}\">")
  assert(why:find("t.tmpl:2:", 1, true) and why:find("fixes where", 1, true), why)
end

local SYNTAX <const>: {Refusal} = {
  { source = "", line = "1", column = "1", reason = "starts with {{type" },
  { source = "text\n{{type T from m.t}}", line = "1", column = "1", reason = "starts with {{type" },
  { source = "{{.x}}", line = "1", column = "1", reason = "starts with {{type" },
  { source = "{{type T}}", line = "1", column = "1", reason = "write {{type" },
  { source = "{{type T from m.t extra}}", line = "1", column = "1", reason = "write {{type" },
  { source = "{{type end from m.t}}", line = "1", column = "8", reason = "not a type name" },
  { source = "{{type 1T from m.t}}", line = "1", column = "8", reason = "not a type name" },
  { source = "{{type T from m..t}}", line = "1", column = "15", reason = "not an import path" },
  { source = "{{type T from m.t}}{{mode}}", line = "1", column = "20", reason = "write {{mode" },
  { source = "{{type T from m.t}}{{mode json}}", line = "1", column = "20", reason = "write {{mode" },
  { source = "{{type T from m.t}}x{{mode text}}", line = "1", column = "21", reason = "directly follow" },
  { source = "{{type T from m.t}}{{type U from m.u}}", line = "1", column = "20", reason = "first action" },
  { source = HEAD .. "a {{.x", line = "2", column = "3", reason = "unterminated action" },
  { source = HEAD .. "{{if .x}}\nabc", line = "2", column = "1", reason = "never closed" },
  { source = HEAD .. "{{range .x}}{{with .y}}\n{{end}}", line = "2", column = "1", reason = "never closed" },
  { source = HEAD .. "x{{end}}", line = "2", column = "2", reason = "without a block" },
  { source = HEAD .. "x{{else}}", line = "2", column = "2", reason = "without a block" },
  { source = HEAD .. "{{if .a}}{{else}}{{else}}{{end}}", line = "2", column = "18", reason = "after {{else}}" },
  { source = HEAD .. "{{if .a}}{{else}}{{else if .b}}{{end}}", line = "2", column = "18", reason = "after {{else}}" },
  { source = HEAD .. "{{range .a}}{{else if .b}}{{end}}", line = "2", column = "20", reason = "nest an {{if}}" },
  { source = HEAD .. "{{with .a}}{{else if .b}}{{end}}", line = "2", column = "19", reason = "nest an {{if}}" },
  { source = HEAD .. "{{if .a}}{{else foo}}{{end}}", line = "2", column = "17", reason = "takes nothing" },
  { source = HEAD .. "{{if .a}}{{end x}}", line = "2", column = "10", reason = "takes nothing" },
  { source = HEAD .. "{{}}", line = "2", column = "1", reason = "expected a value" },
  { source = HEAD .. "{{if}}{{end}}", line = "2", column = "1", reason = "expected a value" },
  { source = HEAD .. "{{foo}}", line = "2", column = "3", reason = "not a field path" },
  { source = HEAD .. "{{.a..b}}", line = "2", column = "3", reason = "not a field path" },
  { source = HEAD .. "{{.a.}}", line = "2", column = "3", reason = "not a field path" },
  { source = HEAD .. "{{.1a}}", line = "2", column = "3", reason = "not a field path" },
  { source = HEAD .. "{{.a b}}", line = "2", column = "6", reason = "expected |" },
  { source = HEAD .. "{{.a |}}", line = "2", column = "6", reason = "expected a function" },
  { source = HEAD .. "{{.a | f}}", line = "2", column = "8", reason = "module.path.func" },
  { source = HEAD .. "{{.a | .b}}", line = "2", column = "8", reason = "module.path.func" },
  { source = HEAD .. "{{.a | m.f x}}", line = "2", column = "12", reason = "expected |" },
  { source = HEAD .. "{{.a | m..f}}", line = "2", column = "8", reason = "module.path.func" },
  { source = HEAD .. "{{if .a | }}{{end}}", line = "2", column = "9", reason = "expected a function" },
  { source = HEAD .. "{{ -.x}}", line = "2", column = "4", reason = "not a field path" },
  { source = HEAD .. "{{.x -}", line = "2", column = "1", reason = "unterminated" },
}

local function test_a_template_that_does_not_parse_is_refused_where_it_goes_wrong()
  local wrong: mut {string} = {}
  for _, case in ipairs(SYNTAX) do
    local why = refused(case.source)
    local want = "t.tmpl:" .. case.line .. ":" .. case.column .. ": "
    if why:sub(1, #want) ~= want or not why:find(case.reason, 1, true) then
      wrong[#wrong + 1] = case.source .. " said " .. why .. ", not " .. want .. "..." .. case.reason
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
  assert(newlines(out) == newlines(src) + 1, "lines: " .. tostring(newlines(out)) .. " for " .. tostring(newlines(src)))
  local lines: mut {string} = {}
  for line in out:gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  for number = 1, 20 do
    local mark = "L" .. tostring(number)
    local at = 0
    for index, line in ipairs(lines) do
      if line:find('"' .. mark, 1, true) or line:find(" " .. mark, 1, true) then
        at = index
      end
    end
    if src:find(mark .. "%D") or src:find(mark .. "$") then
      assert(at == number, mark .. " is on line " .. tostring(at) .. " of the module:\n" .. out)
    end
  end
  assert(lines[#lines]:find("local _module: _Module = {render = render} return _module", 1, true), "last line: " .. lines[#lines])
  assert(lines[#lines]:find('"L20" return table.concat(parts) end local record _Module', 1, true), "last line: " .. lines[#lines])
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
    assert(count == 1, name .. " " .. tostring(count) .. " times in " .. out)
  end
  assert(out:find("= d3.d parts[#parts + 1] = _text(v)", 1, true) and out:find("= d2.e parts[#parts + 1] = _text(v)", 1, true) and
      out:find("= d.f parts[#parts + 1] = _text(v)", 1, true), out)
end

local function test_a_dot_nothing_reads_is_not_named()
  local out = compiled(HEAD .. "{{range .a}}x{{end}}{{with .b}}y{{end}}")
  assert(out:find("for _, _ in ipairs(d.a) do", 1, true), out)
  assert(out:find("local d2 = d.b if d2 then", 1, true), out)
end

local function test_a_condition_chain_is_one_flat_block()
  local out = compiled(HEAD .. "{{if .a}}1{{else if .b | m.f}}2{{else}}3{{end}}")
  assert(out:find("repeat do local d1 = d.a if d1 then", 1, true) and out:find("break end end if _one(m.f(d.b)) then", 1, true) and
      out:find("break end parts[#parts + 1] = ", 1, true) and out:find(" until true", 1, true), out)
  assert(out:find('require("m")', 1, true), out)
  -- A chain with no field path to bind stays an `if`.
  local plain = compiled(HEAD .. "{{if .b | m.f}}1{{else if .c | m.f}}2{{else}}3{{end}}")
  assert(plain:find("if _one(m.f(d.b)) then", 1, true) and plain:find("elseif _one(m.f(d.c)) then", 1, true) and
      not plain:find("repeat", 1, true), plain)
end

--- An `{{else}}` closes the chain that has no field path to bind as it does
--- one that has, including a test of a path an enclosing test bound.
local function test_an_else_closes_a_chain_with_nothing_to_bind()
  local plain = compiled(HEAD .. "{{if .b | m.f}}1{{else}}2{{end}}")
  assert(plain:find("if _one(m.f(d.b)) then", 1, true) and plain:find(" else ", 1, true) and
      not plain:find("repeat", 1, true), plain)
  local _, plain_ends = plain:gsub("%f[%w]end%f[%W]", "")
  local _, plain_opens = plain:gsub("%f[%w]if%f[%W]", "")
  assert(plain_ends >= plain_opens, plain)
  local nested = compiled(HEAD .. "{{if .a}}{{if .a}}x{{else}}y{{end}}{{end}}")
  assert(nested:find("do local d1 = d.a if d1 then if d1 then", 1, true) and
      nested:find(" else parts[#parts + 1] = \"y\" end end end", 1, true), nested)
end

--- A path an enclosing test bound is a prefix of the paths inside it: each
--- reads the local of the longest prefix bound, the key being the path as
--- the source writes it.
local function test_a_nested_guard_reads_the_local_of_its_longest_bound_prefix()
  local out = compiled(HEAD .. "{{if .a}}{{if .a.b}}{{.a.b.c}}{{.a.d}}{{end}}{{end}}")
  assert(out:find("do local d1 = d.a if d1 then do local d2 = d1.b if d2 then", 1, true), out)
  assert(out:find("= d2.c parts", 1, true) and out:find("= d1.d parts", 1, true), out)
  assert(not out:find("d1.b.c", 1, true) and not out:find("d.a.", 1, true), out)
  local same = compiled(HEAD .. "{{if .a}}{{if .a.s}}{{.a.s}}{{end}}{{end}}")
  assert(same:find("do local d2 = d1.s if d2 then", 1, true) and same:find("= d2 parts", 1, true), same)
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

local function test_text_inside_svg_math_or_select_takes_a_string_or_a_number_and_no_markup()
  local out = compiled(HEAD .. "<p>{{.x}}</p><svg>{{.x}}</svg>")
  assert(out:find("do local v: string | number = d.x parts[#parts + 1] = _ftext(v) end", 1, true), out)
  assert(out:find("local function _ftext(v: string | number): string " ..
      "if v is number then return tostring(v) end return html.raw(html.escape(v)) end", 1, true), out)
  assert(out:find("do local v: string | number | html.SafeHtml = d.x parts[#parts + 1] = _text(v) end", 1, true), out)
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
  local lua = compiled(src):gsub("%(_: t%.T%): [%w%.]+", "()"):gsub("local parts: mut {string}", "local parts")
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
  local cases: {Refusal} = {
    { source = '<a href="{{"java"}}{{.x}}">', line = "2", column = "20", reason = "fixes where" },
    { source = '<a href="{{.x}}{{"//h"}}">', line = "2", column = "19", reason = "protocol-relative" },
    { source = '<p {{"onclick"}}="{{.x}}">', line = "2", column = "19", reason = "event handler" },
    { source = '{{"<script>"}}{{.x}}', line = "2", column = "15", reason = "<script>" },
    { source = '{{"<!--"}}{{.x}}-->', line = "2", column = "11", reason = "comment" },
    { source = '<a{{"{{"}}', line = "2", column = "11", reason = "ends inside a tag" },
  }
  for _, case in ipairs(cases) do
    local why = refused(HEAD .. case.source)
    assert(why:find("t.tmpl:" .. case.line .. ":" .. case.column .. ": ", 1, true) and why:find(case.reason, 1, true), case.source .. ": " .. why)
  end
end

local function test_a_string_action_keeps_the_templates_lines()
  local src = TEXT .. "L2 {{\n  \"{{\"\n}} L4\n{{- \"x\" -}}\n\nL6"
  local out = compiled(src)
  assert(newlines(out) == newlines(src) + 1, out)
  local lines: mut {string} = {}
  for line in out:gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  assert(lines[2]:find('"L2 "', 1, true) and lines[3]:find('"{{"', 1, true), out)
  assert(lines[4]:find('" L4"', 1, true) and lines[5]:find('"x"', 1, true), out)
  assert(lines[7]:find('"L6"', 1, true), out)
end

local STRINGS <const>: {Refusal} = {
  { source = HEAD .. '{{"abc}}', line = "2", column = "3", reason = "unterminated string" },
  { source = HEAD .. '{{"abc', line = "2", column = "3", reason = "unterminated string" },
  { source = HEAD .. '{{"a\nb"}}', line = "2", column = "3", reason = "newline" },
  { source = HEAD .. '{{"a\\nb"}}', line = "2", column = "5", reason = "escape" },
  { source = HEAD .. '{{"\\{"}}', line = "2", column = "4", reason = "escape" },
  { source = HEAD .. '{{"a" | m.f}}', line = "2", column = "7", reason = "string" },
  { source = HEAD .. '{{"a" "b"}}', line = "2", column = "7", reason = "string" },
  { source = HEAD .. '{{.a | "m.f"}}', line = "2", column = "8", reason = "string" },
  { source = HEAD .. '{{.a"b"}}', line = "2", column = "5", reason = "string" },
  { source = HEAD .. '{{if "x"}}{{end}}', line = "2", column = "6", reason = "string" },
  { source = HEAD .. '{{if .a}}{{else if "x"}}{{end}}', line = "2", column = "20", reason = "string" },
  { source = HEAD .. '{{range "x"}}{{end}}', line = "2", column = "9", reason = "string" },
  { source = HEAD .. '{{"x"-}}', line = "2", column = "6", reason = "trim marker takes a space" },
  { source = HEAD .. '{{-"x"-}}', line = "2", column = "3", reason = "trim marker takes a space" },
  { source = '{{type T "from" m.t}}', line = "1", column = "1", reason = "write {{type" },
}

local function test_a_string_action_that_is_malformed_or_not_alone_is_refused_where_it_goes_wrong()
  local wrong: mut {string} = {}
  for _, case in ipairs(STRINGS) do
    local why = refused(case.source)
    local want = "t.tmpl:" .. case.line .. ":" .. case.column .. ": "
    if why:sub(1, #want) ~= want or not why:find(case.reason, 1, true) then
      wrong[#wrong + 1] = case.source .. " said " .. why .. ", not " .. want .. "..." .. case.reason
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
  -- With scripting off the frameset pops the noscript, and the classic
  -- "in frameset" mode then ignores `<title>`.
  "<noscript><frameset></noscript><title><frame onload=\"{{.x}}\"></title>",
  -- An arm that leaves the scripting-off reading in a tag where the text
  -- after it reads differently, joined with an arm that does not.
  "<noscript>{{if .a}}<a>{{else}}<a{{if .b}} style{{end}}=\"{{if .c}}{{end}}>{{end}}</noscript>{{.x}}\">",
  "<noscript>{{with .a}}<a>{{else}}<a{{if .b}} style{{end}}=\"{{if .c}}{{end}}>{{end}}</noscript>{{.x}}\">",
  "<noscript>{{range .l}}<a>{{else}}<a{{if .b}} style{{end}}=\"{{if .c}}{{end}}>{{end}}</noscript>{{.x}}\">",
  "<noscript>{{if .a}}{{else}}<a{{if .b}} style{{end}}=\"{{if .c}}{{end}}>{{end}}</noscript>{{.x}}\">",
  "<noscript>{{if .a}}<a>{{else}}<a{{if .b}} style{{end}}=\"{{\"\"}}>{{end}}</noscript>{{.x}}\">",
  "<noscript><a{{if .b}} style{{end}}=\"{{\"\"}}></noscript>{{.x}}\">",
  "<noscript><a{{if .b}} style{{end}}=\"></noscript>{{.x}}\">",
}

--- `src` cut at every byte of its literal text, with `{{.x}}` its one slot:
--- by a block that emits nothing, and by that byte written as a string
--- action. No cut goes beside a brace of the literal text, which would run
--- into an action's own.
local function cuts(src: string): {string}
  local literal: mut {integer: boolean} = {}
  local at = 1
  while at <= #src do
    local open, close = src:find("{{.-}}", at)
    for i = at, (open or #src + 1) - 1 do
      literal[i] = not src:sub(i, i):find("[{}]")
    end
    at = (close or #src) + 1
  end
  local out: mut {string} = { src }
  for i = 1, #src do
    if literal[i] and literal[i - 1] ~= false and literal[i + 1] ~= false then
      local byte = src:sub(i, i):gsub('[\\"]', "\\%0")
      out[#out + 1] = src:sub(1, i - 1) .. "{{if .cut}}{{end}}" .. src:sub(i)
      out[#out + 1] = src:sub(1, i - 1) .. '{{"' .. byte .. '"}}' .. src:sub(i + 1)
    end
  end
  return out
end

local function test_markup_in_noscript_that_scripting_off_reads_differently_refuses_a_later_slot()
  local wrong: mut {string} = {}
  for _, src in ipairs(NOSCRIPT_MARKUP) do
    for _, cut in ipairs(cuts(src)) do
      local out, why = Template.compile(HEAD .. cut, "t.tmpl")
      if out ~= nil or not (why:find("differently", 1, true) or why:find("the arms", 1, true)) then
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
  local wrong: mut {string} = {}
  for _, src in ipairs(NOSCRIPT_PLAIN) do
    for _, cut in ipairs(cuts(src)) do
      local out, why = Template.compile(HEAD .. cut, "t.tmpl")
      if out == nil or not out:find("_text(v)", 1, true) then
        wrong[#wrong + 1] = cut .. ": " .. tostring(why)
      end
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
  for _, src in ipairs({
      "<noscript>{{if .a}}<p>On</p>{{else}}<b>Off</b>{{end}}</noscript>{{.x}}",
      "<noscript>{{if .a}}Turn on JS{{end}}</noscript>{{.x}}",
      "<noscript>{{if .a}}<p>On</p>{{end}}</noscript>{{.x}}",
      "<noscript>{{range .l}}<p>x</p>{{end}}</noscript>{{.x}}",
      "<noscript><input{{if .a}} checked{{end}}></noscript>{{.x}}",
      "<noscript><input{{if .a}} checked{{end}} name=\"n\"></noscript>{{.x}}",
  }) do
    assert(compiled(HEAD .. src):find("_text(v)", 1, true), src)
  end
  -- Arms that leave the scripting-off reading apart up to `</noscript>`.
  for _, src in ipairs({
      "<noscript><input{{if .a}} checked{{end}}</noscript>{{.x}}",
      "<noscript><input{{if .a}} chec{{end}}ked></noscript>{{.x}}",
  }) do
    refused(HEAD .. src)
  end
end

-- A parser in the classic "in select" mode ignores a start tag of raw text
-- or RCDATA other than `<script>` and `<textarea>`, and one in "in frameset"
-- every one but `<noframes>`, and reads the markup inside as tags; a newer
-- one opens the element. A `<template>` in a select hides a `</select>` from
-- the classic parser, which is in select again after `</template>`. A slot
-- after such a tag is refused, as is one in the same text cut into runs.
local function test_raw_text_in_select_or_frameset_is_refused()
  local wrong: mut {string} = {}
  for _, src in ipairs({
      '<select><title><option onclick="{{.x}}"></title></select>',
      '<select><title><script>{{.x}}</script></title></select>',
      '<select><style><option style="</style>{{.x}}">',
      '<select><noscript><option title="</noscript>{{.x}}">',
      '<select><xmp></xmp></select>{{.x}}',
      '<html><head></head><frameset><title><frame src="about:blank" onload="{{.x}}"></title></frameset>',
      '<frameset><textarea></textarea>{{.x}}',
      '<frameset><script></script>{{.x}}',
      '<select><template></select></template><title><option onclick="{{.x}}"></title>',
      '<select><template><div><select></select></template><title><option onclick="{{.x}}"></title>',
      '<select><template></select></template><style><option onclick="</style>{{.x}}">',
  }) do
    for _, cut in ipairs(cuts(src)) do
      local out = Template.compile(HEAD .. cut, "t.tmpl")
      if out ~= nil then
        wrong[#wrong + 1] = cut
      end
    end
  end
  assert(#wrong == 0, "compiled:\n" .. table.concat(wrong, "\n"))
end

local function test_raw_text_the_select_mode_reads_still_takes_a_slot()
  for _, src in ipairs({
      '<select><option>{{.x}}</option></select>',
      '<select><textarea>{{.x}}</textarea></select>',
      '<select><script></script><option>{{.x}}</option></select>',
      '<select></select><title>{{.x}}</title>',
      '<select><option>a</option></select><style>p</style>{{.x}}',
  }) do
    for _, cut in ipairs(cuts(src)) do
      local out = compiled(HEAD .. cut)
      assert(out:find("_rtext(v)", 1, true) or out:find("_text(v)", 1, true) or out:find("_ftext(v)", 1, true), cut)
    end
  end
  assert(refused(HEAD .. "<frameset><frame src=\"a\"></frameset>"):find("inside <frameset>", 1, true))
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
local APART <const>: {Refusal} = {
  -- `checked="x"` in one arm, the tag `<input=x>` in the other.
  { source = '<input{{if .a}} checked{{end}}=x>', line = "2", column = "31", reason = "reads differently" },
  { source = '<input{{if .a}} checked{{end}}{{"="}}x>', line = "2", column = "34", reason = "reads differently" },
  { source = '<input{{if .a}} checked{{end}} =x>', line = "2", column = "32", reason = "reads differently" },
  { source = '<input{{if .a}} checked{{end}}\n  =x>', line = "3", column = "3", reason = "reads differently" },
  -- `checked` in one arm, `ked` in the other.
  { source = '<input {{if .a}}chec{{end}}ked>', line = "2", column = "28", reason = "reads differently" },
  { source = '<input{{if .a}} checked{{end}}put>', line = "2", column = "31", reason = "reads differently" },
  { source = '<input{{if .a}} name=n{{end}}/>', line = "2", column = "30", reason = "reads differently" },
  { source = '<input{{range .l}} checked{{end}}=x>', line = "2", column = "34", reason = "reads differently" },
  { source = '<meta{{if .a}} http-equiv{{end}} content="{{.c}}">', line = "2", column = "33", reason = "reads differently" },
  -- The arm that names http-equiv is the one the `>` ends, not the place kept.
  { source = '<meta content="{{.c}}"{{if .a}}{{else}} http-equiv{{end}}>', line = "2", column = "16", reason = "could be a redirect" },
  { source = '<input{{range .l}} {{end}}name=x>', line = "2", column = "27", reason = "a block before this text" },
  -- Run again, the body's own `a` carries on the `a` the run before wrote.
  { source = '<input {{range .l}}a{{end}}>', line = "2", column = "20", reason = "the {{range}} it is in" },
  { source = '<input{{if .a}} checked{{end}}{{.x}}>', line = "2", column = "31", reason = "a slot" },
  { source = '<input{{if .a}} checked{{end}}', line = "2", column = "31", reason = "the template ends inside a tag" },
  { source = '<in{{if .a}}put checked{{end}}>', line = "2", column = "4", reason = "end in different places" },
  -- An arm that goes on with the name or value the block cut, then adds an attribute.
  { source = '<input a{{if .a}}checked {{end}}>', line = "2", column = "9", reason = "end in different places" },
  { source = '<input name=n{{if .a}}x checked{{end}}>', line = "2", column = "14", reason = "end in different places" },
  { source = '<input a{{if .a}}=x{{end}}>', line = "2", column = "9", reason = "end in different places" },
  { source = '<input a {{if .a}}=x{{end}}>', line = "2", column = "10", reason = "end in different places" },
  { source = '<input/{{if .a}} checked{{end}}>', line = "2", column = "8", reason = "end in different places" },
  { source = '<p>{{if .a}}<input{{end}} checked>', line = "2", column = "4", reason = "end in different places" },
  { source = '<a{{if .a}} href{{end}}="{{.u}}">', line = "2", column = "24", reason = "reads differently" },
  { source = '<meta{{if .a}} http-equiv="refresh"{{end}} content="{{.c}}">', line = "2", column = "6", reason = "end in different places" },
}

local function test_text_that_reads_differently_after_each_arm_of_a_block_is_refused()
  local wrong: mut {string} = {}
  for _, case in ipairs(APART) do
    local why = refused(HEAD .. case.source)
    local want = "t.tmpl:" .. case.line .. ":" .. case.column .. ": "
    if why:sub(1, #want) ~= want or not why:find(case.reason, 1, true) then
      wrong[#wrong + 1] = case.source .. " said " .. why .. ", not " .. want .. "..." .. case.reason
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
  assert(url:find("^t.tmpl:2:490: a slot in the 'href' attribute that does not begin"), url)
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
  local lines: mut {string} = {}
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
  assert(again:find("^t.tmpl:2:22: a slot in the 'href' attribute that does not begin"), again)
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
  assert(out:find("local d3 = d.admin if d3 then", 1, true) and out:find("= d parts", 1, true), out)
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
  local lines: mut {string} = {}
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
local VARIABLE_REFUSALS <const>: {Refusal} = {
  { source = HEAD .. "{{$x}}", line = "2", column = "3", reason = "'$x' is not declared here" },
  { source = HEAD .. "{{range $x := .l}}{{$y.a}}{{end}}", line = "2", column = "21", reason = "'$y' is not declared here" },
  { source = HEAD .. "{{range $item := .l}}\n  {{$itme.name}}{{end}}", line = "3", column = "5", reason = "'$itme' is not declared here" },
  { source = HEAD .. "{{range $x := .l}}{{.}}{{else}}{{$x}}{{end}}", line = "2", column = "34", reason = "'$x' is not declared here" },
  { source = HEAD .. "{{range $i, $x := .l}}{{else}}{{$i}}{{end}}", line = "2", column = "33", reason = "'$i' is not declared here" },
  { source = HEAD .. "{{range $x := .l}}{{end}}{{$x}}", line = "2", column = "28", reason = "'$x' is not declared here" },
  { source = HEAD .. "{{if .a}}{{range $x := .l}}{{end}}{{$x}}{{end}}", line = "2", column = "37", reason = "'$x' is not declared here" },
  { source = HEAD .. "{{range $x := .l}}{{end}}{{range $x := .l}}{{$x}}{{end}}", line = "2", column = "1", reason = "" },
  { source = HEAD .. "{{range $x := .l}}{{range $x := .m}}{{end}}{{end}}", line = "2", column = "27", reason = "'$x' is already declared at 2:9" },
  { source = HEAD .. "{{range $x, $x := .l}}{{end}}", line = "2", column = "13", reason = "'$x' is already declared at 2:9" },
  { source = HEAD .. "{{range $x := $x.l}}{{end}}", line = "2", column = "15", reason = "'$x' is not declared here" },
  { source = HEAD .. "{{with $x := .w}}{{end}}", line = "2", column = "11", reason = "only {{range}} binds" },
  { source = HEAD .. "{{if $x := .w}}{{end}}", line = "2", column = "9", reason = "only {{range}} binds" },
  { source = HEAD .. "{{$x := .w}}", line = "2", column = "6", reason = "only {{range}} binds" },
  { source = HEAD .. "{{.a | m.f, .b}}", line = "2", column = "11", reason = "unexpected ','" },
  { source = HEAD .. "{{.a,b}}", line = "2", column = "5", reason = "unexpected ','" },
  { source = HEAD .. "{{range $i := $x := .a}}{{end}}", line = "2", column = "18", reason = "unexpected ':=': a range binds once" },
  { source = HEAD .. "{{range $x := .a := .b}}{{end}}", line = "2", column = "18", reason = "unexpected ':=': a range binds once" },
  { source = HEAD .. "{{range .a := .b}}{{end}}", line = "2", column = "12", reason = "unexpected ':=': a range binds once" },
  { source = HEAD .. "{{range $ := .l}}{{end}}", line = "2", column = "9", reason = "'$' is not a name to bind" },
  { source = HEAD .. "{{range $x.a := .l}}{{end}}", line = "2", column = "9", reason = "'$x.a' is not a name to bind" },
  { source = HEAD .. "{{range $x .l}}{{end}}", line = "2", column = "12", reason = "expected := after $x" },
  { source = HEAD .. "{{range $x $y}}{{end}}", line = "2", column = "12", reason = "expected := after $x" },
  { source = HEAD .. "{{range $i, $x .l}}{{end}}", line = "2", column = "16", reason = "expected := after $x" },
  { source = HEAD .. "{{range $i, .l}}{{end}}", line = "2", column = "13", reason = "expected a variable to bind" },
  { source = HEAD .. "{{range $i, $x, $y := .l}}{{end}}", line = "2", column = "15", reason = "expected := after $x" },
  { source = HEAD .. "{{range $x :=}}{{end}}", line = "2", column = "1", reason = "expected a value" },
  { source = HEAD .. "{{range := .l}}{{end}}", line = "2", column = "9", reason = "not a field path" },
  { source = HEAD .. "{{$.}}", line = "2", column = "3", reason = "not a variable" },
  { source = HEAD .. "{{$x..a}}", line = "2", column = "3", reason = "not a variable" },
  { source = HEAD .. "{{$1}}", line = "2", column = "3", reason = "not a variable" },
  { source = HEAD .. "{{$$}}", line = "2", column = "3", reason = "not a variable" },
  { source = HEAD .. "{{.a | $.f}}", line = "2", column = "8", reason = "module.path.func" },
}

local function test_a_variable_out_of_scope_or_misspelled_is_refused_where_it_stands()
  local wrong: mut {string} = {}
  for _, case in ipairs(VARIABLE_REFUSALS) do
    local out, why = Template.compile(case.source, "t.tmpl")
    if case.reason == "" then
      if out == nil then
        wrong[#wrong + 1] = case.source .. " was refused: " .. why
      end
    else
      local want = "t.tmpl:" .. case.line .. ":" .. case.column .. ": "
      if out ~= nil or why:sub(1, #want) ~= want or not why:find(case.reason, 1, true) then
        wrong[#wrong + 1] = case.source .. " said " .. tostring(why) .. ", not " .. want .. "..." .. case.reason
      end
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
end

--- The module a template compiles to is written in the new checker's grammar: its output list is `mut`, and the module
--- returns a local of a record type that declares `render`, which a project is held to with no ceiling.
local function test_a_template_is_written_in_the_new_grammar()
  local made = assert(Template.compile("{{type T from m.t}}{{mode text}}\nhi {{.x}}", "t.tmpl"))
  assert(made:find("local parts: mut {string} = {}", 1, true) ~= nil, made)
  assert(made:find("end local record _Module render: function(d: t.T): string end local _module: _Module = {render = render} " ..
      "return _module", 1, true) ~= nil, made)
  -- line N of the template is line N of the module
  local _, lines = made:gsub("\n", "")
  assert(lines == 2, tostring(lines))
end

-- The tracker keeps the alternative places of a block as space-separated
-- keys, and an attribute name may hold a byte Lua's `%s` reads as space
-- (\v, \f) and HTML does not. Such a name must not split a key: compile
-- answers a refusal or a template, and never raises.
local function test_an_attribute_name_with_a_vertical_tab_or_form_feed_never_makes_compile_raise()
  for _, space in ipairs({ "\v", "\f" }) do
    for _, tail in ipairs({ ">", "\">", "=x>", "" }) do
      local src = HEAD .. "<a {{if .a}}b" .. space .. "c" .. tail .. "{{end}}>"
      local ok, out, why = pcall(Template.compile, src, "t.tmpl")
      assert(ok, "compile raised on " .. string.format("%q", src) .. ": " .. tostring(out))
      assert(out ~= nil or why ~= nil, "neither a template nor a refusal")
    end
  end
end
