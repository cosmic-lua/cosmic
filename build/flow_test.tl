local flow = require("build.flow")

local function formatted(text: string): string
  return (assert(flow.format(text)))
end

local function test_a_canonical_text_comes_back_byte_for_byte()
  local text = table.concat({
    "# a header",
    "",
    "{",
    "  name: \"ci\",",
    "",
    "  # the triggers",
    "  \"on\": {push: {branches: [\"main\"]}, workflow_dispatch: {}},",
    "  jobs: { # every job",
    "    a: {",
    "      \"runs-on\": \"x\", # the runner",
    "      steps: [",
    "        {run: \"echo #1 \\\"q\\\"\"},",
    "        # last",
    "      ],",
    "    },",
    "  },",
    "}",
    "# a footer",
    "",
  }, "\n")
  assert(formatted(text) == text, formatted(text))
end

local function test_layout_is_made_canonical()
  local text = table.concat({
    "{ 'x': 1 }",
  }, "\n")
  assert(flow.format(text) == nil, "a single-quoted string is refused")
  local messy = table.concat({
    "",
    "",
    "{\"name\":   \"ci\" ,  jobs: {},",
    "",
    "",
    "",
    "   \"plain\" : [ 1,2 , true, null ],   list: [",
    "  \"a\", \"b\"",
    "  ]  # after",
    "   , \"on\": \"\\u00e9\" }",
  }, "\n")
  local want = table.concat({
    "{",
    "  name: \"ci\",",
    "  jobs: {},",
    "",
    "  plain: [1, 2, true, null],",
    "  list: [",
    "    \"a\",",
    "    \"b\",",
    "  ], # after",
    "  \"on\": \"é\",",
    "}",
    "",
  }, "\n")
  local got = formatted(messy)
  assert(got == want, got)
  assert(formatted(got) == got)
end

local function test_what_it_cannot_lay_out_is_refused()
  for _, text in ipairs({
    "{a: # between\n 1}",
    "{a 1}",
    "{a: 1 b: 2}",
    "{a: [1}",
    "{a: 1} x",
    "",
  }) do
    local out, why = flow.format(text)
    assert(out == nil and why:match("^line %d+: "), ("%q: %s"):format(text, tostring(out)))
  end
end

local function test_an_edited_tree_keeps_what_it_did_not_touch()
  local text = "# head\n{\n  a: \"x\", # keep\n  b: [1, 2],\n}\n"
  local doc = assert(flow.parse(text))
  doc.root.items[1].value = flow.scalar("y")
  doc.root.items[2].value.items[3] = { value = flow.scalar(3), before = {} }
  assert(flow.render(doc) == "# head\n{\n  a: \"y\", # keep\n  b: [1, 2, 3],\n}\n", flow.render(doc))
end

local function test_keys_are_bare_only_where_yaml_reads_them_as_text()
  assert(flow.bare("name") and flow.bare("merge_group"))
  assert(not flow.bare("on") and not flow.bare("Yes") and not flow.bare("runs-on") and not flow.bare("1a"))
end

local function test_flow_style_is_told_from_block_style()
  assert(flow.is_flow("# c\n\n{a: 1}\n"))
  assert(not flow.is_flow("# c\na: 1\n"))
end

local function test_problems_names_what_the_readers_read_apart()
  local cases: {string: string} = {
    ["{a: 'x'}"] = "single-quoted",
    ["{a: 1} // c"] = "// comment",
    ["{a: 1} /* c */"] = "/* comment",
    ["{a: 1}# c"] = "right after a token",
    ["{a: 1}\t# c"] = 'the character "\\9"',
    ['{a:"x"}'] = "no space after",
    ['{"a"\n: 1}'] = "another line than its key",
    ['{on: "x"}'] = "the bare key on",
    ['{NULL: "x"}'] = "the bare key NULL",
    ['{"a": x}'] = "the bare value x",
    ['{"a": 0x1F}'] = "the bare value 0x1F",
    ['{"a": NaN}'] = "the bare value NaN",
    ['{"a": 1.5}'] = "the bare value 1.5",
    ['{"a": 1234567890123456}'] = "the bare value 1234567890123456",
    ['{"a": "\\\'"}'] = "the escape \\'",
    ['{"a": "x\\\ny"}'] = "the escape \\\n",
    ['{"a": "\\N"}'] = "the escape \\N",
    ['{"a": "\\U0001F600"}'] = "the escape \\U",
    ['{"a": "\\u00"}'] = "the escape \\u",
    ['{"a": 1, "a": 2}'] = "the key a twice",
    ['{a: 1, "a": 2}'] = "the key a twice",
    ["{\\u0061: 1}"] = 'the character "\\\\"',
    ['{\t"a": 1}'] = 'the character "\\9"',
    ['{"a": *x}'] = 'the character "*"',
    ["{\n# c\r\"a\": 1}"] = "a \\r alone",
    ["{\n# c\u{2028}\"a\": 1}"] = "U+2028",
    ["{\n# c\u{85}\"a\": 1}"] = "U+0085",
    ['{"a": "x\u{2029}y"}'] = "U+2029",
    ['{"a": "x\x7fy"}'] = "U+007F",
    ['{"a": "x\u{FFFE}"}'] = "U+FFFE",
    ["{\n# \x01\n}"] = "U+0001",
    ['{"a": "\xff"}'] = "not UTF-8",
    ['{"a": "\\uD83D\\uDE00"}'] = "the escape \\uD83D",
    ['{"a": \u{e9}}'] = 'the character \\xC3',
  }
  for text, want in pairs(cases) do
    local got = flow.problems(text)
    assert(#got >= 1 and got[1]:find(want, 1, true), text .. ": " .. table.concat(got, "; "))
  end
  local fine = '# lead \u{2014} \u{2192} \u{2026}\r\n{\n  "on": {push: {}}, # after\n  a: [true, false, null, 0, -12, 123456789012345,],\n' ..
    '  b: "it\'s # not a comment: //, \\"quoted\\" \\u00e9\\n",\n  "c-d": {a: "x:y"},\n  e: [{a: 1}, {a: 2}],\n}\n'
  local none = flow.problems(fine)
  assert(#none == 0, table.concat(none, "; "))
  local got = flow.problems('{\n  a: 1,\n  b: x,\n}')
  assert(got[1] == "line 3: the bare value x: quote it, or write a decimal integer of at most 15 digits", got[1])
end

--- A string is written with each character the subset refuses raw kept
--- as an escape, which YAML reads as that character and not as a line
--- break or a space.
local function test_characters_yaml_reads_otherwise_stay_escaped()
  for _, escape in ipairs({ "\\u2028", "\\u2029", "\\u0085", "\\u007f", "\\u009b", "\\ufeff", "\\uffff" }) do
    local text = '{\n  a: "x' .. escape .. 'y",\n}\n'
    assert(formatted(text) == text, formatted(text))
  end
  assert(formatted('{a: "\\u00e9"}\n') == '{a: "\u{e9}"}\n')
end

--- Nothing the layout would drop or read otherwise is written: a comment
--- after a key with a blank line before it, text outside the subset, and
--- nesting past what `cosmic.json` reads.
local function test_what_would_be_lost_is_refused()
  local out, why = flow.format("{\n  a:\n\n  # kept?\n  1,\n}\n")
  assert(out == nil and why:find("between a key and its value", 1, true), tostring(why))
  out, why = flow.format("{a:1}\n")
  assert(out == nil and why:find("no space after", 1, true), tostring(why))
  out, why = flow.format("{a: foo}\n")
  assert(out == nil and why:find("the bare value foo", 1, true), tostring(why))
  out, why = flow.format(string.rep("[", 100) .. string.rep("]", 100) .. "\n")
  assert(out == nil and why:find("nested deeper", 1, true), tostring(why))
  local ok = pcall(flow.format, string.rep("[", 300000))
  assert(ok, "deep nesting is refused, not raised")
end

local function test_a_comment_after_the_root_keeps_its_line()
  local text = "{a: 1} # c\n"
  assert(formatted(text) == text, formatted(text))
end

local function test_a_tree_is_built_from_teal_values()
  local Json = require("cosmic.json")
  local text = flow.write({
    jobs = { a = { steps = { { run = "make" } }, ["runs-on"] = "ubuntu-24.04" } },
    on = { push = { branches = { "main" } }, workflow_dispatch = {} },
    name = "ci",
    list = Json.array(),
    nothing = Json.null,
  })
  local want = table.concat({
    "{",
    "  name: \"ci\",",
    "  \"on\": {",
    "    push: {",
    "      branches: [\"main\"],",
    "    },",
    "    workflow_dispatch: {},",
    "  },",
    "  jobs: {",
    "    a: {",
    "      \"runs-on\": \"ubuntu-24.04\",",
    "      steps: [",
    "        {run: \"make\"},",
    "      ],",
    "    },",
    "  },",
    "  list: [],",
    "  nothing: null,",
    "}",
    "",
  }, "\n")
  assert(text == want, text)
  assert(formatted(text) == text)
  local wide = flow.write({ a = { string.rep("x", 60), string.rep("y", 60) } }, { width = 80 })
  assert(wide == "{\n  a: [\n    \"" .. string.rep("x", 60) .. "\",\n    \"" .. string.rep("y", 60) ..
    "\",\n  ],\n}\n", wide)
  assert(not pcall(flow.from, { a = 1.5 }), "a float is refused")
  assert(not pcall(flow.from, { [true] = 1 }), "a key that is no string is refused")
end

local function test_get_and_set_find_and_change_members()
  local doc = assert(flow.parse("{\n  a: {b: [1, 2]}, # keep\n}\n"))
  local b = assert(flow.get(doc.root, "a", "b"))
  assert(assert(flow.get(doc.root, "a", "b", 2)).text == "2")
  assert(flow.get(doc.root, "a", "c") == nil and flow.get(doc.root, "a", "b", 3) == nil)
  flow.set(b, 3, flow.scalar(3))
  flow.set(assert(flow.get(doc.root, "a")), "c", flow.from({ d = true }))
  flow.set(doc.root, "a", assert(flow.get(doc.root, "a")))
  assert(flow.render(doc) == "{\n  a: {b: [1, 2, 3], c: {d: true}}, # keep\n}\n", flow.render(doc))
  assert(not pcall(flow.set, b, 9, flow.scalar(1)), "an index past the end is refused")
  assert(not pcall(flow.set, b, "k", flow.scalar(1)), "a key on an array is refused")
end

local function test_update_keeps_the_comments_of_what_stays()
  local Json = require("cosmic.json")
  local doc = assert(flow.parse(table.concat({
    "{",
    "  # the name",
    "  name: \"ci\",",
    "  gone: 1, # goes",
    "  list: [1, 2, 3],",
    "  kind: {a: 1},",
    "}",
    "",
  }, "\n")))
  doc.root = flow.update(doc.root, {
    name = "cd", list = Json.array({ 1, 5 }), kind = { "x" }, added = { b = 2 },
  })
  local want = table.concat({
    "{",
    "  # the name",
    "  name: \"cd\",",
    "  list: [1, 5],",
    "  kind: [\"x\"],",
    "  added: {b: 2},",
    "}",
    "",
  }, "\n")
  assert(flow.render(doc) == want, flow.render(doc))
  local v = flow.value(doc.root) as {string: any}
  assert(v.name == "cd" and (v.added as {string: any}).b == 2)
end
