--- The paths a C binding takes when an allocation fails, walked the way
--- Lua's own test suite walks them: run the same work with the first
--- allocation refused, then the second, and so on, until it runs with
--- every allocation granted. Each refusal raises "not enough memory"
--- from wherever Lua asked, or is the NULL a C allocation of the core's
--- own answers with (core/memory.h), and each must leave nothing behind
--- -- no descriptor, no statement, no block on the C heap, no HTTP
--- transfer -- and nothing freed that is still in use.
---
--- "Nothing behind" is checked after a collection: when memory is so
--- short that Lua cannot even call a guard's close, the guard's __gc is
--- what releases it (core/guard.h), and a refusal walk reaches exactly
--- such points. Each run is followed by one, with allocations granted
--- again: a finalizer left pending would otherwise be run by a step of
--- the collector during the next run's refusals, fail to be called, and
--- never be called again.
---
--- Only the checked core can refuse an allocation (core/testing.h), and
--- CI runs this suite on it; any other core has no instrument to
--- refuse one with, which these tests say rather than pass unseen.

local Compress = require("cosmic.compress")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local testing = require("cosmic.internal.testing")

local checked = testing.configuration == "sanitized"

--- Runs `work` once per allocation it makes, refusing that allocation,
--- and a last time with none refused; answers how many runs a refusal
--- ended. A run that nothing was refused in must succeed.
---
--- `settle`, when given, runs after each run with allocations granted
--- again, to release what the run was handed. The work cannot release it
--- itself: a worker's coverage hook runs Lua between any two lines, and
--- can itself be refused, so a refusal can fall between a binding's
--- return and the line that would have released what it returned.
local function under_every_failure(work: function(), settle?: function()): integer
  local ended = 0
  for after = 0, 1000000 do
    testing.fail_allocations(after)
    local ok, failure = pcall(work as function(): any)
    local refused = testing.allow_allocations()
    if settle ~= nil then settle() end
    collectgarbage("collect")
    if refused == 0 then
      assert(ok, "the work failed with every allocation granted: " .. tostring(failure))
      return ended
    end
    ended = ended + 1
  end
  error("the work never ran with every allocation granted")
end

--- The descriptor the next open is handed: the lowest free one, so an
--- earlier one left open shows as a higher number.
local function next_descriptor(tmp: string): integer
  local fd = assert(sys.open(tmp .. "/probe", sys.O_CREAT | sys.O_RDWR, 420))
  sys.close(fd)
  return fd
end

--- Every core says what it is and has every instrument, but only the
--- checked one's instrument: in any other each raises, so no core that
--- ships has an allocator a program can make fail.
local function test_only_the_checked_core_instruments()
  assert(type(testing.configuration) == "string" and testing.configuration ~= "")
  local instruments: {string: function()} = {
    fail_allocations = function()
      testing.fail_allocations(1 << 40)
      testing.allow_allocations()
    end,
    allow_allocations = function() testing.allow_allocations() end,
    open_statements = function() testing.open_statements() end,
    c_heap = function() testing.c_heap() end,
    fail_at = function() testing.fail_at() end,
    live_transfers = function() testing.live_transfers() end,
  }
  for name, use in pairs(instruments) do
    local ok, err: boolean, any = pcall(use)
    if checked then
      assert(ok, name .. ": " .. tostring(err))
    else
      assert(not ok and tostring(err):find(name .. ": only the checked core", 1, true),
        name .. " must raise on the " .. testing.configuration .. " core: " .. tostring(err))
    end
  end
end

local function test_a_refused_allocation_raises_and_is_counted()
  if not checked then return end
  -- Made before refusal starts: the closure is itself an allocation,
  -- and nothing after a refusal outside pcall could even report.
  local allocate = function(): {string} return { string.rep("x", 100) } end
  testing.fail_allocations(0)
  local ok = pcall(allocate)
  local refused = testing.allow_allocations()
  assert(not ok, "a refused allocation must raise")
  assert(refused >= 1, "the refusal must be counted")
  assert(testing.allow_allocations() == 0, "the count starts over")
end

local function test_readdir_releases_its_directory_whenever_an_allocation_fails(tmp: string)
  if not checked then return end
  assert(sys.mkdir(tmp .. "/d"))
  for i = 1, 40 do
    sys.close((assert(sys.open(tmp .. "/d/entry-" .. i, sys.O_CREAT | sys.O_WRONLY, 420))))
  end
  local before = next_descriptor(tmp)
  local ended = under_every_failure(function()
    assert(sys.readdir(tmp .. "/d"))
  end)
  assert(ended > 0, "listing forty entries allocates")
  collectgarbage("collect")
  local after = next_descriptor(tmp)
  assert(after == before, "a refused allocation left descriptor " .. before .. " open")
end

local function test_the_store_finalizes_its_statement_whenever_an_allocation_fails()
  if not checked then return end
  local before = testing.open_statements()
  local ended = under_every_failure(function()
    assert(Store.bytecode("cosmic.fs"))
  end)
  ended = ended + under_every_failure(function()
    Store.meta("compiler")
  end)
  assert(ended > 0, "copying a module's bytes out allocates")
  collectgarbage("collect")
  assert(testing.open_statements() == before,
    "a refused allocation left " .. (testing.open_statements() - before) ..
    " statements open")
end

--- print builds its line in a buffer that moves to the heap past 1 KB;
--- a refusal at any point of that must raise, never free the buffer out
--- from under itself.
local function test_print_survives_every_refused_allocation()
  if not checked then return end
  local long = string.rep(".", 1100)
  local ended = under_every_failure(function()
    print("allocation_test: a long print under refusal ->", long, 42)
  end)
  assert(ended > 0, "a line past the inline buffer allocates")
end

--- open_temporary builds its answer with the descriptor already open; a
--- refusal while it does must close it, not leave it to the process.
local function test_open_temporary_closes_its_descriptor_whenever_an_allocation_fails(tmp: string)
  if not checked then return end
  local path = tmp .. "/t"
  local before = next_descriptor(tmp)
  -- Taken on the line that makes the call, so no hook runs between the
  -- binding's return and the test holding what it returned.
  local received: sys.TemporaryFile
  local opened = 0
  local ended = under_every_failure(function()
    received = sys.open_temporary(path, 420)
  end, function()
    if received ~= nil then
      sys.close(received.fd)
      received = nil
      opened = opened + 1
    end
  end)
  assert(ended > 0, "building the answer allocates")
  assert(opened >= 1, "the run with nothing refused opens a file")
  collectgarbage("collect")
  local after = next_descriptor(tmp)
  assert(after == before, "a refused allocation left descriptor " .. before .. " open")
end

--- execve holds its argv and environment arrays while it fills them from
--- the tables; a refusal at any point of that, and a failed execve after
--- it, must come back through the guards that free them.
local function test_execve_survives_every_refused_allocation(tmp: string)
  if not checked then return end
  local missing = tmp .. "/no-such-program"
  local ended = under_every_failure(function()
    local ok, trouble = sys.execve(missing, { missing, "an argument" }, { NAME = "value" })
    assert(ok == false and trouble ~= nil,
      "a program that is not there cannot run")
  end)
  assert(ended > 0, "joining the environment allocates")
end

--- A pipe is made after its answer is: a refusal leaves neither end open.
local function test_pipe_leaves_no_end_open_whenever_an_allocation_fails(tmp: string)
  if not checked then return end
  local before = next_descriptor(tmp)
  -- Taken on the line that makes the call, and released in `settle`, so
  -- a refused coverage hook cannot fall between the two.
  local received: sys.Pipe
  local made = 0
  local ended = under_every_failure(function()
    received = sys.pipe()
  end, function()
    if received ~= nil then
      sys.close(received.reader)
      sys.close(received.writer)
      received = nil
      made = made + 1
    end
  end)
  assert(ended > 0, "building the answer allocates")
  assert(made >= 1, "the run with nothing refused makes a pipe")
  local after = next_descriptor(tmp)
  assert(after == before, "a refused allocation left descriptor " .. before .. " open")
end

--- A child is reaped only once its answer can be made: a refusal before
--- it leaves the child to wait for again, never its status lost.
local function test_waitpid_never_loses_a_status_to_a_failed_allocation()
  if not checked then return end
  local pid = assert(sys.spawn("/bin/sh", { "sh", "-c", "exit 7" }, nil, nil, nil,
    nil, nil, false))
  local received: sys.ChildStatus
  local reaped: sys.ChildStatus
  under_every_failure(function()
    if reaped == nil then received = sys.waitpid(pid, false) end
  end, function()
    if received ~= nil then
      reaped = received
      received = nil
    end
  end)
  assert(reaped ~= nil, "the child's status was lost to a refused allocation")
  assert(reaped.pid == pid and reaped.code == 7 and reaped.signal == -1)
end

--- An attached database is held by the store or closed: a refusal
--- leaves no connection -- and no descriptor under it -- behind.
local function test_attach_leaves_no_connection_whenever_an_allocation_fails(tmp: string)
  if not checked then return end
  local path = tmp .. "/project.db"
  local db = assert(Sqlite.open(path, true))
  assert(db:exec("CREATE TABLE modules (path TEXT, bytecode BLOB, kind TEXT, " ..
    "source TEXT, file TEXT); CREATE TABLE meta (key TEXT, value TEXT)"))
  assert(db:close())
  local before = next_descriptor(tmp)
  local searched = #Store.databases()
  local ended = under_every_failure(function()
    Store.attach(path)
  end)
  assert(ended > 0, "attaching allocates")
  -- A run can attach and still count a refusal Lua shrugged off (a
  -- string table it could not grow), so the store may hold more than
  -- one: each holds its one descriptor, and nothing else does.
  local held = #Store.databases() - searched
  assert(held >= 1, "the last run attached")
  local after = next_descriptor(tmp)
  assert(after == before + held, "descriptors from " .. before .. " to " .. after ..
    " for " .. held .. " attached: a refused attach left a connection open")
end

--- Asserts the core's own C heap holds what it held when `c_heap`
--- answered `before_bytes` and `before_blocks`: a block a refusal path
--- forgot to free shows here.
local function assert_c_heap(before_bytes: integer, before_blocks: integer, what: string)
  collectgarbage("collect")
  local bytes, blocks = testing.c_heap()
  assert(bytes == before_bytes and blocks == before_blocks,
    what .. " left " .. (blocks - before_blocks) .. " blocks (" ..
    (bytes - before_bytes) .. " bytes) on the C heap")
end

--- The C heap counts what the core's C allocates and frees, and a
--- refused C allocation is counted with Lua's.
local function test_the_c_heap_counts_its_blocks_and_refusals()
  if not checked then return end
  collectgarbage("collect")
  local bytes, blocks = testing.c_heap()
  do
    local _stream = assert(Compress.inflater("raw"))
    local held_bytes, held_blocks = testing.c_heap()
    assert(held_blocks == blocks + 1 and held_bytes > bytes, "an inflater holds its window")
  end
  assert_c_heap(bytes, blocks, "a collected inflater")
  -- Some run grants the userdata and refuses the window: the inflater
  -- answers that refused C allocation with nil and a message.
  local answered = false
  for after = 0, 100 do
    testing.fail_allocations(after)
    local ok, made, trouble = pcall(Compress.inflater, "raw")
    local refused = testing.allow_allocations()
    if ok and made == nil then
      assert(trouble == "out of memory", tostring(trouble))
      assert(refused >= 1, "the refused window is counted")
      answered = true
      break
    end
    if refused == 0 then break end
  end
  assert(answered, "no run refused the window alone")
  assert_c_heap(bytes, blocks, "a refused inflater")
end

--- "hello, cosmic!", as `xz -c` and `bzip2 -c` write it.
local hello = "hello, cosmic!"
local hello_xz = "\253\55\122\88\90\0\0\4\230\214\180\70\2\0\33\1\28\0\0\0\16\207\88\204\1\0\13\104\101\108\108\111\44\32\99\111\115\109\105\99\33\0\0\0\195\231\225\101\211\83\88\122\0\1\38\14\8\27\224\4\31\182\243\125\1\0\0\0\0\4\89\90"
local hello_bz2 = "\66\90\104\57\49\65\89\38\83\89\153\84\167\133\0\0\3\17\128\96\4\10\102\136\0\32\0\34\0\30\160\128\105\166\135\131\39\44\211\152\60\93\201\20\225\66\66\101\82\158\20"

--- Decodes `packed` with `stream` in two pieces and at most four bytes
--- an update, so input is kept back between updates, and answers what
--- came out.
local function decode_in_pieces(stream: Compress.Stream, packed: string): string
  local parts: {string} = {}
  local half = #packed // 2
  for _, piece in ipairs({ packed:sub(1, half), packed:sub(half + 1) }) do
    while true do
      parts[#parts + 1] = assert(stream:update(piece, 4))
      if not stream:pending() then break end
      piece = ""
    end
  end
  parts[#parts + 1] = assert(stream:finish())
  return table.concat(parts)
end

local record Decoding
  name: string
  make: function(): Compress.Stream | nil, string
  input: string
end

--- Every decoder, over a small vector with bytes trailing it, and the
--- deflater, whenever an allocation fails: a refusal raises or answers
--- nil and a message, and leaves no block behind.
local function test_compress_leaves_nothing_whenever_an_allocation_fails()
  if not checked then return end
  local packed: {string: string} = {}
  for _, format in ipairs({ "raw", "zlib", "gzip" } as {Compress.Format}) do
    local encoder = assert(Compress.deflater(format))
    packed[format] = assert(encoder:update(hello)) .. assert(encoder:finish())
  end
  local decodings: {Decoding} = {
    { name = "raw", input = packed.raw,
      make = function(): Compress.Stream | nil, string return Compress.inflater("raw") end },
    { name = "zlib", input = packed.zlib,
      make = function(): Compress.Stream | nil, string return Compress.inflater("zlib") end },
    { name = "gzip", input = packed.gzip .. "trailing",
      make = function(): Compress.Stream | nil, string return Compress.inflater("gzip") end },
    { name = "xz", input = hello_xz .. "trailing",
      make = function(): Compress.Stream | nil, string return Compress.xz_decoder() end },
    { name = "bz2", input = hello_bz2 .. "trailing", make = Compress.bz2_decoder },
  }
  collectgarbage("collect")
  local bytes, blocks = testing.c_heap()
  local ended = 0
  for _, decoding in ipairs(decodings) do
    ended = ended + under_every_failure(function()
      local stream = assert(decoding.make())
      assert(decode_in_pieces(stream, decoding.input) == hello, decoding.name .. " decodes")
      assert(stream:done(), decoding.name .. " is done")
    end)
    assert_c_heap(bytes, blocks, decoding.name .. " decoding under refusal")
  end
  ended = ended + under_every_failure(function()
    local encoder = assert(Compress.deflater("gzip"))
    local out = assert(encoder:update(string.rep(hello, 64))) .. assert(encoder:finish())
    assert(#out > 0)
  end)
  assert_c_heap(bytes, blocks, "deflating under refusal")
  assert(ended > 0, "decoding allocates")
end

--- A hasher holds no C memory of the core's own, and a refusal while it
--- updates or digests leaves none.
local function test_hash_leaves_nothing_whenever_an_allocation_fails()
  if not checked then return end
  collectgarbage("collect")
  local bytes, blocks = testing.c_heap()
  local ended = under_every_failure(function()
    local hasher = assert(Hash.hasher("sha256"))
    hasher:update("hello, ")
    hasher:update("cosmic!")
    local digest = assert(hasher:digest())
    assert(Hash.hex(digest) == Hash.hex_sha256(hello))
  end)
  assert(ended > 0, "a hasher is an allocation")
  assert_c_heap(bytes, blocks, "hashing under refusal")
end

--- `decode` holds a yyjson document and `encode` its output on the C
--- heap; a refusal anywhere, Lua's or theirs, raises or answers nil and
--- a message, and leaves neither behind.
local function test_json_leaves_nothing_whenever_an_allocation_fails()
  if not checked then return end
  local text = '{"b": [1, 2.5, "x\\u00e9", true, null], "a": {"c": {}, "d": []}}'
  local wide: {string: any} = {}
  for i = 1, 40 do wide["key" .. i] = Json.array({ i, "value " .. i }) end
  collectgarbage("collect")
  local bytes, blocks = testing.c_heap()
  local ended = under_every_failure(function()
    local value, trouble = Json.decode(text, { null_value = Json.null })
    assert(trouble == "", trouble)
    assert(Json.encode(value) == '{"a":{"c":{},"d":[]},"b":[1,2.5,"x\xc3\xa9",true,null]}')
    assert(assert(Json.encode(wide, { pretty = true })):sub(1, 1) == "{")
    assert(Json.encode(wide, { sorted = false }) ~= nil)
    local lone = assert(Json.decode('["\\ud83d"]', { lone_surrogates = true })) as {string}
    assert(lone[1] == "\u{FFFD}")
  end)
  assert(ended > 0, "decoding and encoding allocate")
  assert_c_heap(bytes, blocks, "JSON under refusal")
end

--- A whole reply: a status line, `head`'s header lines, and `body`.
local function reply(status: string, head: string, body: string): string
  return "HTTP/1.1 " .. status .. "\r\n" .. head .. "Content-Length: " ..
    tostring(#body) .. "\r\nConnection: close\r\n\r\n" .. body
end

local record Exchange
  name: string
  options: Http.Options
end

--- Each shape of scripted exchange a request walks: a Content-Length
--- body, a chunked one, a redirect curl follows, an interim 100
--- Continue, and a POST with a body and a header.
local exchanges: {Exchange} = {
  { name = "a Content-Length body", options = { script = { reply("200 OK", "", hello) } } },
  { name = "a chunked body", options = { script = {
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ..
    "7\r\nhello, \r\n7\r\ncosmic!\r\n0\r\n\r\n" } } },
  { name = "a redirect", options = { script = {
    reply("302 Found", "Location: /next\r\n", "moved"), reply("200 OK", "", hello) } } },
  { name = "a 100 Continue", options = { script = {
    "HTTP/1.1 100 Continue\r\n\r\n" .. reply("200 OK", "", hello) } } },
  { name = "a POST", options = { method = "POST", body = "payload",
    headers = { ["X-One"] = "1" }, script = { reply("200 OK", "", hello) } } },
}

--- Opens `options`' exchange, reads the body to its end, closes, and
--- answers the body. A response a refusal leaves open is the
--- collector's to close, as any dropped one is.
local function exchange(options: Http.Options): string
  local response = assert(Http.open("http://cosmic.test/", options))
  local parts: {string} = {}
  while true do
    local chunk, trouble = response:read()
    if chunk == nil then
      assert(trouble == "", trouble)
      break
    end
    parts[#parts + 1] = chunk
  end
  response:close()
  return table.concat(parts)
end

--- `open`, `read` to the end and `close`, over each exchange, whenever
--- an allocation fails -- Lua's or a C buffer's: nothing is left behind,
--- no descriptor, no transfer, no block, and the run with nothing
--- refused reads the whole body.
local function test_http_leaves_nothing_whenever_an_allocation_fails(tmp: string)
  if not checked then return end
  -- The first request makes the process-wide state -- curl's global
  -- init, the trust store, the multi handle and its wakeup pair -- which
  -- is made once and kept, so it is made before anything is counted.
  assert(exchange(exchanges[1].options) == hello)
  collectgarbage("collect")
  local before = next_descriptor(tmp)
  local bytes, blocks = testing.c_heap()
  assert(testing.live_transfers() == 0, "no transfer outlives its close")
  local ended = 0
  for _, case in ipairs(exchanges) do
    ended = ended + under_every_failure(function()
      assert(exchange(case.options) == hello, case.name .. " reads the whole body")
    end)
    assert(testing.live_transfers() == 0, case.name .. " left a transfer alive")
    assert_c_heap(bytes, blocks, case.name .. " under refusal")
    local after = next_descriptor(tmp)
    assert(after == before, case.name .. " left descriptor " .. before .. " open")
  end
  assert(ended > 0, "a request allocates")
end
