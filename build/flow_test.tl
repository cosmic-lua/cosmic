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
    "{\"name\":   \"ci\" ,  jobs :{},",
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
