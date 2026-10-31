--- The speed of [`cosmic.xml`], held to a ratio and never to a clock: four times
--- the input costs about four times the time, read whole or in small chunks, a
--- long token or a long run of text, an element at a time or written back. A
--- limit of eight catches a form that is quadratic (sixteen), as reading a
--- token a chunk left open again at every chunk would be.
local Speed = require("lang.speed")
local Test = require("cosmic.test")
local Xml = require("cosmic.xml")

Test.policy{}

--- A table of `rows` rows of three cells.
local function table_of(rows: integer): string
  local out: mut {string} = { "<table>" }
  for i = 1, rows do
    out[#out + 1] = string.format('<row n="%d"><c>a</c><c>%d</c><c>x &amp; y</c></row>', i, i)
  end
  out[#out + 1] = "</table>"
  return table.concat(out)
end

--- Every event of `text` fed in chunks of `size` bytes to a parser made with `opts`.
local function feed(text: string, size: integer, opts?: Xml.Options): integer
  local p <close> = assert(Xml.parser(opts))
  local count = 0
  for at = 1, #text, size do
    count = count + #(assert(p:feed(text:sub(at, at + size - 1))))
  end
  return count + #(assert(p:finish()))
end

local function test_a_document_reads_in_linear_time()
  local small, large = table_of(500), table_of(2000)
  local ok, why = Speed.within(function()
    assert(Xml.events(small))
  end, function()
    assert(Xml.events(large))
  end, 8)
  assert(ok, "four times the rows cost more than eight times the time: " .. why)
end

--- A token far longer than a chunk is read again only as the text it holds
--- doubles, so feeding it in small chunks stays linear.
local function test_a_long_token_in_small_chunks_reads_in_linear_time()
  local small = '<r a="' .. string.rep("v", 20000) .. '"/>'
  local large = '<r a="' .. string.rep("v", 80000) .. '"/>'
  local ok, why = Speed.within(function()
    assert(feed(small, 64) == 2)
  end, function()
    assert(feed(large, 64) == 2)
  end, 8)
  assert(ok, "four times the token cost more than eight times the time: " .. why)
end

--- A run of text fed in small chunks is held back whole, in a buffer that
--- grows by doubling.
local function test_a_long_text_run_in_small_chunks_reads_in_linear_time()
  local small = "<r>" .. string.rep("text ", 20000) .. "</r>"
  local large = "<r>" .. string.rep("text ", 80000) .. "</r>"
  local ok, why = Speed.within(function()
    assert(feed(small, 64) == 3)
  end, function()
    assert(feed(large, 64) == 3)
  end, 8)
  assert(ok, "four times the text cost more than eight times the time: " .. why)
end

local function test_subtrees_read_in_linear_time()
  local small = assert(Xml.events(table_of(500)))
  local large = assert(Xml.events(table_of(2000)))
  local ok, why = Speed.within(function()
    assert(#Xml.subtrees("table/row"):take(small) == 500)
  end, function()
    assert(#Xml.subtrees("table/row"):take(large) == 2000)
  end, 8)
  assert(ok, "four times the rows cost more than eight times the time: " .. why)
end

local function test_write_is_linear()
  local small = assert(Xml.events(table_of(500)))
  local large = assert(Xml.events(table_of(2000)))
  local ok, why = Speed.within(function()
    assert(Xml.write(small))
  end, function()
    assert(Xml.write(large))
  end, 8)
  assert(ok, "four times the rows cost more than eight times the time: " .. why)
end
