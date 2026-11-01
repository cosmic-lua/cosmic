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

local CompileGrammar = require("build.compile_grammar")
local Html = require("cosmic.html")
local Template = require("cosmic.template")

local HEAD <const> = "{{type T from m.t}}\n"

--- Template source, the closer that ends it in text, and the kinds of
--- its slots (sorted: attr, rtext, text, url; "none" for no slot), by
--- the helper each is written with.
local record Accepted name: string source: string tail: string kinds: string end

local ACCEPTED <const>: {Accepted} = {
  { name = "TestEscapeText[0]", source = "{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[1]", source = "Hello, World!{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[2]", source = "I <3 Ponies!{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[5]", source = "<a>{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[13]", source = "<a href=>{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[14]", source = "<a href=x>{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[15]", source = "<a href ='{{.x}}", tail = "'>", kinds = "url" },
  { name = "TestEscapeText[17]", source = "<a href= \"{{.x}}", tail = "\">", kinds = "url" },
  { name = "TestEscapeText[19]", source = "<a title=\"{{.x}}", tail = "\">", kinds = "attr" },
  { name = "TestEscapeText[28]", source = "<img alt=\"1\">{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[30]", source = "<img alt=\"1>\">{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[82]", source = "<!-->{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[83]", source = "<!--->{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[84]", source = "<!-- foo -->{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[92]", source = "<script>foo</script>{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[96]", source = "<script>document.write(\"<script>alert(1)</script>\");{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[98]", source = "<script>document.write(\"<script>alert(1)</script>{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[100]", source = "<script>document.write(\"<script>alert(1)</Script>\");{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[110]", source = "<textarea>value{{.x}}", tail = "</textarea>", kinds = "rtext" },
  { name = "TestEscapeText[111]", source = "<textarea>value</TEXTAREA>{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscapeText[112]", source = "<textarea name=html><b{{.x}}", tail = "</textarea>", kinds = "rtext" },
  { name = "TestEscapeText[113]", source = "<title>value{{.x}}", tail = "</title>", kinds = "rtext" },
  { name = "TestEscapeText[127]", source = "<a svg:style='{{.x}}", tail = "'>", kinds = "attr" },
  { name = "TestEscapeText[129]", source = "<svg:a svg:onclick=\"{{.x}}", tail = "\">", kinds = "attr" },
  { name = "TestEscapeText[130]", source = "<svg:a svg:onclick=\"x()\">{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscape: if", source = "{{if .t}}Hello{{end}}, {{.x}}!", tail = "", kinds = "text" },
  { name = "TestEscape: else", source = "{{if .f}}{{.h}}{{else}}{{.x}}{{end}}!", tail = "", kinds = "text" },
  { name = "TestEscape: withBody", source = "{{with .x}}{{.}}{{end}}", tail = "", kinds = "text" },
  { name = "TestEscape: withElse", source = "{{with .e}}{{.}}{{else}}{{.x}}{{end}}", tail = "", kinds = "text" },
  { name = "TestEscape: rangeBody", source = "{{range .l}}{{.}}{{end}}", tail = "", kinds = "text" },
  { name = "TestEscape: rangeElse", source = "{{range .e}}{{.}}{{else}}{{.x}}{{end}}", tail = "", kinds = "text" },
  { name = "TestEscape: nonStringValue", source = "{{.t}}", tail = "", kinds = "text" },
  { name = "TestEscape: urlStartRel, urlStartAbsOk, protocolRelativeURLStart, dangerousURLStart (one template; the values are in RENDERED)", source = "<a href='{{.x}}'>", tail = "", kinds = "url" },
  { name = "TestEscape: constant", source = "<a href=\"/search?q={{.x}}\">", tail = "", kinds = "part" },
  { name = "TestEscape: urlQuery", source = "<a href='/search?q={{.x}}'>", tail = "", kinds = "part" },
  { name = "TestEscape: urlFragment", source = "<a href='/faq#{{.x}}'>", tail = "", kinds = "part" },
  { name = "TestEscape: urlBranchConflictMoot", source = "<a href=\"{{if .t}}/foo?a={{else}}/bar#{{end}}{{.x}}\">", tail = "", kinds = "part" },
  { name = "TestEscape: optional attrs", source = "<img class=\"{{.x}}\"{{if .t}} id=\"{{.x}}\"{{end}} src={{if .t}}\"?{{.x}}\"{{else}}\"images/cleardot.gif\"{{end}}{{if .t}}title=\"{{.x}}\"{{end}} alt=\"{{if .t}}{{.x}}{{else}}{{if .f}}{{.y}}{{end}}{{end}}\">", tail = "", kinds = "attr,part" },
  { name = "TestErrors: non-error: range in a URL query", source = "<a href='/foo?{{range .l}}&{{.k}}={{.v}}{{end}}'>", tail = "", kinds = "part" },
  { name = "TestErrors: ambiguous URL context", source = "<a href=\"{{if .f}}/foo?a={{else}}/bar/{{end}}{{.x}}\">", tail = "", kinds = "part" },
  { name = "TestEscape: pathRelativeURLStart", source = "<a href=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "TestEscape: dangerousURLStart2", source = "<a href='  {{.x}}'>", tail = "", kinds = "url" },
  { name = "TestEscape: urlBranch", source = "<a href=\"{{if .f}}/foo?a=b{{else}}/bar{{end}}\">", tail = "", kinds = "none" },
  { name = "TestEscape: jsReAmbigOk", source = "<script>{{if .t}}var x = 1{{end}}</script>", tail = "", kinds = "none" },
  { name = "TestEscape: HTML comment", source = "<b>Hello, <!-- name of world -->{{.x}}</b>", tail = "", kinds = "text" },
  { name = "TestEscape: HTML comment not first < in text node.", source = "<<!-- -->!--{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscape: HTML normalization 1", source = "a < b{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscape: HTML normalization 2", source = "a << b{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscape: HTML normalization 3", source = "a<<!-- --><!-- -->b{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscape: HTML doctype not normalized", source = "<!DOCTYPE html>Hello, World!{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscape: HTML doctype not case-insensitive", source = "<!doCtYPE htMl>Hello, World!{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscape: Split HTML comment", source = "<b>Hello, <!-- name of {{if .t}}city -->{{.x}}{{else}}world -->{{.y}}{{end}}</b>", tail = "", kinds = "text" },
  { name = "TestEscape: JS block comment flush with mathematical division", source = "<script>var a/*b*//c\nd</script>", tail = "", kinds = "none" },
  { name = "TestEscape: JS mixed comments", source = "<script>var a/*b*///c\nd</script>", tail = "", kinds = "none" },
  { name = "TestEscape: JS HTML-like comments", source = "<script>before <!-- beep\nbetween\nbefore-->boop\n</script>", tail = "", kinds = "none" },
  { name = "TestEscape: JS hashbang comment", source = "<script>#! beep\n</script>", tail = "", kinds = "none" },
  { name = "TestEscape: Special tags in <script> string literals", source = "<script>var a = \"asd < 123 <!-- 456 < fgh <script jkl < 789 </script\"</script>", tail = "</script>", kinds = "none" },
  { name = "TestEscape: Special tags in <script> string literals (mixed case)", source = "<script>var a = \"<!-- <ScripT </ScripT\"</script>", tail = "</script>", kinds = "none" },
  { name = "TestEscape: Special tags in <script> regex literals (mixed case)", source = "<script>var a = /<!-- <ScripT </ScripT/</script>", tail = "", kinds = "none" },
  { name = "TestEscape: typed HTML in text", source = "{{.h}}", tail = "", kinds = "text" },
  { name = "TestEscape: typed HTML in attribute", source = "<div title=\"{{.h}}\">", tail = "", kinds = "attr" },
  { name = "TestEscape: typed HTML in RCDATA", source = "<textarea>{{.h}}</textarea>", tail = "", kinds = "rtext" },
  { name = "TestEscape: range in textarea", source = "<textarea>{{range .l}}{{.}}{{end}}</textarea>", tail = "", kinds = "rtext" },
  { name = "TestEscape: optional attrs (URL slot at the value's start)", source = "<img class=\"{{.x}}\"{{if .t}} id=\"{{.x}}\"{{end}} src=\"{{if .t}}{{.x}}{{else}}images/cleardot.gif{{end}}\"{{if .t}} title=\"{{.x}}\"{{end}} alt=\"{{if .t}}{{.x}}{{else}}{{if .f}}{{.y}}{{end}}{{end}}\">", tail = "", kinds = "attr,url" },
  { name = "TestEscape: quoted empty attribute value", source = "<p name=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "TestErrors: non-error: if/else", source = "{{if .c}}<a>{{else}}<b>{{end}}", tail = "", kinds = "none" },
  { name = "TestErrors: non-error: if", source = "{{if .c}}<a>{{end}}", tail = "", kinds = "none" },
  { name = "TestErrors: non-error: empty if arm", source = "{{if .c}}{{else}}<b>{{end}}", tail = "", kinds = "none" },
  { name = "TestErrors: non-error: with", source = "{{with .c}}<div>{{end}}", tail = "", kinds = "none" },
  { name = "TestErrors: non-error: range", source = "{{range .l}}<a>{{end}}", tail = "", kinds = "none" },
  { name = "TestErrors: non-error: range with a tag split by if", source = "{{range .l}}<a{{if .x}}{{end}}>{{end}}", tail = "", kinds = "none" },
  { name = "TestErrors: non-error: script template literal", source = "<script>var a = `${a+b}`</script>`", tail = "", kinds = "none" },
  { name = "TestErrors: non-error: script template literal 2", source = "<script>var tmpl = `asd`;</script>", tail = "", kinds = "none" },
  { name = "TestErrors: non-error: script string brace", source = "<script>var tmpl = `asd ${return \"{\"}`;</script>", tail = "", kinds = "none" },
  { name = "TestErrors: non-error: bare meta in if", source = "{{if .c}}<meta>{{end}}", tail = "", kinds = "none" },
  { name = "TestErrors: non-error: meta content in if", source = "{{if .c}}<meta content=\"url={{.x}}\">{{end}}", tail = "", kinds = "attr" },
  { name = "TestErrors: = in unquoted attr 1", source = "<input type=button value=onclick=>", tail = "", kinds = "none" },
  { name = "TestErrors: = in unquoted attr 2", source = "<input type=button value= onclick=>", tail = "", kinds = "none" },
  { name = "TestErrors: = in unquoted attr 3", source = "<input type=button value= 1+1=2>", tail = "", kinds = "none" },
  { name = "TestErrors: backtick in unquoted attr", source = "<a class=`foo>", tail = "", kinds = "none" },
  { name = "TestErrors: quote in unquoted attr", source = "<a style=font:'Arial'>", tail = "", kinds = "none" },
  { name = "TestErrors: = after tag name", source = "<a=foo>", tail = "", kinds = "none" },
  { name = "TestErrors: script template literal if 3", source = "<script>var a = `{{if .x}}a{{else}}b{{end}}`</script>", tail = "", kinds = "none" },
  { name = "attrs: conditional attribute after a value", source = "<a href=\"x\" {{if .t}}class=\"b\"{{end}}>{{.x}}", tail = "", kinds = "text" },
  { name = "TestEscape: conditional valueless attr name", source = "<input{{if .t}} checked{{end}} name=n>{{.x}}", tail = "", kinds = "text" },
  { name = "attrs: space before and after a conditional valueless name", source = "<input {{if .t}}checked {{end}}name=n>{{.x}}", tail = "", kinds = "text" },
  { name = "attrs: conditional attribute with a value", source = "<input{{if .t}} checked=\"\"{{end}} name=n>{{.x}}", tail = "", kinds = "text" },
  { name = "attrs: double quote inside a single-quoted value", source = "<a title='a\"b' href=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: single quote inside a double-quoted value", source = "<a title=\"a'b\" href='{{.x}}'>", tail = "", kinds = "url" },
  { name = "attrs: unquoted value before a URL", source = "<a title=a href=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: backtick value before a URL", source = "<a title=`x` href=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: no space between attributes", source = "<a title=\"a\"href=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: newlines around the equals sign", source = "<a\n href\n=\n\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: tab around the equals sign", source = "<A\tHREF\t=\t'{{.x}}'>", tail = "", kinds = "url" },
  { name = "attrs: slash between attributes", source = "<a/href=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: mixed-case URL attribute", source = "<a hRef=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: upper-case tag and URL attribute", source = "<IMG SRC=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: mixed-case textarea", source = "<TeXtArEa>{{.x}}</tExTaReA>{{.y}}", tail = "", kinds = "rtext,text" },
  { name = "attrs: mixed-case title", source = "<TiTlE>{{.x}}</tItLe>{{.y}}", tail = "", kinds = "rtext,text" },
  { name = "attrs: mixed-case svg", source = "<SVG><a href=\"{{.x}}\"></a></SVG>{{.y}}", tail = "", kinds = "text,url" },
  { name = "attrs: entity in an attribute name", source = "<a hre&#102;=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: action", source = "<form action=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: background", source = "<body background=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: cite", source = "<blockquote cite=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: classid", source = "<span classid=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: codebase", source = "<span codebase=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: data", source = "<span data=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: formaction", source = "<input formaction=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: href", source = "<area href=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: icon", source = "<command icon=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: longdesc", source = "<img longdesc=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: manifest", source = "<html manifest=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: poster", source = "<video poster=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: profile", source = "<head profile=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: src", source = "<img src=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: frame src", source = "<frame src=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: input src", source = "<input type=\"image\" src=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "attrs: track src", source = "<video><track src=\"{{.x}}\"></video>", tail = "", kinds = "url" },
  { name = "attrs: source src", source = "<audio><source src=\"{{.x}}\"></audio>", tail = "", kinds = "url" },
  { name = "attrs: svg image href", source = "<svg><image href=\"{{.x}}\"/></svg>", tail = "", kinds = "url" },
  { name = "attrs: math href", source = "<math href=\"{{.x}}\">", tail = "</math>", kinds = "url" },
  { name = "attrs: accept", source = "<input accept=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: alt", source = "<img alt=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: class", source = "<p class=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: id", source = "<p id=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: title", source = "<p title=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: lang", source = "<p lang=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: placeholder", source = "<input placeholder=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: target", source = "<a target=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: for", source = "<label for=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: name", source = "<input name=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: value", source = "<input value=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: type", source = "<input type=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: rel", source = "<link rel=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: method", source = "<form method=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: content without http-equiv", source = "<meta name=\"d\" content=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: data- attribute", source = "<p data-label=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: aria- attribute", source = "<p aria-label=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: xml:lang", source = "<p xml:lang=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: end-tag attribute", source = "</a title=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "attrs: end-tag URL attribute", source = "</a href=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "RCDATA end tag: a space after '<'", source = "<textarea>x < {{.y}}</textarea>", tail = "", kinds = "rtext" },
  { name = "RCDATA end tag: a longer name than the end tag", source = "<textarea></textareax{{.x}}</textarea>", tail = "", kinds = "rtext" },
  { name = "RCDATA end tag: another tag's start", source = "<textarea><b{{.x}}</textarea>", tail = "", kinds = "rtext" },
  { name = "RCDATA end tag: after '<' closed by '>'", source = "<textarea>a<b>{{.x}}</textarea>", tail = "", kinds = "rtext" },
  { name = "RCDATA end tag: a slot, then text with '<'", source = "<textarea>{{.x}}<b</textarea>", tail = "", kinds = "rtext" },
  { name = "RCDATA end tag: title: another tag's start", source = "<title><i{{.x}}</title>", tail = "", kinds = "rtext" },
  { name = "RCDATA end tag: attribute value '<' then slot (harmless)", source = "<a title=\"<{{.x}}\">", tail = "", kinds = "attr" },
  { name = "split: a dash outside a script comment is no state", source = "<script>{{if .a}}x-{{else}}x{{end}}</script>{{.x}}", tail = "", kinds = "text" },
  { name = "split: a dash pair outside a script comment", source = "<script>{{if .a}}x--{{end}}</script>{{.x}}", tail = "", kinds = "text" },
  { name = "split: RCDATA end tag", source = "<textarea></text{{if .f}}{{end}}area>{{.x}}", tail = "", kinds = "text" },
  { name = "split: RCDATA end tag name and delimiter", source = "<title></title{{if .f}}{{end}}>{{.x}}", tail = "", kinds = "text" },
  { name = "split: script end tag", source = "<script>x</scr{{if .f}}{{end}}ipt>{{.x}}", tail = "", kinds = "text" },
  { name = "split: script comment end", source = "<script><!--<script></script>--{{if .f}}{{end}}></script>{{.x}}", tail = "", kinds = "text" },
  { name = "split: a partial end tag that is not one", source = "<textarea></tex{{if .f}}{{end}}x>{{.y}}</textarea>", tail = "", kinds = "rtext" },
  { name = "TestFindEndTag[0]", source = "<textarea>hello </textarea> hello{{.x}}", tail = "", kinds = "text" },
  { name = "TestFindEndTag[1]", source = "<textarea>hello </TEXTarea> hello{{.x}}", tail = "", kinds = "text" },
  { name = "TestFindEndTag[2]", source = "<textarea>hello </textAREA>{{.x}}", tail = "", kinds = "text" },
  { name = "TestFindEndTag[3]", source = "<textarea>hello </tag> </other> </textarea> <other>{{.x}}", tail = "", kinds = "text" },
  { name = "TestFindEndTag[4]", source = "<textarea></textarea> <other>{{.x}}", tail = "", kinds = "text" },
  { name = "TestFindEndTag[5]", source = "<textarea><div> </div> </TEXTAREA>{{.x}}", tail = "", kinds = "text" },
  { name = "TestFindEndTag[6]", source = "<textarea><div> </div> </TEXTAREA\t>{{.x}}", tail = "", kinds = "text" },
  { name = "TestFindEndTag[7]", source = "<textarea><div> </div> </TEXTAREA >{{.x}}", tail = "", kinds = "text" },
  { name = "TestFindEndTag[8]", source = "<textarea><div> </div> </TEXTAREAfoo{{.x}}", tail = "</textarea>", kinds = "rtext" },
  { name = "TestFindEndTag[9]", source = "<textarea></TEXTAREAfoo </textarea>{{.x}}", tail = "", kinds = "text" },
  { name = "TestFindEndTag[10]", source = "<script><</script >{{.x}}", tail = "", kinds = "text" },
  { name = "TestFindEndTag[11]", source = "<textarea></script>{{.x}}", tail = "</textarea>", kinds = "rtext" },
  { name = "Go attrType: archive elsewhere", source = "<p archive=\"{{.x}}\">", tail = "", kinds = "url" },
  { name = "Go attrType: usemap", source = "<img usemap=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "Go attrType: xmlns", source = "<svg xmlns=\"{{.x}}\">", tail = "</svg>", kinds = "attr" },
  { name = "Go attrType: xmlns:foo", source = "<svg xmlns:foo=\"{{.x}}\">", tail = "</svg>", kinds = "attr" },
  { name = "Go attrType: data-url", source = "<p data-url=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "Go attrType: data-iconUri", source = "<p data-iconUri=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "Go attrType: data-urlItem", source = "<p data-urlItem=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "Go attrType: data-src", source = "<p data-src=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "Go attrType: data-href", source = "<p data-href=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "Go attrType: data-action", source = "<p data-action=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "Go attrType: g:url", source = "<p g:url=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "Go attrType: g:iconUri", source = "<p g:iconUri=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "Go attrType: g:urlItem", source = "<p g:urlItem=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "Go attrType: imgsrc", source = "<p imgsrc=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "Go attrType: my-uri", source = "<p my-uri=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "Go attrType: myurl", source = "<p myurl=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "Go attrType: ng-src", source = "<p ng-src=\"{{.x}}\">", tail = "", kinds = "attr" },
  { name = "Go attrType: svg:href", source = "<svg><a svg:href=\"{{.x}}\"></a></svg>", tail = "", kinds = "attr" },
}

--- Template source, the line and column it is refused at, and a part of
--- the reason. Line 1 is the `{{type}}` line.
local record Refused name: string source: string line: string column: string reason: string end

local REFUSED <const>: {Refused} = {
  { name = "TestEscapeText[3]", source = "<a{{.x}}", line = "2", column = "3", reason = "tag name" },
  { name = "TestEscapeText[4]", source = "<a {{.x}}", line = "2", column = "4", reason = "attribute" },
  { name = "TestEscapeText[6]", source = "<a href{{.x}}", line = "2", column = "8", reason = "attribute" },
  { name = "TestEscapeText[7]", source = "<a on{{.x}}", line = "2", column = "6", reason = "attribute" },
  { name = "TestEscapeText[8]", source = "<a href {{.x}}", line = "2", column = "9", reason = "attribute" },
  { name = "TestEscapeText[9]", source = "<a style  =  {{.x}}", line = "2", column = "14", reason = "unquoted" },
  { name = "TestEscapeText[10]", source = "<a href={{.x}}", line = "2", column = "9", reason = "unquoted" },
  { name = "TestEscapeText[11]", source = "<a href=x{{.x}}", line = "2", column = "10", reason = "unquoted" },
  { name = "TestEscapeText[12]", source = "<a href=x {{.x}}", line = "2", column = "11", reason = "attribute" },
  { name = "TestEscapeText[16]", source = "<a href=''{{.x}}", line = "2", column = "11", reason = "attribute" },
  { name = "TestEscapeText[18]", source = "<a href=\"\"{{.x}}", line = "2", column = "11", reason = "attribute" },
  { name = "TestEscapeText[20]", source = "<a HREF='http:{{.x}}", line = "2", column = "15", reason = "fixes where the URL goes" },
  { name = "TestEscapeText[21]", source = "<a Href='/{{.x}}", line = "2", column = "17", reason = "the template ends" },
  { name = "TestEscapeText[22]", source = "<a href='\"{{.x}}", line = "2", column = "11", reason = "fixes where the URL goes" },
  { name = "TestEscapeText[23]", source = "<a href=\"'{{.x}}", line = "2", column = "11", reason = "fixes where the URL goes" },
  { name = "TestEscapeText[24]", source = "<a href='&apos;{{.x}}", line = "2", column = "16", reason = "fixes where the URL goes" },
  { name = "TestEscapeText[25]", source = "<a href=\"&quot;{{.x}}", line = "2", column = "16", reason = "fixes where the URL goes" },
  { name = "TestEscapeText[26]", source = "<a href=\"&#34;{{.x}}", line = "2", column = "15", reason = "fixes where the URL goes" },
  { name = "TestEscapeText[27]", source = "<a href=&quot;{{.x}}", line = "2", column = "15", reason = "unquoted" },
  { name = "TestEscapeText[29]", source = "<img alt=\"1>\"{{.x}}", line = "2", column = "14", reason = "attribute" },
  { name = "TestEscapeText[31]", source = "<input checked type=\"checkbox\"{{.x}}", line = "2", column = "31", reason = "attribute" },
  { name = "TestEscapeText[32]", source = "<a onclick=\"{{.x}}", line = "2", column = "13", reason = "event handler" },
  { name = "TestEscapeText[33]", source = "<a onclick=\"//foo{{.x}}", line = "2", column = "18", reason = "event handler" },
  { name = "TestEscapeText[34]", source = "<a onclick='//\n{{.x}}", line = "3", column = "1", reason = "event handler" },
  { name = "TestEscapeText[35]", source = "<a onclick='//\r\n{{.x}}", line = "3", column = "1", reason = "event handler" },
  { name = "TestEscapeText[36]", source = "<a onclick='//\u{2028}{{.x}}", line = "2", column = "18", reason = "event handler" },
  { name = "TestEscapeText[37]", source = "<a onclick=\"/*{{.x}}", line = "2", column = "15", reason = "event handler" },
  { name = "TestEscapeText[38]", source = "<a onclick=\"/*/{{.x}}", line = "2", column = "16", reason = "event handler" },
  { name = "TestEscapeText[39]", source = "<a onclick=\"/**/{{.x}}", line = "2", column = "17", reason = "event handler" },
  { name = "TestEscapeText[40]", source = "<a onkeypress=\"&quot;{{.x}}", line = "2", column = "22", reason = "event handler" },
  { name = "TestEscapeText[41]", source = "<a onclick='&quot;foo&quot;{{.x}}", line = "2", column = "28", reason = "event handler" },
  { name = "TestEscapeText[42]", source = "<a onclick=&#39;foo&#39;{{.x}}", line = "2", column = "25", reason = "unquoted" },
  { name = "TestEscapeText[43]", source = "<a onclick=&#39;foo{{.x}}", line = "2", column = "20", reason = "unquoted" },
  { name = "TestEscapeText[44]", source = "<a onclick=\"&quot;foo'{{.x}}", line = "2", column = "23", reason = "event handler" },
  { name = "TestEscapeText[45]", source = "<a onclick=\"'foo&quot;{{.x}}", line = "2", column = "23", reason = "event handler" },
  { name = "TestEscapeText[46]", source = "<a onclick=\"`foo{{.x}}", line = "2", column = "17", reason = "event handler" },
  { name = "TestEscapeText[47]", source = "<A ONCLICK=\"'{{.x}}", line = "2", column = "14", reason = "event handler" },
  { name = "TestEscapeText[48]", source = "<a onclick=\"/{{.x}}", line = "2", column = "14", reason = "event handler" },
  { name = "TestEscapeText[49]", source = "<a onclick=\"'foo'{{.x}}", line = "2", column = "18", reason = "event handler" },
  { name = "TestEscapeText[50]", source = "<a onclick=\"'foo\\'{{.x}}", line = "2", column = "19", reason = "event handler" },
  { name = "TestEscapeText[51]", source = "<a onclick=\"'foo\\'{{.x}}", line = "2", column = "19", reason = "event handler" },
  { name = "TestEscapeText[52]", source = "<a onclick=\"/foo/{{.x}}", line = "2", column = "18", reason = "event handler" },
  { name = "split: arms leave a script end tag cut short", source = "<script>{{if .a}}</sc{{else}}x{{end}}</script>{{.x}}", line = "2", column = "9", reason = "one leaves <script>, another <script> after '</sc'" },
  { name = "split: arms leave a textarea end tag cut short", source = "<textarea>{{if .a}}</te{{end}}</textarea>{{.x}}", line = "2", column = "11", reason = "after '</te'" },
  { name = "split: arms leave a script comment open", source = "<script>{{if .a}}<!--{{end}}</script>{{.x}}", line = "2", column = "9", reason = "inside a <!--" },
  { name = "split: arms leave a nested script open", source = "<script><!--{{if .a}}<script >{{end}}</script>{{.x}}", line = "2", column = "13", reason = "inside a <!-- and a nested <script" },
  { name = "split: a loop leaves a script comment open", source = "<script>{{range .l}}<!--{{end}}</script>{{.x}}", line = "2", column = "9", reason = "inside a <!--" },
  -- An action that emits nothing splits literal text without moving what the browser reads.
  { name = "split: RCDATA end tag, then a script", source = "<textarea></text{{if .f}}{{end}}area><script>{{.x}}</script></textarea>", line = "2", column = "46", reason = "<script>" },
  { name = "split: script comment and nested script", source = "<script><!--\n/*<script>*/{{if .f}}{{end}}\n//</script>\n{{.x}}\n</script>", line = "5", column = "1", reason = "<script>" },
  { name = "split: script end tag after a split nested start", source = "<script><!--<scr{{if .f}}{{end}}ipt></script>{{.x}}", line = "2", column = "46", reason = "<script>" },
  { name = "split: script end tag after a split comment start", source = "<script><!{{if .f}}{{end}}--<script></script>{{.x}}", line = "2", column = "46", reason = "<script>" },
  { name = "split: style end tag name", source = "<style></sty{{if .f}}{{end}}le><script>{{.x}}</script>", line = "2", column = "40", reason = "<script>" },
  { name = "TestEscapeText[53]", source = "<script>/foo/ /={{.x}}", line = "2", column = "17", reason = "<script>" },
  { name = "TestEscapeText[54]", source = "<a onclick=\"1 /foo{{.x}}", line = "2", column = "19", reason = "event handler" },
  { name = "TestEscapeText[55]", source = "<a onclick=\"1 /*c*/ /foo{{.x}}", line = "2", column = "25", reason = "event handler" },
  { name = "TestEscapeText[56]", source = "<a onclick=\"/foo[/]{{.x}}", line = "2", column = "20", reason = "event handler" },
  { name = "TestEscapeText[57]", source = "<a onclick=\"/foo\\/{{.x}}", line = "2", column = "19", reason = "event handler" },
  { name = "TestEscapeText[58]", source = "<a onclick=\"/foo/{{.x}}", line = "2", column = "18", reason = "event handler" },
  { name = "TestEscapeText[59]", source = "<input checked style=\"{{.x}}", line = "2", column = "23", reason = "'style'" },
  { name = "TestEscapeText[60]", source = "<a style=\"//{{.x}}", line = "2", column = "13", reason = "'style'" },
  { name = "TestEscapeText[61]", source = "<a style=\"//</script>{{.x}}", line = "2", column = "22", reason = "'style'" },
  { name = "TestEscapeText[62]", source = "<a style='//\n{{.x}}", line = "3", column = "1", reason = "'style'" },
  { name = "TestEscapeText[63]", source = "<a style='//\r{{.x}}", line = "2", column = "14", reason = "'style'" },
  { name = "TestEscapeText[64]", source = "<a style=\"/*{{.x}}", line = "2", column = "13", reason = "'style'" },
  { name = "TestEscapeText[65]", source = "<a style=\"/*/{{.x}}", line = "2", column = "14", reason = "'style'" },
  { name = "TestEscapeText[66]", source = "<a style=\"/**/{{.x}}", line = "2", column = "15", reason = "'style'" },
  { name = "TestEscapeText[67]", source = "<a style=\"background: '{{.x}}", line = "2", column = "24", reason = "'style'" },
  { name = "TestEscapeText[68]", source = "<a style=\"background: &quot;{{.x}}", line = "2", column = "29", reason = "'style'" },
  { name = "TestEscapeText[69]", source = "<a style=\"background: '/foo?img={{.x}}", line = "2", column = "33", reason = "'style'" },
  { name = "TestEscapeText[70]", source = "<a style=\"background: '/{{.x}}", line = "2", column = "25", reason = "'style'" },
  { name = "TestEscapeText[71]", source = "<a style=\"background: url(&#x22;/{{.x}}", line = "2", column = "34", reason = "'style'" },
  { name = "TestEscapeText[72]", source = "<a style=\"background: url('/{{.x}}", line = "2", column = "29", reason = "'style'" },
  { name = "TestEscapeText[73]", source = "<a style=\"background: url('/){{.x}}", line = "2", column = "30", reason = "'style'" },
  { name = "TestEscapeText[74]", source = "<a style=\"background: url('/ {{.x}}", line = "2", column = "30", reason = "'style'" },
  { name = "TestEscapeText[75]", source = "<a style=\"background: url(/{{.x}}", line = "2", column = "28", reason = "'style'" },
  { name = "TestEscapeText[76]", source = "<a style=\"background: url( {{.x}}", line = "2", column = "28", reason = "'style'" },
  { name = "TestEscapeText[77]", source = "<a style=\"background: url( /image?name={{.x}}", line = "2", column = "40", reason = "'style'" },
  { name = "TestEscapeText[78]", source = "<a style=\"background: url(x){{.x}}", line = "2", column = "29", reason = "'style'" },
  { name = "TestEscapeText[79]", source = "<a style=\"background: url('x'{{.x}}", line = "2", column = "30", reason = "'style'" },
  { name = "TestEscapeText[80]", source = "<a style=\"background: url( x {{.x}}", line = "2", column = "30", reason = "'style'" },
  { name = "TestEscapeText[81]", source = "<!-- foo{{.x}}", line = "2", column = "9", reason = "comment" },
  { name = "TestEscapeText[85]", source = "<script{{.x}}", line = "2", column = "8", reason = "tag name" },
  { name = "TestEscapeText[86]", source = "<script {{.x}}", line = "2", column = "9", reason = "attribute" },
  { name = "TestEscapeText[87]", source = "<script src=\"foo.js\" {{.x}}", line = "2", column = "22", reason = "attribute" },
  { name = "TestEscapeText[88]", source = "<script src='foo.js' {{.x}}", line = "2", column = "22", reason = "attribute" },
  { name = "TestEscapeText[89]", source = "<script type=text/javascript {{.x}}", line = "2", column = "30", reason = "attribute" },
  { name = "TestEscapeText[90]", source = "<script>{{.x}}", line = "2", column = "9", reason = "<script>" },
  { name = "TestEscapeText[91]", source = "<script>foo{{.x}}", line = "2", column = "12", reason = "<script>" },
  { name = "TestEscapeText[93]", source = "<script>foo</script><!--{{.x}}", line = "2", column = "25", reason = "comment" },
  { name = "TestEscapeText[94]", source = "<script>document.write(\"<p>foo</p>\");{{.x}}", line = "2", column = "38", reason = "<script>" },
  { name = "TestEscapeText[95]", source = "<script>document.write(\"<p>foo<\\/script>\");{{.x}}", line = "2", column = "44", reason = "<script>" },
  { name = "TestEscapeText[97]", source = "<script>document.write(\"<script>{{.x}}", line = "2", column = "33", reason = "<script>" },
  { name = "TestEscapeText[99]", source = "<script>document.write(\"<script>alert(1)<!--{{.x}}", line = "2", column = "45", reason = "<script>" },
  { name = "TestEscapeText[101]", source = "<script>document.write(\"<!--\");{{.x}}", line = "2", column = "32", reason = "<script>" },
  { name = "TestEscapeText[102]", source = "<script>let a = /</script{{.x}}", line = "2", column = "26", reason = "<script>" },
  { name = "TestEscapeText[103]", source = "<script>let a = /</script/{{.x}}", line = "2", column = "27", reason = "attribute" },
  { name = "TestEscapeText[104]", source = "<script type=\"text/template\">{{.x}}", line = "2", column = "30", reason = "<script>" },
  { name = "TestEscapeText[105]", source = "<script type=\"TEXT/JAVASCRIPT\">{{.x}}", line = "2", column = "32", reason = "<script>" },
  { name = "TestEscapeText[106]", source = "<script TYPE=\"text/template\">{{.x}}", line = "2", column = "30", reason = "<script>" },
  { name = "TestEscapeText[107]", source = "<script type=\"notjs\">{{.x}}", line = "2", column = "22", reason = "<script>" },
  { name = "TestEscapeText[108]", source = "<Script>{{.x}}", line = "2", column = "9", reason = "<script>" },
  { name = "TestEscapeText[109]", source = "<SCRIPT>foo{{.x}}", line = "2", column = "12", reason = "<script>" },
  { name = "TestEscapeText[114]", source = "<style>value{{.x}}", line = "2", column = "13", reason = "<style>" },
  { name = "TestEscapeText[115]", source = "<a xlink:href{{.x}}", line = "2", column = "14", reason = "attribute" },
  { name = "TestEscapeText[116]", source = "<a xmlns{{.x}}", line = "2", column = "9", reason = "attribute" },
  { name = "TestEscapeText[117]", source = "<a xmlns:foo{{.x}}", line = "2", column = "13", reason = "attribute" },
  { name = "TestEscapeText[118]", source = "<a xmlnsxyz{{.x}}", line = "2", column = "12", reason = "attribute" },
  { name = "TestEscapeText[119]", source = "<a data-url{{.x}}", line = "2", column = "12", reason = "attribute" },
  { name = "TestEscapeText[120]", source = "<a data-iconUri{{.x}}", line = "2", column = "16", reason = "attribute" },
  { name = "TestEscapeText[121]", source = "<a data-urlItem{{.x}}", line = "2", column = "16", reason = "attribute" },
  { name = "TestEscapeText[122]", source = "<a g:{{.x}}", line = "2", column = "6", reason = "attribute" },
  { name = "TestEscapeText[123]", source = "<a g:url{{.x}}", line = "2", column = "9", reason = "attribute" },
  { name = "TestEscapeText[124]", source = "<a g:iconUri{{.x}}", line = "2", column = "13", reason = "attribute" },
  { name = "TestEscapeText[125]", source = "<a g:urlItem{{.x}}", line = "2", column = "13", reason = "attribute" },
  { name = "TestEscapeText[126]", source = "<a g:value{{.x}}", line = "2", column = "11", reason = "attribute" },
  { name = "TestEscapeText[128]", source = "<svg:font-face{{.x}}", line = "2", column = "15", reason = "tag name" },
  { name = "TestEscapeText[131]", source = "<script>var a = `{{.x}}", line = "2", column = "18", reason = "<script>" },
  { name = "TestEscapeText[132]", source = "<script>var a = `${ {{.x}}", line = "2", column = "21", reason = "<script>" },
  { name = "TestEscapeText[133]", source = "<script>var a = `${}{{.x}}", line = "2", column = "21", reason = "<script>" },
  { name = "TestEscapeText[134]", source = "<script>var a = `${`{{.x}}", line = "2", column = "21", reason = "<script>" },
  { name = "TestEscapeText[135]", source = "<script>var a = `${var a = \"{{.x}}", line = "2", column = "29", reason = "<script>" },
  { name = "TestEscapeText[136]", source = "<script>var a = `${var a = \"`{{.x}}", line = "2", column = "30", reason = "<script>" },
  { name = "TestEscapeText[137]", source = "<script>var a = `${var a = \"}{{.x}}", line = "2", column = "30", reason = "<script>" },
  { name = "TestEscapeText[138]", source = "<script>var a = `${``{{.x}}", line = "2", column = "22", reason = "<script>" },
  { name = "TestEscapeText[139]", source = "<script>var a = `${`}{{.x}}", line = "2", column = "22", reason = "<script>" },
  { name = "TestEscapeText[140]", source = "<script>`${ {} } asd`</script><script>`${ {} }{{.x}}", line = "2", column = "47", reason = "<script>" },
  { name = "TestEscapeText[141]", source = "<script>var foo = `${ (_ => { return \"x\" })() + \"${ {{.x}}", line = "2", column = "53", reason = "<script>" },
  { name = "TestEscapeText[142]", source = "<script>var a = `${ {</script><script>var b = `${ x }{{.x}}", line = "2", column = "54", reason = "<script>" },
  { name = "TestEscapeText[143]", source = "<script>var foo = `x` + \"${ {{.x}}", line = "2", column = "29", reason = "<script>" },
  { name = "TestEscapeText[144]", source = "<script>function f() { var a = `${}`; }{{.x}}", line = "2", column = "40", reason = "<script>" },
  { name = "TestEscapeText[145]", source = "<script>{`${}`}{{.x}}", line = "2", column = "16", reason = "<script>" },
  { name = "TestEscapeText[146]", source = "<script>`${ function f() { return `${1}` }() }`{{.x}}", line = "2", column = "48", reason = "<script>" },
  { name = "TestEscapeText[147]", source = "<script>function f() {`${ function f() { `${1}` } }`}{{.x}}", line = "2", column = "54", reason = "<script>" },
  { name = "TestEscapeText[148]", source = "<script>`${ { `` }{{.x}}", line = "2", column = "19", reason = "<script>" },
  { name = "TestEscapeText[149]", source = "<script>`${ { }`{{.x}}", line = "2", column = "17", reason = "<script>" },
  { name = "TestEscapeText[150]", source = "<script>var foo = `${ foo({ a: { c: `${ {{.x}}", line = "2", column = "41", reason = "<script>" },
  { name = "TestEscapeText[151]", source = "<script>var foo = `${ foo({ a: { c: `${ {{.}} }` }, b: ", line = "2", column = "41", reason = "<script>" },
  { name = "TestEscapeText[152]", source = "<script>`${ `}{{.x}}", line = "2", column = "15", reason = "<script>" },
  { name = "TestEscapeText[153]", source = "<script>`${1}${ {{.x}}", line = "2", column = "17", reason = "<script>" },
  { name = "TestEscapeText[154]", source = "<script>`${`${1}${ {{.x}}", line = "2", column = "20", reason = "<script>" },
  { name = "TestEscape: multipleAttrs", source = "<a b=1 c={{.x}}>", line = "2", column = "10", reason = "unquoted" },
  { name = "TestEscape: nonHierURL", source = "<a href={{.x}}>", line = "2", column = "9", reason = "unquoted" },
  { name = "TestEscape: urlPath", source = "<a href='http://{{.x}}/foo'>", line = "2", column = "17", reason = "fixes where the URL goes" },
  { name = "TestEscape: jsStrValue", source = "<button onclick='alert({{.x}})'>", line = "2", column = "24", reason = "event handler" },
  { name = "TestEscape: jsNumericValue", source = "<button onclick='alert({{.n}})'>", line = "2", column = "24", reason = "event handler" },
  { name = "TestEscape: jsBoolValue", source = "<button onclick='alert({{.t}})'>", line = "2", column = "24", reason = "event handler" },
  { name = "TestEscape: jsNilValueTyped", source = "<button onclick='alert(typeof{{.x}})'>", line = "2", column = "30", reason = "event handler" },
  { name = "TestEscape: jsObjValue", source = "<button onclick='alert({{.l}})'>", line = "2", column = "24", reason = "event handler" },
  { name = "TestEscape: jsObjValueScript", source = "<script>alert({{.l}})</script>", line = "2", column = "15", reason = "<script>" },
  { name = "TestEscape: scriptTypeSpace", source = "<script type=\" \">{{.x}}</script>", line = "2", column = "18", reason = "<script>" },
  { name = "TestEscape: scriptTypeTab", source = "<script type=\"\t\">{{.x}}</script>", line = "2", column = "18", reason = "<script>" },
  { name = "TestEscape: scriptTypeEmpty", source = "<script type=\"\">{{.x}}</script>", line = "2", column = "17", reason = "<script>" },
  { name = "TestEscape: jsStr", source = "<button onclick='alert(&quot;{{.x}}&quot;)'>", line = "2", column = "30", reason = "event handler" },
  { name = "TestEscape: badMarshaler", source = "<button onclick='alert(1/{{.x}}in numbers)'>", line = "2", column = "26", reason = "event handler" },
  { name = "TestEscape: jsRe", source = "<button onclick='alert(/{{.x}}/.test(\"\"))'>", line = "2", column = "25", reason = "event handler" },
  { name = "TestEscape: jsReBlank", source = "<script>alert(/{{.x}}/.test(\"\"));</script>", line = "2", column = "16", reason = "<script>" },
  { name = "TestEscape: styleBidiKeywordPassed", source = "<p style=\"dir: {{.x}}\">", line = "2", column = "16", reason = "'style'" },
  { name = "TestEscape: styleBidiPropNamePassed", source = "<p style=\"border-{{.x}}: 0; border-{{.y}}: 1in\">", line = "2", column = "18", reason = "'style'" },
  { name = "TestEscape: styleExpressionBlocked", source = "<p style=\"width: {{.x}}\">", line = "2", column = "18", reason = "'style'" },
  { name = "TestEscape: styleTagSelectorPassed", source = "<style>{{.x}} { color: pink }</style>", line = "2", column = "8", reason = "<style>" },
  { name = "TestEscape: styleIDPassed", source = "<style>p{{.x}} { font: Arial }</style>", line = "2", column = "9", reason = "<style>" },
  { name = "TestEscape: styleQuantityPassed", source = "<a style=\"left: {{.x}}; top: {{.n}}\">", line = "2", column = "17", reason = "'style'" },
  { name = "TestEscape: stylePctPassed", source = "<table style=width:{{.x}}>", line = "2", column = "20", reason = "unquoted" },
  { name = "TestEscape: styleColorPassed", source = "<p style=\"color: {{.x}}; background: {{.y}}\">", line = "2", column = "18", reason = "'style'" },
  { name = "TestEscape: styleMozBindingBlocked", source = "<p style=\"{{.x}}: ...\">", line = "2", column = "11", reason = "'style'" },
  { name = "TestEscape: styleFontNameString", source = "<p style='font-family: \"{{.x}}\", \"{{.y}}\"'>", line = "2", column = "25", reason = "'style'" },
  { name = "TestEscape: styleFontNameUnquoted", source = "<p style='font-family: {{.x}}'>", line = "2", column = "24", reason = "'style'" },
  { name = "TestEscape: styleURLQueryEncoded", source = "<p style=\"background: url(/img?name={{.x}})\">", line = "2", column = "37", reason = "'style'" },
  { name = "TestEscape: styleQuotedURLQueryEncoded", source = "<p style=\"background: url('/img?name={{.x}}')\">", line = "2", column = "38", reason = "'style'" },
  { name = "TestEscape: styleStrQueryEncoded", source = "<p style=\"background: '/img?name={{.x}}'\">", line = "2", column = "34", reason = "'style'" },
  { name = "TestEscape: styleURLBadProtocolBlocked", source = "<a style=\"background: url('{{.x}}')\">", line = "2", column = "28", reason = "'style'" },
  { name = "TestEscape: styleStrBadProtocolBlocked", source = "<a style=\"background: '{{.x}}'\">", line = "2", column = "24", reason = "'style'" },
  { name = "TestEscape: styleURLEncodedForHTMLInAttr", source = "<a style=\"background: url('{{.x}}')\">", line = "2", column = "28", reason = "'style'" },
  { name = "TestEscape: styleURLNotEncodedForHTMLInCdata", source = "<style>body { background: url('{{.x}}') }</style>", line = "2", column = "32", reason = "<style>" },
  { name = "TestEscape: styleURLMixedCase", source = "<p style=\"background: URL(#{{.x}})\">", line = "2", column = "28", reason = "'style'" },
  { name = "TestEscape: stylePropertyPairPassed", source = "<a style='{{.x}}'>", line = "2", column = "11", reason = "'style'" },
  { name = "TestEscape: styleStrSpecialsEncoded", source = "<a style=\"font-family: '{{.x}}', &quot;{{.y}}&quot;\">", line = "2", column = "25", reason = "'style'" },
  { name = "TestEscape: styleURLSpecialsEncoded", source = "<a style=\"border-image: url({{.x}}), url(&quot;{{.y}}&quot;), url('{{.x}}'), 'http://www.example.com/?q={{.y}}''\">", line = "2", column = "29", reason = "'style'" },
  { name = "TestEscape: No doctype injection", source = "<!{{.x}}", line = "2", column = "3", reason = "comment" },
  { name = "TestEscape: JS line comment", source = "<script>for (;;) { if (c()) break// foo not a label\nfoo({{.t}});}</script>", line = "3", column = "5", reason = "<script>" },
  { name = "TestEscape: JS multiline block comment", source = "<script>for (;;) { if (c()) break/* foo not a label\n */foo({{.t}});}</script>", line = "3", column = "8", reason = "<script>" },
  { name = "TestEscape: JS single-line block comment", source = "<script>for (;;) {\nif (c()) break/* foo a label */foo;x({{.t}});}</script>", line = "3", column = "38", reason = "<script>" },
  { name = "TestEscape: CSS comments", source = "<style>p// paragraph\n{border: 1px/* color */{{.x}}}</style>", line = "3", column = "24", reason = "<style>" },
  { name = "TestEscape: JS attr block comment", source = "<a onclick=\"f(&quot;&quot;); /* alert({{.x}}) */\">", line = "2", column = "39", reason = "event handler" },
  { name = "TestEscape: JS attr line comment", source = "<a onclick=\"// alert({{.x}})\">", line = "2", column = "22", reason = "event handler" },
  { name = "TestEscape: CSS attr block comment", source = "<a style=\"/* color: {{.x}} */\">", line = "2", column = "21", reason = "'style'" },
  { name = "TestEscape: CSS attr line comment", source = "<a style=\"// color: {{.x}}\">", line = "2", column = "21", reason = "'style'" },
  { name = "TestEscape: HTML substitution commented out", source = "<p><!-- {{.x}} --></p>", line = "2", column = "9", reason = "comment" },
  { name = "TestEscape: Comment ends flush with start", source = "<!--{{.x}}--><script>/*{{.x}}*///{{.x}}\n</script><style>/*{{.x}}*///{{.x}}\n</style><a onclick='/*{{.x}}*///{{.x}}' style='/*{{.x}}*///{{.x}}'>", line = "2", column = "5", reason = "comment" },
  { name = "TestEscape: typed HTML in script", source = "<button onclick=\"alert({{.h}})\">", line = "2", column = "24", reason = "event handler" },
  { name = "TestEscape: No tag injection", source = "{{.x}}<{{.y}}...", line = "2", column = "8", reason = "tag name" },
  { name = "TestEscape: No comment injection", source = "<{{.x}}", line = "2", column = "2", reason = "tag name" },
  { name = "TestEscape: No RCDATA end tag injection", source = "<textarea><{{.x}}...</textarea>", line = "2", column = "12", reason = "complete its end tag" },
  -- Without the arm, the tag is `<inputname=n>`.
  { name = "TestEscape: conditional valueless attr name (space after)", source = "<input{{if .t}} checked {{end}}name=n>", line = "2", column = "32", reason = "reads differently" },
  { name = "TestEscape: conditional dynamic valueless attr name 1", source = "<input{{if .t}} {{.x}}{{end}} name=n>", line = "2", column = "17", reason = "attribute" },
  { name = "TestEscape: conditional dynamic valueless attr name 2", source = "<input {{if .t}}{{.x}} {{end}}name=n>", line = "2", column = "17", reason = "attribute" },
  { name = "TestEscape: dynamic attribute name", source = "<img on{{.x}}=\"alert({{.y}})\">", line = "2", column = "8", reason = "attribute" },
  { name = "TestEscape: bad dynamic attribute name 1", source = "<input {{.x}}=\"{{.y}}\">", line = "2", column = "8", reason = "attribute" },
  { name = "TestEscape: bad dynamic attribute name 2", source = "<div {{.x}}=\"{{.y}}\">", line = "2", column = "6", reason = "attribute" },
  { name = "TestEscape: bad dynamic attribute name 3", source = "<img {{.x}}=\"{{.y}}\">", line = "2", column = "6", reason = "attribute" },
  { name = "TestEscape: bad dynamic attribute name 4", source = "<input checked {{.x}}=\"Whose value am I?\">", line = "2", column = "16", reason = "attribute" },
  { name = "TestEscape: dynamic element name", source = "<h{{.x}}><table><t{{.y}}>...</h{{.x}}>", line = "2", column = "3", reason = "tag name" },
  { name = "TestEscape: bad dynamic element name", source = "<{{.x}}>{{.y}}</{{.x}}>", line = "2", column = "2", reason = "tag name" },
  { name = "TestEscape: srcset bad URL in second position", source = "<img srcset=\"{{.x}}\">", line = "2", column = "14", reason = "list of URLs" },
  { name = "TestEscape: srcset buffer growth", source = "<img srcset={{.x}}>", line = "2", column = "13", reason = "unquoted" },
  { name = "TestEscape: unquoted empty attribute value (plaintext)", source = "<p name={{.x}}>", line = "2", column = "9", reason = "unquoted" },
  { name = "TestEscape: unquoted empty attribute value (url)", source = "<p href={{.x}}>", line = "2", column = "9", reason = "unquoted" },
  { name = "TestEscape: JS template lit special characters", source = "<script>var a = `{{.x}}`</script>", line = "2", column = "18", reason = "<script>" },
  { name = "TestEscape: JS template lit special characters, nested lit", source = "<script>var a = `${ `{{.x}}` }`</script>", line = "2", column = "22", reason = "<script>" },
  { name = "TestEscape: JS template lit, nested JS", source = "<script>var a = `${ var a = \"{{.x}}\" }`</script>", line = "2", column = "30", reason = "<script>" },
  { name = "TestEscape: meta content attribute url", source = "<meta http-equiv=\"refresh\" content=\"asd; url={{.x}}; asd; url={{.y}}; asd\">", line = "2", column = "46", reason = "http-equiv" },
  { name = "TestEscape: meta content string", source = "<meta http-equiv=\"refresh\" content=\"{{.x}}\">", line = "2", column = "37", reason = "http-equiv" },
  { name = "TestEscape: meta content url with whitespace before equals", source = "<meta http-equiv=\"refresh\" content=\"0;url ={{.x}}\">", line = "2", column = "44", reason = "http-equiv" },
  { name = "TestEscape: meta content url with tab before equals", source = "<meta http-equiv=\"refresh\" content=\"0;url\t={{.x}}\">", line = "2", column = "44", reason = "http-equiv" },
  { name = "TestEscape: meta content url with space after equals", source = "<meta http-equiv=\"refresh\" content=\"0;url= {{.x}}\">", line = "2", column = "44", reason = "http-equiv" },
  { name = "TestEscape: meta content url with whitespace both sides of equals", source = "<meta http-equiv=\"refresh\" content=\"0;url \t= {{.x}}\">", line = "2", column = "46", reason = "http-equiv" },
  { name = "TestEscape: regexp after open brace in if block", source = "<script>if(true){/{{.x}}/g.test(\"x\")}</script>", line = "2", column = "19", reason = "<script>" },
  { name = "TestEscape: regexp after close brace", source = "<script>if(true){x=1}/{{.x}}/g.test(\"x\")</script>", line = "2", column = "23", reason = "<script>" },
  { name = "TestEscape: regexp after open brace in template literal", source = "<script>`${ (function(){/{{.x}}/g.test(x)}) }`</script>", line = "2", column = "26", reason = "<script>" },
  { name = "TestEscape: regexp after close brace in template literal", source = "<script>`${ (function(){}/{{.x}}/g.test(x)) }`</script>", line = "2", column = "27", reason = "<script>" },
  { name = "TestEscape: Issue81821", source = "<script>const s = `${1}${/{{.x}}/g}`</script>", line = "2", column = "27", reason = "<script>" },
  { name = "TestEscape: Issue81823 yield", source = "<script>function* rules(){yield /{{.x}}/g}</script>", line = "2", column = "34", reason = "<script>" },
  { name = "TestEscape: Issue81823 property yield", source = "<script>const pct = bond.yield / 100;\nconst user = {{.x}}; // state\n</script>", line = "3", column = "14", reason = "<script>" },
  { name = "TestEscape: Issue81823 property in", source = "<script>const kb = traffic.in / 1024;\nconst user = {{.x}}; // state\n</script>", line = "3", column = "14", reason = "<script>" },
  { name = "TestEscape: MetaContentEscapeGODEBUG", source = "<meta http-equiv=\"refresh\" content=\"asd; url={{.x}}; asd; url={{.y}}; asd\">", line = "2", column = "46", reason = "http-equiv" },
  { name = "TestErrors: non-error: script slot 1", source = "<script>var tmpl = `${return {{.x}} }`;</script>", line = "2", column = "30", reason = "<script>" },
  { name = "TestErrors: non-error: script slot 2", source = "<script>var tmpl = `${ let a = {1:1} {{.x}} }`;</script>", line = "2", column = "38", reason = "<script>" },
  { name = "TestErrors: branches: tag open in if", source = "{{if .c}}<a{{end}}", line = "2", column = "1", reason = "the arms" },
  { name = "TestErrors: branches: tag open in else", source = "{{if .c}}\n{{else}}\n<a{{end}}", line = "2", column = "1", reason = "the arms" },
  { name = "TestErrors: branches: missing quote in else", source = "{{if .c}}<a href=\"foo\">{{else}}<a href=\"bar>{{end}}", line = "2", column = "1", reason = "the arms" },
  { name = "TestErrors: branches: href vs title", source = "<a {{if .c}}href='{{else}}title='{{end}}{{.x}}'>", line = "2", column = "4", reason = "the arms" },
  { name = "TestErrors: branches: with", source = "\n{{with .x}}<a{{end}}", line = "3", column = "1", reason = "the arms" },
  { name = "TestErrors: branches: with else", source = "\n{{with .x}}<a>{{else}}<a{{end}}", line = "3", column = "1", reason = "the arms" },
  { name = "TestErrors: branches: range loop re-entry", source = "{{range .l}}<a{{end}}", line = "2", column = "1", reason = "ends where it did not begin" },
  { name = "TestErrors: branches: range attr", source = "\n{{range .l}} x='<a{{end}}", line = "3", column = "1", reason = "ends where it did not begin" },
  { name = "TestErrors: ends: unquoted attr", source = "<a b=1 c={{.x}}", line = "2", column = "10", reason = "unquoted" },
  { name = "TestErrors: ends: script", source = "<script>foo();", line = "2", column = "15", reason = "the template ends" },
  { name = "TestErrors: js string unfinished escape 1", source = "<a onclick=\"alert('Hello \\", line = "2", column = "27", reason = "the template ends" },
  { name = "TestErrors: js string unfinished escape 2", source = "<a onclick='alert(\"Hello\\, World\\", line = "2", column = "34", reason = "the template ends" },
  { name = "TestErrors: js regexp unfinished", source = "<a onclick='alert(/x+\\", line = "2", column = "23", reason = "the template ends" },
  { name = "TestErrors: js regexp charset unfinished", source = "<a onclick=\"/foo[\\]/", line = "2", column = "21", reason = "the template ends" },
  { name = "TestErrors: js division or regexp", source = "<script>{{if .f}}var x = 1{{end}}/-{{.x}}/i.test(x)</script>", line = "2", column = "36", reason = "<script>" },
  { name = "TestErrors: escaper in unquoted attr", source = "<div class={{.x}}>Hello<div>", line = "2", column = "12", reason = "unquoted" },
  { name = "TestErrors: script template literal if 1", source = "<script>var a = `{{if .x}}`{{end}}", line = "2", column = "35", reason = "the template ends" },
  { name = "TestErrors: script template literal if 2", source = "<script>var a = `{{if .x}}a{{else}}`{{end}}", line = "2", column = "44", reason = "the template ends" },
  { name = "attrs: upper-case event handler", source = "<IMG ONERROR=\"{{.x}}\">", line = "2", column = "15", reason = "event handler" },
  { name = "attrs: mixed-case style", source = "<a StYlE=\"{{.x}}\">", line = "2", column = "11", reason = "'style'" },
  { name = "attrs: mixed-case srcset", source = "<img SrcSet=\"{{.x}}\">", line = "2", column = "14", reason = "list of URLs" },
  { name = "attrs: mixed-case script", source = "<ScRiPt>{{.x}}</sCrIpT>", line = "2", column = "9", reason = "<script>" },
  { name = "attrs: mixed-case style element", source = "<StYlE>{{.x}}</sTyLe>", line = "2", column = "8", reason = "<style>" },
  { name = "attrs: mixed-case meta http-equiv", source = "<META HTTP-EQUIV=\"refresh\" CONTENT=\"{{.x}}\">", line = "2", column = "37", reason = "http-equiv" },
  { name = "attrs: mixed-case xlink:href", source = "<svg><a XLink:Href=\"{{.x}}\">", line = "2", column = "29", reason = "the template ends" },
  { name = "attrs: xlink:href", source = "<svg><a xlink:href=\"{{.x}}\">", line = "2", column = "29", reason = "the template ends" },
  { name = "attrs: iframe src", source = "<iframe src=\"{{.x}}\">", line = "2", column = "22", reason = "the template ends" },
  { name = "attrs: sandbox", source = "<iframe sandbox=\"{{.x}}\">", line = "2", column = "26", reason = "the template ends" },
  { name = "attrs: charset", source = "<meta charset=\"{{.x}}\">", line = "2", column = "16", reason = "charset" },
  { name = "attrs: xmlns:xlink", source = "<svg xmlns:xlink=\"http://www.w3.org/1999/xlink\"><a xlink:title=\"{{.x}}\">", line = "2", column = "73", reason = "the template ends" },
  { name = "RCDATA end tag: TestEscape: No RCDATA end tag injection (variant: x = '/textarea ' then a script)", source = "<textarea></textarea{{.x}}><script>{{.y}}</script>", line = "2", column = "21", reason = "complete its end tag" },
  { name = "RCDATA end tag: slot completes </textarea after '</'", source = "<textarea></{{.x}}><script>{{.y}}</script>", line = "2", column = "13", reason = "complete its end tag" },
  { name = "RCDATA end tag: slot completes </textarea after '<'", source = "<textarea><{{.x}}textarea><script>{{.y}}</script>", line = "2", column = "12", reason = "complete its end tag" },
  { name = "RCDATA end tag: slot after '</tex'", source = "<textarea></tex{{.x}}>", line = "2", column = "16", reason = "complete its end tag" },
  { name = "RCDATA end tag: slot after a full '</textarea'", source = "<textarea></textarea{{.x}}>{{.y}}", line = "2", column = "21", reason = "complete its end tag" },
  { name = "RCDATA end tag: slot after '</TEXTAREA' (case)", source = "<textarea></TEXTAREA{{.x}}><a onclick='{{.y}}'>", line = "2", column = "21", reason = "complete its end tag" },
  { name = "RCDATA end tag: title: slot after '</title'", source = "<title></title{{.x}}><script>{{.y}}</script>", line = "2", column = "15", reason = "complete its end tag" },
  { name = "RCDATA end tag: title: slot after '<'", source = "<title><{{.x}}title><a href={{.y}}>", line = "2", column = "9", reason = "complete its end tag" },
  { name = "RCDATA end tag: slot after '<' with attributes following", source = "<textarea></textarea{{.x}}><b {{.y}}>", line = "2", column = "21", reason = "complete its end tag" },
  { name = "RCDATA end tag: slot after '<' after other text", source = "<textarea>a <b>c<{{.x}}", line = "2", column = "18", reason = "complete its end tag" },
  { name = "RCDATA end tag: slot after '<' in the second text node", source = "<textarea>{{.x}}<{{.y}}", line = "2", column = "18", reason = "complete its end tag" },
  { name = "RCDATA end tag: slot after '<' across an if", source = "<textarea><{{if .a}}b{{end}}{{.x}}", line = "2", column = "12", reason = "the arms" },
  { name = "RCDATA end tag: end tag then a space: out of RCDATA", source = "<textarea></textarea {{.x}}>", line = "2", column = "22", reason = "attribute" },
  { name = "RCDATA end tag: end tag with a tab", source = "<textarea></textarea\t{{.x}}>", line = "2", column = "22", reason = "attribute" },
  { name = "RCDATA end tag: foreign content: textarea after '<'", source = "<svg><textarea></textarea{{.x}}></textarea></svg>", line = "2", column = "26", reason = "complete its end tag" },
  { name = "RCDATA end tag: foreign content: title after '</'", source = "<svg><title></{{.x}}></title></svg>", line = "2", column = "15", reason = "differently" },
  { name = "RCDATA end tag: text '<' then slot", source = "a <{{.x}}", line = "2", column = "4", reason = "tag name" },
  { name = "RCDATA end tag: text '</' then slot", source = "a </{{.x}}>", line = "2", column = "5", reason = "tag name" },
  { name = "RCDATA end tag: text '<!' then slot", source = "a <!{{.x}}>", line = "2", column = "5", reason = "comment" },
  { name = "RCDATA end tag: text '<?' then slot", source = "a <?{{.x}}>", line = "2", column = "5", reason = "comment" },
  { name = "RCDATA end tag: comment '<' then slot", source = "<!-- <{{.x}} -->", line = "2", column = "7", reason = "comment" },
  { name = "Go attrType: imagesrcset", source = "<link imagesrcset=\"{{.x}}\">", line = "2", column = "20", reason = "list of URLs" },
  { name = "Go attrType: archive on object", source = "<object archive=\"{{.x}}\">", line = "2", column = "18", reason = "load or run" },
  { name = "Go attrType: archive on applet", source = "<applet archive=\"{{.x}}\">", line = "2", column = "18", reason = "load or run" },
  { name = "TestEscape: styleClassPassed", source = "<style>p{{.x}} { font: Arial }</style>", line = "2", column = "9", reason = "<style>" },
  { name = "TestEscape: styleObfuscatedExpressionBlocked", source = "<p style=\"width: {{.x}}\">", line = "2", column = "18", reason = "'style'" },
  { name = "TestEscape: styleObfuscatedMozBindingBlocked", source = "<p style=\"{{.x}}: ...\">", line = "2", column = "11", reason = "'style'" },
  { name = "TestEscape: styleStrEncodedProtocolEncoded", source = "<a style=\"background: '{{.x}}'\">", line = "2", column = "24", reason = "'style'" },
  { name = "TestEscape: styleURLGoodProtocolPassed", source = "<a style=\"background: url('{{.x}}')\">", line = "2", column = "28", reason = "'style'" },
  { name = "TestEscape: styleStrGoodProtocolPassed", source = "<a style=\"background: '{{.x}}'\">", line = "2", column = "24", reason = "'style'" },
  { name = "TestEscape: jsNilValueUntyped", source = "<button onclick='alert(typeof{{.x}})'>", line = "2", column = "30", reason = "event handler" },
}

local KINDS <const>: {string} = { "attr", "rtext", "text", "url", "part" }

--- The kinds of slot `out`, a compiled template, writes: "attr,url", "none".
local function kinds_of(out: string): string
  local found: mut {string} = {}
  for _, kind in ipairs(KINDS) do
    if out:find("parts[#parts + 1] = _" .. kind .. "(", 1, true) then
      found[#found + 1] = kind
    end
  end
  return if #found == 0 then "none" else table.concat(found, ",") end
end

local function test_a_ported_case_that_cosmic_takes_has_the_slots_its_place_gives()
  local wrong: mut {string} = {}
  for _, case in ipairs(ACCEPTED) do
    local out, why = Template.compile(HEAD .. case.source .. case.tail, "t.tmpl")
    if out == nil then
      wrong[#wrong + 1] = case.name .. ": refused: " .. why
    elseif kinds_of(out) ~= case.kinds then
      wrong[#wrong + 1] = case.name .. ": " .. kinds_of(out) .. ", not " .. case.kinds
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
end

local function test_a_ported_case_that_cosmic_refuses_is_refused_where_and_why_it_should()
  local wrong: mut {string} = {}
  for _, case in ipairs(REFUSED) do
    local out, why = Template.compile(HEAD .. case.source, "t.tmpl")
    local want = "t.tmpl:" .. case.line .. ":" .. case.column .. ": "
    if out ~= nil then
      wrong[#wrong + 1] = case.name .. ": compiled"
    elseif why:sub(1, #want) ~= want or not why:find(case.reason, 1, true) then
      wrong[#wrong + 1] = case.name .. " said " .. why .. ", not " .. want .. "..." .. case.reason
    end
  end
  assert(#wrong == 0, table.concat(wrong, "\n"))
end

--- `body` with `{{if .f}}{{end}}`, which emits nothing, put after its `cut`th
--- byte; nil when that byte is inside an action.
local function split_at(body: string, cut: integer): string?
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

--- Compiles each of `cases` with the empty block put at every byte boundary
--- and answers what differs from the case compiled whole, and how many
--- splits it compiled.
local function split_wrong(cases: {string}): {string}, integer
  local wrong: mut {string} = {}
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
  return wrong, checked
end

-- A block that emits nothing, put between any two bytes of a template's
-- text, must not change what the browser reads, so it must not change the
-- kind of any slot: a template that compiles with it compiles without it,
-- with the same kinds. Three tests, so that each stays well inside the
-- time one test may take.
local function test_an_empty_action_at_any_byte_boundary_leaves_accepted_slots_as_they_were()
  local cases: mut {string} = {}
  for _, case in ipairs(ACCEPTED) do
    cases[#cases + 1] = case.source .. case.tail
  end
  local wrong, checked = split_wrong(cases)
  assert(checked > 500, "too few splits checked: " .. tostring(checked))
  assert(#wrong == 0, table.concat(wrong, "\n"))
end

local function test_an_empty_action_at_any_byte_boundary_leaves_refused_slots_as_they_were()
  local cases: mut {string} = {}
  for _, case in ipairs(REFUSED) do
    cases[#cases + 1] = case.source
  end
  local wrong, checked = split_wrong(cases)
  assert(checked > 500, "too few splits checked: " .. tostring(checked))
  assert(#wrong == 0, table.concat(wrong, "\n"))
end

local function test_an_empty_action_at_any_byte_boundary_leaves_raw_text_slots_as_they_were()
  local wrong, checked = split_wrong({
    "<textarea></textarea><script>{{.x}}</script></textarea>",
    "<title></title><style>a</style><script>{{.x}}</script>",
    "<script><!--\n/*<script>*/\n//</script>\n{{.x}}\n</script>",
    "<script><!--<script></script>-->{{.x}}</script>{{.y}}",
    "<script><!--<script></script>--></script>{{.y}}",
    "<script>a</script >{{.y}}<textarea>b</TextArea\n>{{.z}}",
    "<style>x</style>{{.x}}<textarea></textareax></textarea>{{.y}}",
  })
  assert(checked > 100, "too few splits checked: " .. tostring(checked))
  assert(#wrong == 0, table.concat(wrong, "\n"))
end

--- What `body`, an html template, renders to for `page`: the module generated
--- in the new grammar, written as Lua by [`build.compile_grammar`] (which writes it
--- whether or not the checker likes what it reads), run against the real [`cosmic.html`].
local function render(body: string, page: {string: any}): string
  local out, why = Template.compile(HEAD .. body, "t.tmpl", { dialects = nil })
  assert(out ~= nil, why)
  local compiled = assert(CompileGrammar.compile({ { path = "t.tl", relative = "t.tl", text = out, declaration = false } })[1])
  local code = compiled.code
  assert(code ~= nil and #compiled.syntax_errors == 0, "no Lua for " .. body)
  local env: {string: any} = setmetatable({}, { __index = _G })
  env.require = function(name: string): any
    return name == "cosmic.html" and Html or {}
  end
  local chunk = assert(load(assert(code), "=template", "t", env))
  local loaded = chunk()
  assert(loaded is {string: function(...: any): any...}, "no render")
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
local record Rendered source: string x: string want: string end

local RENDERED <const>: {Rendered} = {
  { source = "<a href='{{.x}}'>", x = "javascript:alert(%22pwned%22)", want = "<a href='" .. INVALID .. "'>" },
  { source = "<a href='  {{.x}}'>", x = "javascript:alert(%22pwned%22)", want = "<a href='  " .. INVALID .. "'>" },
  { source = "<a href=\"{{.x}}\">", x = "/javascript:80/foo/bar", want = "<a href=\"" .. attr("/javascript:80/foo/bar") .. "\">" },
  { source = "<a href='{{.x}}'>", x = "/foo/bar?a=b&c=d", want = "<a href='" .. attr("/foo/bar?a=b&c=d") .. "'>" },
  { source = "<a href='{{.x}}'>", x = "http://example.com/foo/bar?a=b&c=d", want = "<a href='" .. attr("http://example.com/foo/bar?a=b&c=d") .. "'>" },
  { source = "<a href='{{.x}}'>", x = "//example.com:8000/foo/bar?a=b&c=d", want = "<a href='" .. INVALID .. "'>" },
  { source = "<a href=\"{{.x}}\">", x = "mailto:Muhammed \"The Greatest\" Ali <m.ali@example.com>", want = "<a href=\"" .. attr("mailto:Muhammed \"The Greatest\" Ali <m.ali@example.com>") .. "\">" },
  { source = "<a href=\"{{.x}}\">", x = "JaVaScRiPt:alert(1)", want = "<a href=\"" .. INVALID .. "\">" },
  { source = "<a href=\"{{.x}}\">", x = "java\tscript:alert(1)", want = "<a href=\"" .. INVALID .. "\">" },
  { source = "<a href=\"{{.x}}\">", x = "\1javascript:alert(1)", want = "<a href=\"" .. INVALID .. "\">" },
  { source = "<a href=\"{{.x}}\">", x = " \njavascript:alert(1)", want = "<a href=\"" .. INVALID .. "\">" },
  { source = "<a href=\"{{.x}}\">", x = "vbscript:alert(1)", want = "<a href=\"" .. INVALID .. "\">" },
  { source = "<a href=\"{{.x}}\">", x = "data:text/html,<script>alert(1)</script>", want = "<a href=\"" .. INVALID .. "\">" },
  { source = "<a href=\"{{.x}}\">", x = "&#106;avascript:alert(1)", want = "<a href=\"" .. attr("&#106;avascript:alert(1)") .. "\">" },
  { source = "<meta name=\"d\" content=\"{{.x}}\">", x = "asd: 123", want = "<meta name=\"d\" content=\"" .. attr("asd: 123") .. "\">" },
  { source = "<textarea>{{.x}}</textarea>", x = "</textarea><script>alert(1)</script>", want = "<textarea>&lt;/textarea&gt;&lt;script&gt;alert(1)&lt;/script&gt;</textarea>" },
  { source = "<title>{{.x}}</title>", x = "</title><script>alert(1)</script>", want = "<title>&lt;/title&gt;&lt;script&gt;alert(1)&lt;/script&gt;</title>" },
  { source = "<div title=\"{{.x}}\">", x = "\"><script>alert(1)</script>", want = "<div title=\"" .. attr("\"><script>alert(1)</script>") .. "\">" },
  { source = "<p>{{.x}}</p>", x = "<script>alert(1)</script>", want = "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>" },
  { source = "<textarea>x < {{.x}}</textarea>", x = "/textarea>", want = "<textarea>x < /textarea&gt;</textarea>" },
  { source = "<svg><a XLink:Href=\"{{.x}}\"></a></svg>", x = "javascript:alert(1)", want = "<svg><a XLink:Href=\"" .. INVALID .. "\"></a></svg>" },
  { source = "<IMG SRC='{{.x}}'>", x = "javascript:alert(1)", want = "<IMG SRC='" .. INVALID .. "'>" },
}

local function test_a_number_is_a_text_slot_as_go_prints_a_non_string_value()
  assert(render("{{.n}}", { n = 42 }) == "42")
  assert(render("<p>{{.n}}</p>", { n = 7 }) == "<p>7</p>")
  assert(render("<p title=\"{{.n}}\">", { n = 7 }) == "<p title=\"" .. attr("7") .. "\">")
end

local function test_a_range_else_renders_as_go_renders_it()
  -- TestEscape: rangeElse, whose list is empty.
  assert(render("{{range .e}}{{.}}{{else}}{{.x}}{{end}}", { e = {}, x = "<Hello>" }) == "&lt;Hello&gt;")
  assert(render("{{range .e}}{{.}}{{else}}{{.x}}{{end}}", { e = { "<a>", "b" }, x = "c" }) == "&lt;a&gt;b")
end

local function test_hostile_values_are_rendered_for_the_place_they_land_in()
  local wrong: mut {string} = {}
  for _, case in ipairs(RENDERED) do
    local got = render(case.source, { x = case.x })
    if got ~= case.want then
      wrong[#wrong + 1] = case.source .. " with " .. string.format("%q", case.x) .. " gave " ..
        string.format("%q", got) .. ", not " .. string.format("%q", case.want)
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
