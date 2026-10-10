--- Cases ported by hand from Go's `html/template` tests, stated as what
--- [`cosmic.template`] does with each: the kind of its slots (text, rtext,
--- attr, url), a rendered result for hostile values, or a refusal. Go
--- escapes many places cosmic refuses (script, style, event handlers,
--- unquoted attributes, dynamic names): those are recorded as refusals, and
--- are the point.
---
--- Source: Go's src/html/template, commit c14c08388f57ed9b483018e5e087d948701e9133:
--- escape_test.go (TestEscape, TestEscapeText, TestErrors and the later
--- CVE and issue tests), transition_test.go (TestFindEndTag) and the
--- srcset cases of url_test.go. Each table row names its Go test and case.
--- A Go template becomes cosmic's by writing every `{{...}}` value as a
--- field, `{{.x}}`; a Go test of a text prefix (TestEscapeText) gets a slot
--- after the prefix, since the place a slot has there is what cosmic's
--- tracker decides; the closer an accepted row carries ends it in text, as
--- a template must end.
---
--- Not ported, by category (counts are Go cases):
--- - template calls and sets (`{{template}}`, `{{define}}`): TestEscapeSet 9,
---   TestErrors 3; cosmic composes through a stage's `render`;
--- - predefined escapers and variables (`html`, `urlquery`, `print`, `$x :=`,
---   `eq`): TestEscape 6, TestEscapeMap 2, TestErrors 7;
--- - nil and Marshaler values: TestEscape 3 (a slot takes a string, a
---   number or a safe type: the checker's, in template_check_test.tl);
--- - `{{break}}` and `{{continue}}`: TestErrors 6 (cosmic has neither);
--- - JavaScript template literals with no slot at all: TestErrors 2;
--- - TestFindEndTag cases about a tag name cosmic does not special-case: 4;
--- - the escapers themselves (JS, CSS, URL normalising, srcset filtering):
---   js_test.go, css_test.go, url_test.go, html_test.go: cosmic has none
---   (doc/roadmap.md) or tests them in cosmic.html.
---
--- Where cosmic differs from Go on purpose: it does not rewrite literal
--- text (Go turns a literal `<` in RCDATA into `&lt;` and removes comments),
--- so `</script>` in a JS string ends the script, as a browser reads it; it
--- refuses what it cannot escape, where Go escapes by guessing a JS or CSS
--- state; and it takes `usemap`, `xmlns` and `data-*` or other custom
--- attributes as plain attributes (see the notes in markup.tl).
---
--- Copyright 2011 The Go Authors. All rights reserved.
--- Use of the source code these cases come from is governed by a BSD-style
--- license, reproduced here as it requires (BSD-3-Clause):
---
--- Copyright 2009 The Go Authors.
---
--- Redistribution and use in source and binary forms, with or without
--- modification, are permitted provided that the following conditions are
--- met:
---
---    * Redistributions of source code must retain the above copyright
--- notice, this list of conditions and the following disclaimer.
---    * Redistributions in binary form must reproduce the above
--- copyright notice, this list of conditions and the following disclaimer
--- in the documentation and/or other materials provided with the
--- distribution.
---    * Neither the name of Google LLC nor the names of its
--- contributors may be used to endorse or promote products derived from
--- this software without specific prior written permission.
---
--- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
--- "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
--- LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
--- A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
--- OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
--- SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
--- LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
--- DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
--- THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
--- (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
--- OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

local Html = require("cosmic.html")
local Template = require("cosmic.template")
local teal = require("build.teal")

local HEAD <const> = "{{type T from m.t}}\n"

--- Template source, the closer that ends it in text, and the kinds of
--- its slots (sorted: attr, rtext, text, url; "none" for no slot), by
--- the helper each is written with.
local ACCEPTED <const>: {{string}} = {
  { "TestEscapeText[0]", "{{.x}}", "", "text" },
  { "TestEscapeText[1]", "Hello, World!{{.x}}", "", "text" },
  { "TestEscapeText[2]", "I <3 Ponies!{{.x}}", "", "text" },
  { "TestEscapeText[5]", "<a>{{.x}}", "", "text" },
  { "TestEscapeText[13]", "<a href=>{{.x}}", "", "text" },
  { "TestEscapeText[14]", "<a href=x>{{.x}}", "", "text" },
  { "TestEscapeText[15]", "<a href ='{{.x}}", "'>", "url" },
  { "TestEscapeText[17]", "<a href= \"{{.x}}", "\">", "url" },
  { "TestEscapeText[19]", "<a title=\"{{.x}}", "\">", "attr" },
  { "TestEscapeText[28]", "<img alt=\"1\">{{.x}}", "", "text" },
  { "TestEscapeText[30]", "<img alt=\"1>\">{{.x}}", "", "text" },
  { "TestEscapeText[82]", "<!-->{{.x}}", "", "text" },
  { "TestEscapeText[83]", "<!--->{{.x}}", "", "text" },
  { "TestEscapeText[84]", "<!-- foo -->{{.x}}", "", "text" },
  { "TestEscapeText[92]", "<script>foo</script>{{.x}}", "", "text" },
  { "TestEscapeText[96]", "<script>document.write(\"<script>alert(1)</script>\");{{.x}}", "", "text" },
  { "TestEscapeText[98]", "<script>document.write(\"<script>alert(1)</script>{{.x}}", "", "text" },
  { "TestEscapeText[100]", "<script>document.write(\"<script>alert(1)</Script>\");{{.x}}", "", "text" },
  { "TestEscapeText[110]", "<textarea>value{{.x}}", "</textarea>", "rtext" },
  { "TestEscapeText[111]", "<textarea>value</TEXTAREA>{{.x}}", "", "text" },
  { "TestEscapeText[112]", "<textarea name=html><b{{.x}}", "</textarea>", "rtext" },
  { "TestEscapeText[113]", "<title>value{{.x}}", "</title>", "rtext" },
  { "TestEscapeText[127]", "<a svg:style='{{.x}}", "'>", "attr" },
  { "TestEscapeText[129]", "<svg:a svg:onclick=\"{{.x}}", "\">", "attr" },
  { "TestEscapeText[130]", "<svg:a svg:onclick=\"x()\">{{.x}}", "", "text" },
  { "TestEscape: if", "{{if .t}}Hello{{end}}, {{.x}}!", "", "text" },
  { "TestEscape: else", "{{if .f}}{{.h}}{{else}}{{.x}}{{end}}!", "", "text" },
  { "TestEscape: withBody", "{{with .x}}{{.}}{{end}}", "", "text" },
  { "TestEscape: withElse", "{{with .e}}{{.}}{{else}}{{.x}}{{end}}", "", "text" },
  { "TestEscape: rangeBody", "{{range .l}}{{.}}{{end}}", "", "text" },
  { "TestEscape: nonStringValue", "{{.t}}", "", "text" },
  { "TestEscape: urlStartRel, urlStartAbsOk, protocolRelativeURLStart, dangerousURLStart (one template; the values are in RENDERED)", "<a href='{{.x}}'>", "", "url" },
  { "TestEscape: pathRelativeURLStart", "<a href=\"{{.x}}\">", "", "url" },
  { "TestEscape: dangerousURLStart2", "<a href='  {{.x}}'>", "", "url" },
  { "TestEscape: urlBranch", "<a href=\"{{if .f}}/foo?a=b{{else}}/bar{{end}}\">", "", "none" },
  { "TestEscape: jsReAmbigOk", "<script>{{if .t}}var x = 1{{end}}</script>", "", "none" },
  { "TestEscape: HTML comment", "<b>Hello, <!-- name of world -->{{.x}}</b>", "", "text" },
  { "TestEscape: HTML comment not first < in text node.", "<<!-- -->!--{{.x}}", "", "text" },
  { "TestEscape: HTML normalization 1", "a < b{{.x}}", "", "text" },
  { "TestEscape: HTML normalization 2", "a << b{{.x}}", "", "text" },
  { "TestEscape: HTML normalization 3", "a<<!-- --><!-- -->b{{.x}}", "", "text" },
  { "TestEscape: HTML doctype not normalized", "<!DOCTYPE html>Hello, World!{{.x}}", "", "text" },
  { "TestEscape: HTML doctype not case-insensitive", "<!doCtYPE htMl>Hello, World!{{.x}}", "", "text" },
  { "TestEscape: Split HTML comment", "<b>Hello, <!-- name of {{if .t}}city -->{{.x}}{{else}}world -->{{.y}}{{end}}</b>", "", "text" },
  { "TestEscape: JS block comment flush with mathematical division", "<script>var a/*b*//c\nd</script>", "", "none" },
  { "TestEscape: JS mixed comments", "<script>var a/*b*///c\nd</script>", "", "none" },
  { "TestEscape: JS HTML-like comments", "<script>before <!-- beep\nbetween\nbefore-->boop\n</script>", "", "none" },
  { "TestEscape: JS hashbang comment", "<script>#! beep\n</script>", "", "none" },
  { "TestEscape: Special tags in <script> string literals", "<script>var a = \"asd < 123 <!-- 456 < fgh <script jkl < 789 </script\"</script>", "</script>", "none" },
  { "TestEscape: Special tags in <script> string literals (mixed case)", "<script>var a = \"<!-- <ScripT </ScripT\"</script>", "</script>", "none" },
  { "TestEscape: Special tags in <script> regex literals (mixed case)", "<script>var a = /<!-- <ScripT </ScripT/</script>", "", "none" },
  { "TestEscape: typed HTML in text", "{{.h}}", "", "text" },
  { "TestEscape: typed HTML in attribute", "<div title=\"{{.h}}\">", "", "attr" },
  { "TestEscape: typed HTML in RCDATA", "<textarea>{{.h}}</textarea>", "", "rtext" },
  { "TestEscape: range in textarea", "<textarea>{{range .l}}{{.}}{{end}}</textarea>", "", "rtext" },
  { "TestEscape: optional attrs (URL slot at the value's start)", "<img class=\"{{.x}}\"{{if .t}} id=\"{{.x}}\"{{end}} src=\"{{if .t}}{{.x}}{{else}}images/cleardot.gif{{end}}\"{{if .t}} title=\"{{.x}}\"{{end}} alt=\"{{if .t}}{{.x}}{{else}}{{if .f}}{{.y}}{{end}}{{end}}\">", "", "attr,url" },
  { "TestEscape: quoted empty attribute value", "<p name=\"{{.x}}\">", "", "attr" },
  { "TestErrors: non-error: if/else", "{{if .c}}<a>{{else}}<b>{{end}}", "", "none" },
  { "TestErrors: non-error: if", "{{if .c}}<a>{{end}}", "", "none" },
  { "TestErrors: non-error: empty if arm", "{{if .c}}{{else}}<b>{{end}}", "", "none" },
  { "TestErrors: non-error: with", "{{with .c}}<div>{{end}}", "", "none" },
  { "TestErrors: non-error: range", "{{range .l}}<a>{{end}}", "", "none" },
  { "TestErrors: non-error: range with a tag split by if", "{{range .l}}<a{{if .x}}{{end}}>{{end}}", "", "none" },
  { "TestErrors: non-error: script template literal", "<script>var a = `${a+b}`</script>`", "", "none" },
  { "TestErrors: non-error: script template literal 2", "<script>var tmpl = `asd`;</script>", "", "none" },
  { "TestErrors: non-error: script string brace", "<script>var tmpl = `asd ${return \"{\"}`;</script>", "", "none" },
  { "TestErrors: non-error: bare meta in if", "{{if .c}}<meta>{{end}}", "", "none" },
  { "TestErrors: non-error: meta content in if", "{{if .c}}<meta content=\"url={{.x}}\">{{end}}", "", "attr" },
  { "TestErrors: = in unquoted attr 1", "<input type=button value=onclick=>", "", "none" },
  { "TestErrors: = in unquoted attr 2", "<input type=button value= onclick=>", "", "none" },
  { "TestErrors: = in unquoted attr 3", "<input type=button value= 1+1=2>", "", "none" },
  { "TestErrors: backtick in unquoted attr", "<a class=`foo>", "", "none" },
  { "TestErrors: quote in unquoted attr", "<a style=font:'Arial'>", "", "none" },
  { "TestErrors: = after tag name", "<a=foo>", "", "none" },
  { "TestErrors: script template literal if 3", "<script>var a = `{{if .x}}a{{else}}b{{end}}`</script>", "", "none" },
  { "attrs: conditional attribute after a value", "<a href=\"x\" {{if .t}}class=\"b\"{{end}}>{{.x}}", "", "text" },
  { "TestEscape: conditional valueless attr name", "<input{{if .t}} checked{{end}} name=n>{{.x}}", "", "text" },
  { "attrs: space before and after a conditional valueless name", "<input {{if .t}}checked {{end}}name=n>{{.x}}", "",
    "text" },
  { "attrs: conditional attribute with a value", "<input{{if .t}} checked=\"\"{{end}} name=n>{{.x}}", "", "text" },
  { "attrs: double quote inside a single-quoted value", "<a title='a\"b' href=\"{{.x}}\">", "", "url" },
  { "attrs: single quote inside a double-quoted value", "<a title=\"a'b\" href='{{.x}}'>", "", "url" },
  { "attrs: unquoted value before a URL", "<a title=a href=\"{{.x}}\">", "", "url" },
  { "attrs: backtick value before a URL", "<a title=`x` href=\"{{.x}}\">", "", "url" },
  { "attrs: no space between attributes", "<a title=\"a\"href=\"{{.x}}\">", "", "url" },
  { "attrs: newlines around the equals sign", "<a\n href\n=\n\"{{.x}}\">", "", "url" },
  { "attrs: tab around the equals sign", "<A\tHREF\t=\t'{{.x}}'>", "", "url" },
  { "attrs: slash between attributes", "<a/href=\"{{.x}}\">", "", "url" },
  { "attrs: mixed-case URL attribute", "<a hRef=\"{{.x}}\">", "", "url" },
  { "attrs: upper-case tag and URL attribute", "<IMG SRC=\"{{.x}}\">", "", "url" },
  { "attrs: mixed-case textarea", "<TeXtArEa>{{.x}}</tExTaReA>{{.y}}", "", "rtext,text" },
  { "attrs: mixed-case title", "<TiTlE>{{.x}}</tItLe>{{.y}}", "", "rtext,text" },
  { "attrs: mixed-case svg", "<SVG><a href=\"{{.x}}\"></a></SVG>{{.y}}", "", "text,url" },
  { "attrs: entity in an attribute name", "<a hre&#102;=\"{{.x}}\">", "", "attr" },
  { "attrs: action", "<form action=\"{{.x}}\">", "", "url" },
  { "attrs: background", "<body background=\"{{.x}}\">", "", "url" },
  { "attrs: cite", "<blockquote cite=\"{{.x}}\">", "", "url" },
  { "attrs: classid", "<span classid=\"{{.x}}\">", "", "url" },
  { "attrs: codebase", "<span codebase=\"{{.x}}\">", "", "url" },
  { "attrs: data", "<span data=\"{{.x}}\">", "", "url" },
  { "attrs: formaction", "<input formaction=\"{{.x}}\">", "", "url" },
  { "attrs: href", "<area href=\"{{.x}}\">", "", "url" },
  { "attrs: icon", "<command icon=\"{{.x}}\">", "", "url" },
  { "attrs: longdesc", "<img longdesc=\"{{.x}}\">", "", "url" },
  { "attrs: manifest", "<html manifest=\"{{.x}}\">", "", "url" },
  { "attrs: poster", "<video poster=\"{{.x}}\">", "", "url" },
  { "attrs: profile", "<head profile=\"{{.x}}\">", "", "url" },
  { "attrs: src", "<img src=\"{{.x}}\">", "", "url" },
  { "attrs: frame src", "<frame src=\"{{.x}}\">", "", "url" },
  { "attrs: input src", "<input type=\"image\" src=\"{{.x}}\">", "", "url" },
  { "attrs: track src", "<video><track src=\"{{.x}}\"></video>", "", "url" },
  { "attrs: source src", "<audio><source src=\"{{.x}}\"></audio>", "", "url" },
  { "attrs: svg image href", "<svg><image href=\"{{.x}}\"/></svg>", "", "url" },
  { "attrs: math href", "<math href=\"{{.x}}\">", "</math>", "url" },
  { "attrs: accept", "<input accept=\"{{.x}}\">", "", "attr" },
  { "attrs: alt", "<img alt=\"{{.x}}\">", "", "attr" },
  { "attrs: class", "<p class=\"{{.x}}\">", "", "attr" },
  { "attrs: id", "<p id=\"{{.x}}\">", "", "attr" },
  { "attrs: title", "<p title=\"{{.x}}\">", "", "attr" },
  { "attrs: lang", "<p lang=\"{{.x}}\">", "", "attr" },
  { "attrs: placeholder", "<input placeholder=\"{{.x}}\">", "", "attr" },
  { "attrs: target", "<a target=\"{{.x}}\">", "", "attr" },
  { "attrs: for", "<label for=\"{{.x}}\">", "", "attr" },
  { "attrs: name", "<input name=\"{{.x}}\">", "", "attr" },
  { "attrs: value", "<input value=\"{{.x}}\">", "", "attr" },
  { "attrs: type", "<input type=\"{{.x}}\">", "", "attr" },
  { "attrs: rel", "<link rel=\"{{.x}}\">", "", "attr" },
  { "attrs: method", "<form method=\"{{.x}}\">", "", "attr" },
  { "attrs: content without http-equiv", "<meta name=\"d\" content=\"{{.x}}\">", "", "attr" },
  { "attrs: data- attribute", "<p data-label=\"{{.x}}\">", "", "attr" },
  { "attrs: aria- attribute", "<p aria-label=\"{{.x}}\">", "", "attr" },
  { "attrs: xml:lang", "<p xml:lang=\"{{.x}}\">", "", "attr" },
  { "attrs: end-tag attribute", "</a title=\"{{.x}}\">", "", "attr" },
  { "attrs: end-tag URL attribute", "</a href=\"{{.x}}\">", "", "url" },
  { "RCDATA end tag: a space after '<'", "<textarea>x < {{.y}}</textarea>", "", "rtext" },
  { "RCDATA end tag: a longer name than the end tag", "<textarea></textareax{{.x}}</textarea>", "", "rtext" },
  { "RCDATA end tag: another tag's start", "<textarea><b{{.x}}</textarea>", "", "rtext" },
  { "RCDATA end tag: after '<' closed by '>'", "<textarea>a<b>{{.x}}</textarea>", "", "rtext" },
  { "RCDATA end tag: a slot, then text with '<'", "<textarea>{{.x}}<b</textarea>", "", "rtext" },
  { "RCDATA end tag: title: another tag's start", "<title><i{{.x}}</title>", "", "rtext" },
  { "RCDATA end tag: attribute value '<' then slot (harmless)", "<a title=\"<{{.x}}\">", "", "attr" },
  { "split: a dash outside a script comment is no state", "<script>{{if .a}}x-{{else}}x{{end}}</script>{{.x}}", "", "text" },
  { "split: a dash pair outside a script comment", "<script>{{if .a}}x--{{end}}</script>{{.x}}", "", "text" },
  { "split: RCDATA end tag", "<textarea></text{{if .f}}{{end}}area>{{.x}}", "", "text" },
  { "split: RCDATA end tag name and delimiter", "<title></title{{if .f}}{{end}}>{{.x}}", "", "text" },
  { "split: script end tag", "<script>x</scr{{if .f}}{{end}}ipt>{{.x}}", "", "text" },
  { "split: script comment end", "<script><!--<script></script>--{{if .f}}{{end}}></script>{{.x}}", "", "text" },
  { "split: a partial end tag that is not one", "<textarea></tex{{if .f}}{{end}}x>{{.y}}</textarea>", "", "rtext" },
  { "TestFindEndTag[0]", "<textarea>hello </textarea> hello{{.x}}", "", "text" },
  { "TestFindEndTag[1]", "<textarea>hello </TEXTarea> hello{{.x}}", "", "text" },
  { "TestFindEndTag[2]", "<textarea>hello </textAREA>{{.x}}", "", "text" },
  { "TestFindEndTag[3]", "<textarea>hello </tag> </other> </textarea> <other>{{.x}}", "", "text" },
  { "TestFindEndTag[4]", "<textarea></textarea> <other>{{.x}}", "", "text" },
  { "TestFindEndTag[5]", "<textarea><div> </div> </TEXTAREA>{{.x}}", "", "text" },
  { "TestFindEndTag[6]", "<textarea><div> </div> </TEXTAREA\t>{{.x}}", "", "text" },
  { "TestFindEndTag[7]", "<textarea><div> </div> </TEXTAREA >{{.x}}", "", "text" },
  { "TestFindEndTag[8]", "<textarea><div> </div> </TEXTAREAfoo{{.x}}", "</textarea>", "rtext" },
  { "TestFindEndTag[9]", "<textarea></TEXTAREAfoo </textarea>{{.x}}", "", "text" },
  { "TestFindEndTag[10]", "<script><</script >{{.x}}", "", "text" },
  { "TestFindEndTag[11]", "<textarea></script>{{.x}}", "</textarea>", "rtext" },
  { "Go attrType: archive elsewhere", "<p archive=\"{{.x}}\">", "", "url" },
  { "Go attrType: usemap", "<img usemap=\"{{.x}}\">", "", "attr" },
  { "Go attrType: xmlns", "<svg xmlns=\"{{.x}}\">", "</svg>", "attr" },
  { "Go attrType: xmlns:foo", "<svg xmlns:foo=\"{{.x}}\">", "</svg>", "attr" },
  { "Go attrType: data-url", "<p data-url=\"{{.x}}\">", "", "attr" },
  { "Go attrType: data-iconUri", "<p data-iconUri=\"{{.x}}\">", "", "attr" },
  { "Go attrType: data-urlItem", "<p data-urlItem=\"{{.x}}\">", "", "attr" },
  { "Go attrType: data-src", "<p data-src=\"{{.x}}\">", "", "attr" },
  { "Go attrType: data-href", "<p data-href=\"{{.x}}\">", "", "attr" },
  { "Go attrType: data-action", "<p data-action=\"{{.x}}\">", "", "attr" },
  { "Go attrType: g:url", "<p g:url=\"{{.x}}\">", "", "attr" },
  { "Go attrType: g:iconUri", "<p g:iconUri=\"{{.x}}\">", "", "attr" },
  { "Go attrType: g:urlItem", "<p g:urlItem=\"{{.x}}\">", "", "attr" },
  { "Go attrType: imgsrc", "<p imgsrc=\"{{.x}}\">", "", "attr" },
  { "Go attrType: my-uri", "<p my-uri=\"{{.x}}\">", "", "attr" },
  { "Go attrType: myurl", "<p myurl=\"{{.x}}\">", "", "attr" },
  { "Go attrType: ng-src", "<p ng-src=\"{{.x}}\">", "", "attr" },
  { "Go attrType: svg:href", "<svg><a svg:href=\"{{.x}}\"></a></svg>", "", "attr" },
}

--- Template source, the line and column it is refused at, and a part of
--- the reason. Line 1 is the `{{type}}` line.
local REFUSED <const>: {{string}} = {
  { "TestEscapeText[3]", "<a{{.x}}", "2", "3", "tag name" },
  { "TestEscapeText[4]", "<a {{.x}}", "2", "4", "attribute" },
  { "TestEscapeText[6]", "<a href{{.x}}", "2", "8", "attribute" },
  { "TestEscapeText[7]", "<a on{{.x}}", "2", "6", "attribute" },
  { "TestEscapeText[8]", "<a href {{.x}}", "2", "9", "attribute" },
  { "TestEscapeText[9]", "<a style  =  {{.x}}", "2", "14", "unquoted" },
  { "TestEscapeText[10]", "<a href={{.x}}", "2", "9", "unquoted" },
  { "TestEscapeText[11]", "<a href=x{{.x}}", "2", "10", "unquoted" },
  { "TestEscapeText[12]", "<a href=x {{.x}}", "2", "11", "attribute" },
  { "TestEscapeText[16]", "<a href=''{{.x}}", "2", "11", "attribute" },
  { "TestEscapeText[18]", "<a href=\"\"{{.x}}", "2", "11", "attribute" },
  { "TestEscapeText[20]", "<a HREF='http:{{.x}}", "2", "15", "must begin" },
  { "TestEscapeText[21]", "<a Href='/{{.x}}", "2", "11", "must begin" },
  { "TestEscapeText[22]", "<a href='\"{{.x}}", "2", "11", "must begin" },
  { "TestEscapeText[23]", "<a href=\"'{{.x}}", "2", "11", "must begin" },
  { "TestEscapeText[24]", "<a href='&apos;{{.x}}", "2", "16", "must begin" },
  { "TestEscapeText[25]", "<a href=\"&quot;{{.x}}", "2", "16", "must begin" },
  { "TestEscapeText[26]", "<a href=\"&#34;{{.x}}", "2", "15", "must begin" },
  { "TestEscapeText[27]", "<a href=&quot;{{.x}}", "2", "15", "unquoted" },
  { "TestEscapeText[29]", "<img alt=\"1>\"{{.x}}", "2", "14", "attribute" },
  { "TestEscapeText[31]", "<input checked type=\"checkbox\"{{.x}}", "2", "31", "attribute" },
  { "TestEscapeText[32]", "<a onclick=\"{{.x}}", "2", "13", "event handler" },
  { "TestEscapeText[33]", "<a onclick=\"//foo{{.x}}", "2", "18", "event handler" },
  { "TestEscapeText[34]", "<a onclick='//\n{{.x}}", "3", "1", "event handler" },
  { "TestEscapeText[35]", "<a onclick='//\r\n{{.x}}", "3", "1", "event handler" },
  { "TestEscapeText[36]", "<a onclick='//\u{2028}{{.x}}", "2", "18", "event handler" },
  { "TestEscapeText[37]", "<a onclick=\"/*{{.x}}", "2", "15", "event handler" },
  { "TestEscapeText[38]", "<a onclick=\"/*/{{.x}}", "2", "16", "event handler" },
  { "TestEscapeText[39]", "<a onclick=\"/**/{{.x}}", "2", "17", "event handler" },
  { "TestEscapeText[40]", "<a onkeypress=\"&quot;{{.x}}", "2", "22", "event handler" },
  { "TestEscapeText[41]", "<a onclick='&quot;foo&quot;{{.x}}", "2", "28", "event handler" },
  { "TestEscapeText[42]", "<a onclick=&#39;foo&#39;{{.x}}", "2", "25", "unquoted" },
  { "TestEscapeText[43]", "<a onclick=&#39;foo{{.x}}", "2", "20", "unquoted" },
  { "TestEscapeText[44]", "<a onclick=\"&quot;foo'{{.x}}", "2", "23", "event handler" },
  { "TestEscapeText[45]", "<a onclick=\"'foo&quot;{{.x}}", "2", "23", "event handler" },
  { "TestEscapeText[46]", "<a onclick=\"`foo{{.x}}", "2", "17", "event handler" },
  { "TestEscapeText[47]", "<A ONCLICK=\"'{{.x}}", "2", "14", "event handler" },
  { "TestEscapeText[48]", "<a onclick=\"/{{.x}}", "2", "14", "event handler" },
  { "TestEscapeText[49]", "<a onclick=\"'foo'{{.x}}", "2", "18", "event handler" },
  { "TestEscapeText[50]", "<a onclick=\"'foo\\'{{.x}}", "2", "19", "event handler" },
  { "TestEscapeText[51]", "<a onclick=\"'foo\\'{{.x}}", "2", "19", "event handler" },
  { "TestEscapeText[52]", "<a onclick=\"/foo/{{.x}}", "2", "18", "event handler" },
  { "split: arms leave a script end tag cut short", "<script>{{if .a}}</sc{{else}}x{{end}}</script>{{.x}}", "2", "9", "one leaves <script>, another <script> after '</sc'" },
  { "split: arms leave a textarea end tag cut short", "<textarea>{{if .a}}</te{{end}}</textarea>{{.x}}", "2", "11", "after '</te'" },
  { "split: arms leave a script comment open", "<script>{{if .a}}<!--{{end}}</script>{{.x}}", "2", "9", "inside a <!--" },
  { "split: arms leave a nested script open", "<script><!--{{if .a}}<script >{{end}}</script>{{.x}}", "2", "13", "inside a <!-- and a nested <script" },
  { "split: a loop leaves a script comment open", "<script>{{range .l}}<!--{{end}}</script>{{.x}}", "2", "9", "inside a <!--" },
  -- An action that emits nothing splits literal text without moving what the browser reads.
  { "split: RCDATA end tag, then a script", "<textarea></text{{if .f}}{{end}}area><script>{{.x}}</script></textarea>", "2", "46", "<script>" },
  { "split: script comment and nested script", "<script><!--\n/*<script>*/{{if .f}}{{end}}\n//</script>\n{{.x}}\n</script>", "5", "1", "<script>" },
  { "split: script end tag after a split nested start", "<script><!--<scr{{if .f}}{{end}}ipt></script>{{.x}}", "2", "46", "<script>" },
  { "split: script end tag after a split comment start", "<script><!{{if .f}}{{end}}--<script></script>{{.x}}", "2", "46", "<script>" },
  { "split: style end tag name", "<style></sty{{if .f}}{{end}}le><script>{{.x}}</script>", "2", "40", "<script>" },
  { "TestEscapeText[53]", "<script>/foo/ /={{.x}}", "2", "17", "<script>" },
  { "TestEscapeText[54]", "<a onclick=\"1 /foo{{.x}}", "2", "19", "event handler" },
  { "TestEscapeText[55]", "<a onclick=\"1 /*c*/ /foo{{.x}}", "2", "25", "event handler" },
  { "TestEscapeText[56]", "<a onclick=\"/foo[/]{{.x}}", "2", "20", "event handler" },
  { "TestEscapeText[57]", "<a onclick=\"/foo\\/{{.x}}", "2", "19", "event handler" },
  { "TestEscapeText[58]", "<a onclick=\"/foo/{{.x}}", "2", "18", "event handler" },
  { "TestEscapeText[59]", "<input checked style=\"{{.x}}", "2", "23", "'style'" },
  { "TestEscapeText[60]", "<a style=\"//{{.x}}", "2", "13", "'style'" },
  { "TestEscapeText[61]", "<a style=\"//</script>{{.x}}", "2", "22", "'style'" },
  { "TestEscapeText[62]", "<a style='//\n{{.x}}", "3", "1", "'style'" },
  { "TestEscapeText[63]", "<a style='//\r{{.x}}", "2", "14", "'style'" },
  { "TestEscapeText[64]", "<a style=\"/*{{.x}}", "2", "13", "'style'" },
  { "TestEscapeText[65]", "<a style=\"/*/{{.x}}", "2", "14", "'style'" },
  { "TestEscapeText[66]", "<a style=\"/**/{{.x}}", "2", "15", "'style'" },
  { "TestEscapeText[67]", "<a style=\"background: '{{.x}}", "2", "24", "'style'" },
  { "TestEscapeText[68]", "<a style=\"background: &quot;{{.x}}", "2", "29", "'style'" },
  { "TestEscapeText[69]", "<a style=\"background: '/foo?img={{.x}}", "2", "33", "'style'" },
  { "TestEscapeText[70]", "<a style=\"background: '/{{.x}}", "2", "25", "'style'" },
  { "TestEscapeText[71]", "<a style=\"background: url(&#x22;/{{.x}}", "2", "34", "'style'" },
  { "TestEscapeText[72]", "<a style=\"background: url('/{{.x}}", "2", "29", "'style'" },
  { "TestEscapeText[73]", "<a style=\"background: url('/){{.x}}", "2", "30", "'style'" },
  { "TestEscapeText[74]", "<a style=\"background: url('/ {{.x}}", "2", "30", "'style'" },
  { "TestEscapeText[75]", "<a style=\"background: url(/{{.x}}", "2", "28", "'style'" },
  { "TestEscapeText[76]", "<a style=\"background: url( {{.x}}", "2", "28", "'style'" },
  { "TestEscapeText[77]", "<a style=\"background: url( /image?name={{.x}}", "2", "40", "'style'" },
  { "TestEscapeText[78]", "<a style=\"background: url(x){{.x}}", "2", "29", "'style'" },
  { "TestEscapeText[79]", "<a style=\"background: url('x'{{.x}}", "2", "30", "'style'" },
  { "TestEscapeText[80]", "<a style=\"background: url( x {{.x}}", "2", "30", "'style'" },
  { "TestEscapeText[81]", "<!-- foo{{.x}}", "2", "9", "comment" },
  { "TestEscapeText[85]", "<script{{.x}}", "2", "8", "tag name" },
  { "TestEscapeText[86]", "<script {{.x}}", "2", "9", "attribute" },
  { "TestEscapeText[87]", "<script src=\"foo.js\" {{.x}}", "2", "22", "attribute" },
  { "TestEscapeText[88]", "<script src='foo.js' {{.x}}", "2", "22", "attribute" },
  { "TestEscapeText[89]", "<script type=text/javascript {{.x}}", "2", "30", "attribute" },
  { "TestEscapeText[90]", "<script>{{.x}}", "2", "9", "<script>" },
  { "TestEscapeText[91]", "<script>foo{{.x}}", "2", "12", "<script>" },
  { "TestEscapeText[93]", "<script>foo</script><!--{{.x}}", "2", "25", "comment" },
  { "TestEscapeText[94]", "<script>document.write(\"<p>foo</p>\");{{.x}}", "2", "38", "<script>" },
  { "TestEscapeText[95]", "<script>document.write(\"<p>foo<\\/script>\");{{.x}}", "2", "44", "<script>" },
  { "TestEscapeText[97]", "<script>document.write(\"<script>{{.x}}", "2", "33", "<script>" },
  { "TestEscapeText[99]", "<script>document.write(\"<script>alert(1)<!--{{.x}}", "2", "45", "<script>" },
  { "TestEscapeText[101]", "<script>document.write(\"<!--\");{{.x}}", "2", "32", "<script>" },
  { "TestEscapeText[102]", "<script>let a = /</script{{.x}}", "2", "26", "<script>" },
  { "TestEscapeText[103]", "<script>let a = /</script/{{.x}}", "2", "27", "attribute" },
  { "TestEscapeText[104]", "<script type=\"text/template\">{{.x}}", "2", "30", "<script>" },
  { "TestEscapeText[105]", "<script type=\"TEXT/JAVASCRIPT\">{{.x}}", "2", "32", "<script>" },
  { "TestEscapeText[106]", "<script TYPE=\"text/template\">{{.x}}", "2", "30", "<script>" },
  { "TestEscapeText[107]", "<script type=\"notjs\">{{.x}}", "2", "22", "<script>" },
  { "TestEscapeText[108]", "<Script>{{.x}}", "2", "9", "<script>" },
  { "TestEscapeText[109]", "<SCRIPT>foo{{.x}}", "2", "12", "<script>" },
  { "TestEscapeText[114]", "<style>value{{.x}}", "2", "13", "<style>" },
  { "TestEscapeText[115]", "<a xlink:href{{.x}}", "2", "14", "attribute" },
  { "TestEscapeText[116]", "<a xmlns{{.x}}", "2", "9", "attribute" },
  { "TestEscapeText[117]", "<a xmlns:foo{{.x}}", "2", "13", "attribute" },
  { "TestEscapeText[118]", "<a xmlnsxyz{{.x}}", "2", "12", "attribute" },
  { "TestEscapeText[119]", "<a data-url{{.x}}", "2", "12", "attribute" },
  { "TestEscapeText[120]", "<a data-iconUri{{.x}}", "2", "16", "attribute" },
  { "TestEscapeText[121]", "<a data-urlItem{{.x}}", "2", "16", "attribute" },
  { "TestEscapeText[122]", "<a g:{{.x}}", "2", "6", "attribute" },
  { "TestEscapeText[123]", "<a g:url{{.x}}", "2", "9", "attribute" },
  { "TestEscapeText[124]", "<a g:iconUri{{.x}}", "2", "13", "attribute" },
  { "TestEscapeText[125]", "<a g:urlItem{{.x}}", "2", "13", "attribute" },
  { "TestEscapeText[126]", "<a g:value{{.x}}", "2", "11", "attribute" },
  { "TestEscapeText[128]", "<svg:font-face{{.x}}", "2", "15", "tag name" },
  { "TestEscapeText[131]", "<script>var a = `{{.x}}", "2", "18", "<script>" },
  { "TestEscapeText[132]", "<script>var a = `${ {{.x}}", "2", "21", "<script>" },
  { "TestEscapeText[133]", "<script>var a = `${}{{.x}}", "2", "21", "<script>" },
  { "TestEscapeText[134]", "<script>var a = `${`{{.x}}", "2", "21", "<script>" },
  { "TestEscapeText[135]", "<script>var a = `${var a = \"{{.x}}", "2", "29", "<script>" },
  { "TestEscapeText[136]", "<script>var a = `${var a = \"`{{.x}}", "2", "30", "<script>" },
  { "TestEscapeText[137]", "<script>var a = `${var a = \"}{{.x}}", "2", "30", "<script>" },
  { "TestEscapeText[138]", "<script>var a = `${``{{.x}}", "2", "22", "<script>" },
  { "TestEscapeText[139]", "<script>var a = `${`}{{.x}}", "2", "22", "<script>" },
  { "TestEscapeText[140]", "<script>`${ {} } asd`</script><script>`${ {} }{{.x}}", "2", "47", "<script>" },
  { "TestEscapeText[141]", "<script>var foo = `${ (_ => { return \"x\" })() + \"${ {{.x}}", "2", "53", "<script>" },
  { "TestEscapeText[142]", "<script>var a = `${ {</script><script>var b = `${ x }{{.x}}", "2", "54", "<script>" },
  { "TestEscapeText[143]", "<script>var foo = `x` + \"${ {{.x}}", "2", "29", "<script>" },
  { "TestEscapeText[144]", "<script>function f() { var a = `${}`; }{{.x}}", "2", "40", "<script>" },
  { "TestEscapeText[145]", "<script>{`${}`}{{.x}}", "2", "16", "<script>" },
  { "TestEscapeText[146]", "<script>`${ function f() { return `${1}` }() }`{{.x}}", "2", "48", "<script>" },
  { "TestEscapeText[147]", "<script>function f() {`${ function f() { `${1}` } }`}{{.x}}", "2", "54", "<script>" },
  { "TestEscapeText[148]", "<script>`${ { `` }{{.x}}", "2", "19", "<script>" },
  { "TestEscapeText[149]", "<script>`${ { }`{{.x}}", "2", "17", "<script>" },
  { "TestEscapeText[150]", "<script>var foo = `${ foo({ a: { c: `${ {{.x}}", "2", "41", "<script>" },
  { "TestEscapeText[151]", "<script>var foo = `${ foo({ a: { c: `${ {{.}} }` }, b: ", "2", "41", "<script>" },
  { "TestEscapeText[152]", "<script>`${ `}{{.x}}", "2", "15", "<script>" },
  { "TestEscapeText[153]", "<script>`${1}${ {{.x}}", "2", "17", "<script>" },
  { "TestEscapeText[154]", "<script>`${`${1}${ {{.x}}", "2", "20", "<script>" },
  { "TestEscape: rangeElse", "{{range .e}}{{.}}{{else}}{{.x}}{{end}}", "2", "18", "not supported" },
  { "TestEscape: constant", "<a href=\"/search?q={{.x}}\">", "2", "20", "must begin" },
  { "TestEscape: multipleAttrs", "<a b=1 c={{.x}}>", "2", "10", "unquoted" },
  { "TestEscape: nonHierURL", "<a href={{.x}}>", "2", "9", "unquoted" },
  { "TestEscape: urlPath", "<a href='http://{{.x}}/foo'>", "2", "17", "must begin" },
  { "TestEscape: urlQuery", "<a href='/search?q={{.x}}'>", "2", "20", "must begin" },
  { "TestEscape: urlFragment", "<a href='/faq#{{.x}}'>", "2", "15", "must begin" },
  { "TestEscape: urlBranchConflictMoot", "<a href=\"{{if .t}}/foo?a={{else}}/bar#{{end}}{{.x}}\">", "2", "46", "must begin" },
  { "TestEscape: jsStrValue", "<button onclick='alert({{.x}})'>", "2", "24", "event handler" },
  { "TestEscape: jsNumericValue", "<button onclick='alert({{.n}})'>", "2", "24", "event handler" },
  { "TestEscape: jsBoolValue", "<button onclick='alert({{.t}})'>", "2", "24", "event handler" },
  { "TestEscape: jsNilValueTyped", "<button onclick='alert(typeof{{.x}})'>", "2", "30", "event handler" },
  { "TestEscape: jsObjValue", "<button onclick='alert({{.l}})'>", "2", "24", "event handler" },
  { "TestEscape: jsObjValueScript", "<script>alert({{.l}})</script>", "2", "15", "<script>" },
  { "TestEscape: scriptTypeSpace", "<script type=\" \">{{.x}}</script>", "2", "18", "<script>" },
  { "TestEscape: scriptTypeTab", "<script type=\"\t\">{{.x}}</script>", "2", "18", "<script>" },
  { "TestEscape: scriptTypeEmpty", "<script type=\"\">{{.x}}</script>", "2", "17", "<script>" },
  { "TestEscape: jsStr", "<button onclick='alert(&quot;{{.x}}&quot;)'>", "2", "30", "event handler" },
  { "TestEscape: badMarshaler", "<button onclick='alert(1/{{.x}}in numbers)'>", "2", "26", "event handler" },
  { "TestEscape: jsRe", "<button onclick='alert(/{{.x}}/.test(\"\"))'>", "2", "25", "event handler" },
  { "TestEscape: jsReBlank", "<script>alert(/{{.x}}/.test(\"\"));</script>", "2", "16", "<script>" },
  { "TestEscape: styleBidiKeywordPassed", "<p style=\"dir: {{.x}}\">", "2", "16", "'style'" },
  { "TestEscape: styleBidiPropNamePassed", "<p style=\"border-{{.x}}: 0; border-{{.y}}: 1in\">", "2", "18", "'style'" },
  { "TestEscape: styleExpressionBlocked", "<p style=\"width: {{.x}}\">", "2", "18", "'style'" },
  { "TestEscape: styleTagSelectorPassed", "<style>{{.x}} { color: pink }</style>", "2", "8", "<style>" },
  { "TestEscape: styleIDPassed", "<style>p{{.x}} { font: Arial }</style>", "2", "9", "<style>" },
  { "TestEscape: styleQuantityPassed", "<a style=\"left: {{.x}}; top: {{.n}}\">", "2", "17", "'style'" },
  { "TestEscape: stylePctPassed", "<table style=width:{{.x}}>", "2", "20", "unquoted" },
  { "TestEscape: styleColorPassed", "<p style=\"color: {{.x}}; background: {{.y}}\">", "2", "18", "'style'" },
  { "TestEscape: styleMozBindingBlocked", "<p style=\"{{.x}}: ...\">", "2", "11", "'style'" },
  { "TestEscape: styleFontNameString", "<p style='font-family: \"{{.x}}\", \"{{.y}}\"'>", "2", "25", "'style'" },
  { "TestEscape: styleFontNameUnquoted", "<p style='font-family: {{.x}}'>", "2", "24", "'style'" },
  { "TestEscape: styleURLQueryEncoded", "<p style=\"background: url(/img?name={{.x}})\">", "2", "37", "'style'" },
  { "TestEscape: styleQuotedURLQueryEncoded", "<p style=\"background: url('/img?name={{.x}}')\">", "2", "38", "'style'" },
  { "TestEscape: styleStrQueryEncoded", "<p style=\"background: '/img?name={{.x}}'\">", "2", "34", "'style'" },
  { "TestEscape: styleURLBadProtocolBlocked", "<a style=\"background: url('{{.x}}')\">", "2", "28", "'style'" },
  { "TestEscape: styleStrBadProtocolBlocked", "<a style=\"background: '{{.x}}'\">", "2", "24", "'style'" },
  { "TestEscape: styleURLEncodedForHTMLInAttr", "<a style=\"background: url('{{.x}}')\">", "2", "28", "'style'" },
  { "TestEscape: styleURLNotEncodedForHTMLInCdata", "<style>body { background: url('{{.x}}') }</style>", "2", "32", "<style>" },
  { "TestEscape: styleURLMixedCase", "<p style=\"background: URL(#{{.x}})\">", "2", "28", "'style'" },
  { "TestEscape: stylePropertyPairPassed", "<a style='{{.x}}'>", "2", "11", "'style'" },
  { "TestEscape: styleStrSpecialsEncoded", "<a style=\"font-family: '{{.x}}', &quot;{{.y}}&quot;\">", "2", "25", "'style'" },
  { "TestEscape: styleURLSpecialsEncoded", "<a style=\"border-image: url({{.x}}), url(&quot;{{.y}}&quot;), url('{{.x}}'), 'http://www.example.com/?q={{.y}}''\">", "2", "29", "'style'" },
  { "TestEscape: No doctype injection", "<!{{.x}}", "2", "3", "comment" },
  { "TestEscape: JS line comment", "<script>for (;;) { if (c()) break// foo not a label\nfoo({{.t}});}</script>", "3", "5", "<script>" },
  { "TestEscape: JS multiline block comment", "<script>for (;;) { if (c()) break/* foo not a label\n */foo({{.t}});}</script>", "3", "8", "<script>" },
  { "TestEscape: JS single-line block comment", "<script>for (;;) {\nif (c()) break/* foo a label */foo;x({{.t}});}</script>", "3", "38", "<script>" },
  { "TestEscape: CSS comments", "<style>p// paragraph\n{border: 1px/* color */{{.x}}}</style>", "3", "24", "<style>" },
  { "TestEscape: JS attr block comment", "<a onclick=\"f(&quot;&quot;); /* alert({{.x}}) */\">", "2", "39", "event handler" },
  { "TestEscape: JS attr line comment", "<a onclick=\"// alert({{.x}})\">", "2", "22", "event handler" },
  { "TestEscape: CSS attr block comment", "<a style=\"/* color: {{.x}} */\">", "2", "21", "'style'" },
  { "TestEscape: CSS attr line comment", "<a style=\"// color: {{.x}}\">", "2", "21", "'style'" },
  { "TestEscape: HTML substitution commented out", "<p><!-- {{.x}} --></p>", "2", "9", "comment" },
  { "TestEscape: Comment ends flush with start", "<!--{{.x}}--><script>/*{{.x}}*///{{.x}}\n</script><style>/*{{.x}}*///{{.x}}\n</style><a onclick='/*{{.x}}*///{{.x}}' style='/*{{.x}}*///{{.x}}'>", "2", "5", "comment" },
  { "TestEscape: typed HTML in script", "<button onclick=\"alert({{.h}})\">", "2", "24", "event handler" },
  { "TestEscape: No tag injection", "{{.x}}<{{.y}}...", "2", "8", "tag name" },
  { "TestEscape: No comment injection", "<{{.x}}", "2", "2", "tag name" },
  { "TestEscape: No RCDATA end tag injection", "<textarea><{{.x}}...</textarea>", "2", "12", "complete its end tag" },
  { "TestEscape: optional attrs", "<img class=\"{{.x}}\"{{if .t}} id=\"{{.x}}\"{{end}} src={{if .t}}\"?{{.x}}\"{{else}}\"images/cleardot.gif\"{{end}}{{if .t}}title=\"{{.x}}\"{{end}} alt=\"{{if .t}}{{.x}}{{else}}{{if .f}}{{.y}}{{end}}{{end}}\">", "2", "64", "must begin" },
  -- Without the arm, the tag is `<inputname=n>`.
  { "TestEscape: conditional valueless attr name (space after)", "<input{{if .t}} checked {{end}}name=n>", "2", "32",
    "reads differently" },
  { "TestEscape: conditional dynamic valueless attr name 1", "<input{{if .t}} {{.x}}{{end}} name=n>", "2", "17", "attribute" },
  { "TestEscape: conditional dynamic valueless attr name 2", "<input {{if .t}}{{.x}} {{end}}name=n>", "2", "17", "attribute" },
  { "TestEscape: dynamic attribute name", "<img on{{.x}}=\"alert({{.y}})\">", "2", "8", "attribute" },
  { "TestEscape: bad dynamic attribute name 1", "<input {{.x}}=\"{{.y}}\">", "2", "8", "attribute" },
  { "TestEscape: bad dynamic attribute name 2", "<div {{.x}}=\"{{.y}}\">", "2", "6", "attribute" },
  { "TestEscape: bad dynamic attribute name 3", "<img {{.x}}=\"{{.y}}\">", "2", "6", "attribute" },
  { "TestEscape: bad dynamic attribute name 4", "<input checked {{.x}}=\"Whose value am I?\">", "2", "16", "attribute" },
  { "TestEscape: dynamic element name", "<h{{.x}}><table><t{{.y}}>...</h{{.x}}>", "2", "3", "tag name" },
  { "TestEscape: bad dynamic element name", "<{{.x}}>{{.y}}</{{.x}}>", "2", "2", "tag name" },
  { "TestEscape: srcset bad URL in second position", "<img srcset=\"{{.x}}\">", "2", "14", "list of URLs" },
  { "TestEscape: srcset buffer growth", "<img srcset={{.x}}>", "2", "13", "unquoted" },
  { "TestEscape: unquoted empty attribute value (plaintext)", "<p name={{.x}}>", "2", "9", "unquoted" },
  { "TestEscape: unquoted empty attribute value (url)", "<p href={{.x}}>", "2", "9", "unquoted" },
  { "TestEscape: JS template lit special characters", "<script>var a = `{{.x}}`</script>", "2", "18", "<script>" },
  { "TestEscape: JS template lit special characters, nested lit", "<script>var a = `${ `{{.x}}` }`</script>", "2", "22", "<script>" },
  { "TestEscape: JS template lit, nested JS", "<script>var a = `${ var a = \"{{.x}}\" }`</script>", "2", "30", "<script>" },
  { "TestEscape: meta content attribute url", "<meta http-equiv=\"refresh\" content=\"asd; url={{.x}}; asd; url={{.y}}; asd\">", "2", "46", "http-equiv" },
  { "TestEscape: meta content string", "<meta http-equiv=\"refresh\" content=\"{{.x}}\">", "2", "37", "http-equiv" },
  { "TestEscape: meta content url with whitespace before equals", "<meta http-equiv=\"refresh\" content=\"0;url ={{.x}}\">", "2", "44", "http-equiv" },
  { "TestEscape: meta content url with tab before equals", "<meta http-equiv=\"refresh\" content=\"0;url\t={{.x}}\">", "2", "44", "http-equiv" },
  { "TestEscape: meta content url with space after equals", "<meta http-equiv=\"refresh\" content=\"0;url= {{.x}}\">", "2", "44", "http-equiv" },
  { "TestEscape: meta content url with whitespace both sides of equals", "<meta http-equiv=\"refresh\" content=\"0;url \t= {{.x}}\">", "2", "46", "http-equiv" },
  { "TestEscape: regexp after open brace in if block", "<script>if(true){/{{.x}}/g.test(\"x\")}</script>", "2", "19", "<script>" },
  { "TestEscape: regexp after close brace", "<script>if(true){x=1}/{{.x}}/g.test(\"x\")</script>", "2", "23", "<script>" },
  { "TestEscape: regexp after open brace in template literal", "<script>`${ (function(){/{{.x}}/g.test(x)}) }`</script>", "2", "26", "<script>" },
  { "TestEscape: regexp after close brace in template literal", "<script>`${ (function(){}/{{.x}}/g.test(x)) }`</script>", "2", "27", "<script>" },
  { "TestEscape: Issue81821", "<script>const s = `${1}${/{{.x}}/g}`</script>", "2", "27", "<script>" },
  { "TestEscape: Issue81823 yield", "<script>function* rules(){yield /{{.x}}/g}</script>", "2", "34", "<script>" },
  { "TestEscape: Issue81823 property yield", "<script>const pct = bond.yield / 100;\nconst user = {{.x}}; // state\n</script>", "3", "14", "<script>" },
  { "TestEscape: Issue81823 property in", "<script>const kb = traffic.in / 1024;\nconst user = {{.x}}; // state\n</script>", "3", "14", "<script>" },
  { "TestEscape: MetaContentEscapeGODEBUG", "<meta http-equiv=\"refresh\" content=\"asd; url={{.x}}; asd; url={{.y}}; asd\">", "2", "46", "http-equiv" },
  { "TestErrors: non-error: range in a URL query", "<a href='/foo?{{range .l}}&{{.k}}={{.v}}{{end}}'>", "2", "28", "must begin" },
  { "TestErrors: non-error: script slot 1", "<script>var tmpl = `${return {{.x}} }`;</script>", "2", "30", "<script>" },
  { "TestErrors: non-error: script slot 2", "<script>var tmpl = `${ let a = {1:1} {{.x}} }`;</script>", "2", "38", "<script>" },
  { "TestErrors: branches: tag open in if", "{{if .c}}<a{{end}}", "2", "1", "the arms" },
  { "TestErrors: branches: tag open in else", "{{if .c}}\n{{else}}\n<a{{end}}", "2", "1", "the arms" },
  { "TestErrors: branches: missing quote in else", "{{if .c}}<a href=\"foo\">{{else}}<a href=\"bar>{{end}}", "2", "1", "the arms" },
  { "TestErrors: branches: href vs title", "<a {{if .c}}href='{{else}}title='{{end}}{{.x}}'>", "2", "4", "the arms" },
  { "TestErrors: branches: with", "\n{{with .x}}<a{{end}}", "3", "1", "the arms" },
  { "TestErrors: branches: with else", "\n{{with .x}}<a>{{else}}<a{{end}}", "3", "1", "the arms" },
  { "TestErrors: branches: range loop re-entry", "{{range .l}}<a{{end}}", "2", "1", "ends where it did not begin" },
  { "TestErrors: branches: range attr", "\n{{range .l}} x='<a{{end}}", "3", "1", "ends where it did not begin" },
  { "TestErrors: ends: unquoted attr", "<a b=1 c={{.x}}", "2", "10", "unquoted" },
  { "TestErrors: ends: script", "<script>foo();", "2", "15", "the template ends" },
  { "TestErrors: ambiguous URL context", "<a href=\"{{if .f}}/foo?a={{else}}/bar/{{end}}{{.x}}\">", "2", "46", "must begin" },
  { "TestErrors: js string unfinished escape 1", "<a onclick=\"alert('Hello \\", "2", "27", "the template ends" },
  { "TestErrors: js string unfinished escape 2", "<a onclick='alert(\"Hello\\, World\\", "2", "34", "the template ends" },
  { "TestErrors: js regexp unfinished", "<a onclick='alert(/x+\\", "2", "23", "the template ends" },
  { "TestErrors: js regexp charset unfinished", "<a onclick=\"/foo[\\]/", "2", "21", "the template ends" },
  { "TestErrors: js division or regexp", "<script>{{if .f}}var x = 1{{end}}/-{{.x}}/i.test(x)</script>", "2", "36", "<script>" },
  { "TestErrors: escaper in unquoted attr", "<div class={{.x}}>Hello<div>", "2", "12", "unquoted" },
  { "TestErrors: script template literal if 1", "<script>var a = `{{if .x}}`{{end}}", "2", "35", "the template ends" },
  { "TestErrors: script template literal if 2", "<script>var a = `{{if .x}}a{{else}}`{{end}}", "2", "44", "the template ends" },
  { "attrs: upper-case event handler", "<IMG ONERROR=\"{{.x}}\">", "2", "15", "event handler" },
  { "attrs: mixed-case style", "<a StYlE=\"{{.x}}\">", "2", "11", "'style'" },
  { "attrs: mixed-case srcset", "<img SrcSet=\"{{.x}}\">", "2", "14", "list of URLs" },
  { "attrs: mixed-case script", "<ScRiPt>{{.x}}</sCrIpT>", "2", "9", "<script>" },
  { "attrs: mixed-case style element", "<StYlE>{{.x}}</sTyLe>", "2", "8", "<style>" },
  { "attrs: mixed-case meta http-equiv", "<META HTTP-EQUIV=\"refresh\" CONTENT=\"{{.x}}\">", "2", "37", "http-equiv" },
  { "attrs: mixed-case xlink:href", "<svg><a XLink:Href=\"{{.x}}\">", "2", "29", "the template ends" },
  { "attrs: xlink:href", "<svg><a xlink:href=\"{{.x}}\">", "2", "29", "the template ends" },
  { "attrs: iframe src", "<iframe src=\"{{.x}}\">", "2", "22", "the template ends" },
  { "attrs: sandbox", "<iframe sandbox=\"{{.x}}\">", "2", "26", "the template ends" },
  { "attrs: charset", "<meta charset=\"{{.x}}\">", "2", "16", "charset" },
  { "attrs: xmlns:xlink", "<svg xmlns:xlink=\"http://www.w3.org/1999/xlink\"><a xlink:title=\"{{.x}}\">", "2", "73", "the template ends" },
  { "RCDATA end tag: TestEscape: No RCDATA end tag injection (variant: x = '/textarea ' then a script)", "<textarea></textarea{{.x}}><script>{{.y}}</script>", "2", "21", "complete its end tag" },
  { "RCDATA end tag: slot completes </textarea after '</'", "<textarea></{{.x}}><script>{{.y}}</script>", "2", "13", "complete its end tag" },
  { "RCDATA end tag: slot completes </textarea after '<'", "<textarea><{{.x}}textarea><script>{{.y}}</script>", "2", "12", "complete its end tag" },
  { "RCDATA end tag: slot after '</tex'", "<textarea></tex{{.x}}>", "2", "16", "complete its end tag" },
  { "RCDATA end tag: slot after a full '</textarea'", "<textarea></textarea{{.x}}>{{.y}}", "2", "21", "complete its end tag" },
  { "RCDATA end tag: slot after '</TEXTAREA' (case)", "<textarea></TEXTAREA{{.x}}><a onclick='{{.y}}'>", "2", "21", "complete its end tag" },
  { "RCDATA end tag: title: slot after '</title'", "<title></title{{.x}}><script>{{.y}}</script>", "2", "15", "complete its end tag" },
  { "RCDATA end tag: title: slot after '<'", "<title><{{.x}}title><a href={{.y}}>", "2", "9", "complete its end tag" },
  { "RCDATA end tag: slot after '<' with attributes following", "<textarea></textarea{{.x}}><b {{.y}}>", "2", "21", "complete its end tag" },
  { "RCDATA end tag: slot after '<' after other text", "<textarea>a <b>c<{{.x}}", "2", "18", "complete its end tag" },
  { "RCDATA end tag: slot after '<' in the second text node", "<textarea>{{.x}}<{{.y}}", "2", "18", "complete its end tag" },
  { "RCDATA end tag: slot after '<' across an if", "<textarea><{{if .a}}b{{end}}{{.x}}", "2", "12", "the arms" },
  { "RCDATA end tag: end tag then a space: out of RCDATA", "<textarea></textarea {{.x}}>", "2", "22", "attribute" },
  { "RCDATA end tag: end tag with a tab", "<textarea></textarea\t{{.x}}>", "2", "22", "attribute" },
  { "RCDATA end tag: foreign content: textarea after '<'", "<svg><textarea></textarea{{.x}}></textarea></svg>", "2", "26", "differently" },
  { "RCDATA end tag: foreign content: title after '</'", "<svg><title></{{.x}}></title></svg>", "2", "15", "differently" },
  { "RCDATA end tag: text '<' then slot", "a <{{.x}}", "2", "4", "tag name" },
  { "RCDATA end tag: text '</' then slot", "a </{{.x}}>", "2", "5", "tag name" },
  { "RCDATA end tag: text '<!' then slot", "a <!{{.x}}>", "2", "5", "comment" },
  { "RCDATA end tag: text '<?' then slot", "a <?{{.x}}>", "2", "5", "comment" },
  { "RCDATA end tag: comment '<' then slot", "<!-- <{{.x}} -->", "2", "7", "comment" },
  { "Go attrType: imagesrcset", "<link imagesrcset=\"{{.x}}\">", "2", "20", "list of URLs" },
  { "Go attrType: archive on object", "<object archive=\"{{.x}}\">", "2", "18", "load or run" },
  { "Go attrType: archive on applet", "<applet archive=\"{{.x}}\">", "2", "18", "load or run" },
  { "TestEscape: styleClassPassed", "<style>p{{.x}} { font: Arial }</style>", "2", "9", "<style>" },
  { "TestEscape: styleObfuscatedExpressionBlocked", "<p style=\"width: {{.x}}\">", "2", "18", "'style'" },
  { "TestEscape: styleObfuscatedMozBindingBlocked", "<p style=\"{{.x}}: ...\">", "2", "11", "'style'" },
  { "TestEscape: styleStrEncodedProtocolEncoded", "<a style=\"background: '{{.x}}'\">", "2", "24", "'style'" },
  { "TestEscape: styleURLGoodProtocolPassed", "<a style=\"background: url('{{.x}}')\">", "2", "28", "'style'" },
  { "TestEscape: styleStrGoodProtocolPassed", "<a style=\"background: '{{.x}}'\">", "2", "24", "'style'" },
  { "TestEscape: jsNilValueUntyped", "<button onclick='alert(typeof{{.x}})'>", "2", "30", "event handler" },
}

local KINDS <const>: {string} = { "attr", "rtext", "text", "url" }

--- The kinds of slot `out`, a compiled template, writes: "attr,url", "none".
local function kinds_of(out: string): string
  local found: {string} = {}
  for _, kind in ipairs(KINDS) do
    if out:find("parts[#parts + 1] = _" .. kind .. "(", 1, true) then
      found[#found + 1] = kind
    end
  end
  return #found == 0 and "none" or table.concat(found, ",")
end

local function test_a_ported_case_that_cosmic_takes_has_the_slots_its_place_gives()
  local wrong: {string} = {}
  for _, case in ipairs(ACCEPTED) do
    local out, why = Template.compile(HEAD .. case[2] .. case[3], "t.tmpl")
    if out == nil then
      wrong[#wrong + 1] = case[1] .. ": refused: " .. why
    elseif kinds_of(out) ~= case[4] then
      wrong[#wrong + 1] = case[1] .. ": " .. kinds_of(out) .. ", not " .. case[4]
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
end

local function test_a_ported_case_that_cosmic_refuses_is_refused_where_and_why_it_should()
  local wrong: {string} = {}
  for _, case in ipairs(REFUSED) do
    local out, why = Template.compile(HEAD .. case[2], "t.tmpl")
    local want = "t.tmpl:" .. case[3] .. ":" .. case[4] .. ": "
    if out ~= nil then
      wrong[#wrong + 1] = case[1] .. ": compiled"
    elseif why:sub(1, #want) ~= want or not why:find(case[5], 1, true) then
      wrong[#wrong + 1] = case[1] .. " said " .. why .. ", not " .. want .. "..." .. case[5]
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
end

--- `body` with `{{if .f}}{{end}}`, which emits nothing, put after its `cut`th
--- byte; nil when that byte is inside an action.
local function split_at(body: string, cut: integer): string | nil
  local at = 1
  while true do
    local open, close = body:find("{{.-}}", at)
    if open == nil then
      break
    end
    if cut >= open and cut < close then
      return nil
    end
    at = close + 1
  end
  return body:sub(1, cut) .. "{{if .f}}{{end}}" .. body:sub(cut + 1)
end

-- A block that emits nothing, put between any two bytes of a template's
-- text, must not change what the browser reads, so it must not change the
-- kind of any slot: a template that compiles with it compiles without it,
-- with the same kinds.
local function test_an_empty_action_at_any_byte_boundary_leaves_the_slots_as_they_were()
  local wrong: {string} = {}
  local cases: {string} = {}
  for _, case in ipairs(ACCEPTED) do
    cases[#cases + 1] = case[2] .. case[3]
  end
  for _, case in ipairs(REFUSED) do
    cases[#cases + 1] = case[2]
  end
  for _, body in ipairs({
      "<textarea></textarea><script>{{.x}}</script></textarea>",
      "<title></title><style>a</style><script>{{.x}}</script>",
      "<script><!--\n/*<script>*/\n//</script>\n{{.x}}\n</script>",
      "<script><!--<script></script>-->{{.x}}</script>{{.y}}",
      "<script><!--<script></script>--></script>{{.y}}",
      "<script>a</script >{{.y}}<textarea>b</TextArea\n>{{.z}}",
      "<style>x</style>{{.x}}<textarea></textareax></textarea>{{.y}}",
  }) do
    cases[#cases + 1] = body
  end
  local checked = 0
  for _, body in ipairs(cases) do
    local plain = Template.compile(HEAD .. body, "t.tmpl")
    for cut = 0, #body do
      local split = split_at(body, cut)
      if split ~= nil then
        checked = checked + 1
        local out = Template.compile(HEAD .. split, "t.tmpl")
        if out ~= nil and plain == nil then
          wrong[#wrong + 1] = string.format("%q compiled split at %d: %q", body, cut, split)
        elseif out ~= nil and plain ~= nil and kinds_of(out) ~= kinds_of(plain) then
          wrong[#wrong + 1] = string.format("%q split at %d: %s, not %s", body, cut, kinds_of(out), kinds_of(plain))
        end
      end
    end
  end
  assert(checked > 1000, "too few splits checked: " .. checked)
  assert(#wrong == 0, table.concat(wrong, "\n"))
end

local built = assert(teal.load(true))

--- What `body`, an html template, renders to for `page`: the generated
--- module with its types struck out, run against the real [`cosmic.html`].
local function render(body: string, page: {string: any}): string
  local out, why = Template.compile(HEAD .. body, "t.tmpl")
  assert(out ~= nil, why)
  local code, result = built.gen(out, nil, nil, "tl")
  assert(code ~= nil and #result.syntax_errors == 0, "no Lua for " .. body)
  local env: {string: any} = setmetatable({}, { __index = _G })
  env.require = function(name: string): any
    return name == "cosmic.html" and Html or {}
  end
  local chunk = assert(load(code, "=template", "t", env))
  local loaded = chunk()
  assert(loaded is {string: function}, "no render")
  local made = loaded.render(page)
  assert(made is Html.SafeHtml, "render answered a " .. type(made))
  return (Html.raw(made):gsub("^\n", ""))
end

--- `s` as a quoted attribute value is written.
local function attr(s: string): string
  return Html.raw_attr(Html.escape_attr(s))
end

local INVALID <const> = attr("about:invalid")

--- Template, value of `.x`, and what the template renders to.
local RENDERED <const>: {{string}} = {
  { "<a href='{{.x}}'>", "javascript:alert(%22pwned%22)", "<a href='" .. INVALID .. "'>" },
  { "<a href='  {{.x}}'>", "javascript:alert(%22pwned%22)", "<a href='  " .. INVALID .. "'>" },
  { "<a href=\"{{.x}}\">", "/javascript:80/foo/bar", "<a href=\"" .. attr("/javascript:80/foo/bar") .. "\">" },
  { "<a href='{{.x}}'>", "/foo/bar?a=b&c=d", "<a href='" .. attr("/foo/bar?a=b&c=d") .. "'>" },
  { "<a href='{{.x}}'>", "http://example.com/foo/bar?a=b&c=d",
    "<a href='" .. attr("http://example.com/foo/bar?a=b&c=d") .. "'>" },
  { "<a href='{{.x}}'>", "//example.com:8000/foo/bar?a=b&c=d", "<a href='" .. INVALID .. "'>" },
  { "<a href=\"{{.x}}\">", "mailto:Muhammed \"The Greatest\" Ali <m.ali@example.com>",
    "<a href=\"" .. attr("mailto:Muhammed \"The Greatest\" Ali <m.ali@example.com>") .. "\">" },
  { "<a href=\"{{.x}}\">", "JaVaScRiPt:alert(1)", "<a href=\"" .. INVALID .. "\">" },
  { "<a href=\"{{.x}}\">", "java\tscript:alert(1)", "<a href=\"" .. INVALID .. "\">" },
  { "<a href=\"{{.x}}\">", "\1javascript:alert(1)", "<a href=\"" .. INVALID .. "\">" },
  { "<a href=\"{{.x}}\">", " \njavascript:alert(1)", "<a href=\"" .. INVALID .. "\">" },
  { "<a href=\"{{.x}}\">", "vbscript:alert(1)", "<a href=\"" .. INVALID .. "\">" },
  { "<a href=\"{{.x}}\">", "data:text/html,<script>alert(1)</script>", "<a href=\"" .. INVALID .. "\">" },
  { "<a href=\"{{.x}}\">", "&#106;avascript:alert(1)", "<a href=\"" .. attr("&#106;avascript:alert(1)") .. "\">" },
  { "<meta name=\"d\" content=\"{{.x}}\">", "asd: 123", "<meta name=\"d\" content=\"" .. attr("asd: 123") .. "\">" },
  { "<textarea>{{.x}}</textarea>", "</textarea><script>alert(1)</script>",
    "<textarea>&lt;/textarea&gt;&lt;script&gt;alert(1)&lt;/script&gt;</textarea>" },
  { "<title>{{.x}}</title>", "</title><script>alert(1)</script>",
    "<title>&lt;/title&gt;&lt;script&gt;alert(1)&lt;/script&gt;</title>" },
  { "<div title=\"{{.x}}\">", "\"><script>alert(1)</script>", "<div title=\"" .. attr("\"><script>alert(1)</script>") .. "\">" },
  { "<p>{{.x}}</p>", "<script>alert(1)</script>", "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>" },
  { "<textarea>x < {{.x}}</textarea>", "/textarea>", "<textarea>x < /textarea&gt;</textarea>" },
  { "<svg><a XLink:Href=\"{{.x}}\"></a></svg>", "javascript:alert(1)", "<svg><a XLink:Href=\"" .. INVALID .. "\"></a></svg>" },
  { "<IMG SRC='{{.x}}'>", "javascript:alert(1)", "<IMG SRC='" .. INVALID .. "'>" },
}

local function test_a_number_is_a_text_slot_as_go_prints_a_non_string_value()
  assert(render("{{.n}}", { n = 42 }) == "42")
  assert(render("<p>{{.n}}</p>", { n = 7 }) == "<p>7</p>")
  assert(render("<p title=\"{{.n}}\">", { n = 7 }) == "<p title=\"" .. attr("7") .. "\">")
end

local function test_hostile_values_are_rendered_for_the_place_they_land_in()
  local wrong: {string} = {}
  for _, case in ipairs(RENDERED) do
    local got = render(case[1], { x = case[2] })
    if got ~= case[3] then
      wrong[#wrong + 1] = case[1] .. " with " .. string.format("%q", case[2]) .. " gave " ..
        string.format("%q", got) .. ", not " .. string.format("%q", case[3])
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
end

--- Go's TestURLFilters input: every byte below 0x80, and a few beyond.
local EVERY_BYTE <const> = "\0\1\2\3\4\5\6\7\8\9\10\11\12\13\14\15\16\17\18\19\20\21\22\23\24\25\26\27\28\29\30\31" ..
  " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\127" ..
  "\u{a0}\u{100}\u{2028}\u{2029}\u{feff}\u{1d11e}"

local function test_no_byte_gets_out_of_a_quoted_place_unescaped()
  for _, body in ipairs({ "<p>{{.x}}</p>", "<textarea>{{.x}}</textarea>", "<p title=\"{{.x}}\">", "<p title='{{.x}}'>" }) do
    local got = render(body, { x = EVERY_BYTE })
    local inner = got:gsub("^<%w+[^>]*>", ""):gsub("</?%w+>$", "")
    assert(not inner:find("[<>\"']"), body .. " let a markup byte through: " .. string.format("%q", got))
  end
  local url = render("<a href=\"{{.x}}\">", { x = EVERY_BYTE })
  assert(url == "<a href=\"" .. INVALID .. "\">", url)
end
