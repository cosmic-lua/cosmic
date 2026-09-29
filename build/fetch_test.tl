--- `cosmic fetch` in process, over `cosmic.http`'s scripted transport
--- (`Io.script`: a canned reply per connection, so no test reaches the
--- network), and one refusal on a closed local port. Like
--- cosmic/http_test.tl it declares only loopback, so it is keyed and
--- runs offline. The program run as a process is build/fetch_tool_test.tl's.

local Child = require("cosmic.child")
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Test = require("cosmic.test")
local fetch = require("build.fetch")

Test.needs{ network = { "127.0.0.1" } }

local url = "http://cosmic.test/data"

local record Ran
  code: integer
  out: string
  err: string
end

local function reply(status: string, head: string, body?: string): string
  body = body or ""
  return "HTTP/1.1 " .. status .. "\r\n" .. head ..
    "Content-Length: " .. tostring(#body) .. "\r\nConnection: close\r\n\r\n" .. body
end

--- Runs `fetch` with `words` after the verb, over `script`; `fail_out`
--- makes every write to standard output fail.
local function run(words: {string}, script: {string}, fail_out?: string): Ran
  local argv: {integer:string} = { "fetch" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local out: {string} = {}
  local err: {string} = {}
  local code = fetch.run(argv, {
    script = script,
    out = function(text: string): boolean, string
      if fail_out ~= nil then return false, fail_out end
      out[#out + 1] = text
      return true, ""
    end,
    err = function(line: string) err[#err + 1] = line .. "\n" end,
  })
  return { code = code, out = table.concat(out), err = table.concat(err) }
end

local function test_the_body_goes_to_standard_output()
  local ran = run({ url }, { reply("200 OK", "", "hello") })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "hello" and ran.err == "", ran.out .. ran.err)
end

local function test_the_body_goes_to_a_file_and_nothing_to_standard_output(tmp: string)
  local path = tmp .. "/got.txt"
  local ran = run({ url, "-o", path }, { reply("200 OK", "", "hello") })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "", ran.out)
  assert(Fs.read(path) == "hello")
end

local function test_a_matching_digest_delivers_the_body(tmp: string)
  local digest = Hash.hex_sha256("hello")
  local ran = run({ "--sha256", digest:upper(), url }, { reply("200 OK", "", "hello") })
  assert(ran.code == 0 and ran.out == "hello", ran.err)
  local path = tmp .. "/ok.txt"
  local filed = run({ url, "-o", path, "--sha256", digest }, { reply("200 OK", "", "hello") })
  assert(filed.code == 0, filed.err)
  assert(Fs.read(path) == "hello")
end

local function test_a_digest_mismatch_names_both_and_sends_nothing(tmp: string)
  local wrong = string.rep("0", 64)
  local right = Hash.hex_sha256("hello")
  local ran = run({ "--sha256", wrong, url }, { reply("200 OK", "", "hello") })
  assert(ran.code == 1, tostring(ran.code))
  assert(ran.out == "", "nothing may be sent before the digest is checked: " .. ran.out)
  assert(ran.err:find(wrong, 1, true) and ran.err:find(right, 1, true), ran.err)
  local path = tmp .. "/never.txt"
  local filed = run({ url, "-o", path, "--sha256", wrong }, { reply("200 OK", "", "hello") })
  assert(filed.code == 1, tostring(filed.code))
  assert(filed.err:find(wrong, 1, true) and filed.err:find(right, 1, true), filed.err)
  assert(Fs.exists(path) == false, "a failed digest leaves nothing at -o")
  local entries = assert(Fs.list(tmp))
  for _, name in ipairs(entries) do
    assert(not name:find("never", 1, true), "a temporary file was left: " .. name)
  end
end

local function test_a_bad_status_fails_and_names_it(tmp: string)
  local ran = run({ url }, { reply("404 Not Found", "", "<html>no</html>") })
  assert(ran.code == 1, tostring(ran.code))
  assert(ran.out == "", "an error page must not reach a pipe: " .. ran.out)
  assert(ran.err:find("HTTP 404", 1, true), ran.err)
  local path = tmp .. "/page.html"
  local filed = run({ url, "-o", path }, { reply("500 Oops", "", "x") })
  assert(filed.code == 1 and filed.err:find("HTTP 500", 1, true), filed.err)
  assert(Fs.exists(path) == false)
end

local function test_a_redirect_is_followed()
  local ran = run({ url }, {
    reply("302 Found", "Location: /next\r\n", "moved"),
    reply("200 OK", "", "final"),
  })
  assert(ran.code == 0 and ran.out == "final", ran.err .. ran.out)
end

local function test_a_redirect_loop_fails()
  local script: {string} = {}
  for _ = 1, 12 do script[#script + 1] = reply("302 Found", "Location: /again\r\n") end
  local ran = run({ url }, script)
  assert(ran.code == 1 and ran.out == "", ran.err)
  assert(ran.err:find("cosmic: fetch: ", 1, true) == 1, ran.err)
end

local function test_head_prints_the_status_and_headers()
  local ran = run({ "--head", url }, { reply("200 OK", "X-One: 1\r\nA-Two: b\r\n", "body") })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("^HTTP 200\n"), ran.out)
  assert(ran.out:find("x-one: 1\n", 1, true) and ran.out:find("a-two: b\n", 1, true), ran.out)
  assert(ran.out:find("a-two", 1, true) < ran.out:find("x-one", 1, true), "sorted: " .. ran.out)
  assert(not ran.out:find("body", 1, true), ran.out)
end

local function test_head_json_prints_an_object()
  local ran = run({ "--head", "--json", url }, { reply("200 OK", "X-One: 1\r\n", "body") })
  assert(ran.code == 0, ran.err)
  local object = assert(Json.decode(ran.out)) as {string:any}
  assert(object.status == 200, ran.out)
  assert(object.url == url, ran.out)
  local headers = object.headers as {string:string}
  assert(headers["x-one"] == "1", ran.out)
end

local function test_head_prints_then_fails_on_a_bad_status()
  local ran = run({ "--head", url }, { reply("404 Not Found", "X-One: 1\r\n") })
  assert(ran.code == 1, tostring(ran.code))
  assert(ran.out:find("^HTTP 404\n"), ran.out)
  assert(ran.err:find("HTTP 404", 1, true), ran.err)
end

local function test_a_bad_url_or_command_line_is_a_usage_error()
  for _, words in ipairs({
    { "notaurl" }, { "ftp://example.com/x" }, { "http://" }, { "http://@/" }, { "http://:80/" }, { "http://u:p@:80/x" }, {}, { url, "extra" },
    { url, "--bogus" }, { url, "--sha256", "abc" }, { url, "--json" },
    { url, "--head", "-o", "x" }, { url, "-o", "" },
  } as {{string}}) do
    local ran = run(words, {})
    assert(ran.code == 2, table.concat(words, " ") .. " exited " .. ran.code .. ": " .. ran.err)
    assert(ran.out == "" and ran.err:find("cosmic: fetch: ", 1, true) == 1, ran.err)
  end
end

local function test_a_refused_connection_fails()
  -- Port 1 is never listening (as cosmic/http_test.tl's probe is);
  -- TODO: bind and close an ephemeral port instead, once a socket
  -- module of the tree can bind one.
  local ran = run({ "http://127.0.0.1:1/" }, nil)
  assert(ran.code == 1, tostring(ran.code) .. ran.err)
  assert(ran.out == "" and ran.err:find("cosmic: fetch: http://127.0.0.1:1/", 1, true) == 1, ran.err)
end

local function test_a_failed_write_to_standard_output_exits_two()
  local ran = run({ url }, { reply("200 OK", "", "hello") }, "no space left")
  assert(ran.code == 2, tostring(ran.code))
  assert(ran.err:find("standard output: no space left", 1, true), ran.err)
  local head = run({ "--head", url }, { reply("200 OK", "") }, "broken pipe")
  assert(head.code == 2, tostring(head.code))
  local verified = run({ "--sha256", Hash.hex_sha256("hello"), url },
    { reply("200 OK", "", "hello") }, "broken pipe")
  assert(verified.code == 2, tostring(verified.code))
end

local function test_credentials_never_reach_a_message_or_the_json(tmp: string)
  local secret = "http://user:hunter2@cosmic.test/data"
  for _, words in ipairs({ { secret }, { secret, "-o", tmp .. "/x" },
      { "--sha256", string.rep("0", 64), secret } } as {{string}}) do
    local ran = run(words, { reply("404 Not Found", "", "no") })
    assert(ran.code == 1, ran.err)
    assert(not ran.err:find("hunter2", 1, true) and not ran.err:find("user:", 1, true), ran.err)
    assert(ran.err:find("***@cosmic.test", 1, true), ran.err)
  end
  local mismatch = run({ secret, "-o", tmp .. "/y", "--sha256", string.rep("0", 64) },
    { reply("200 OK", "", "hello") })
  assert(mismatch.code == 1 and not mismatch.err:find("hunter2", 1, true), mismatch.err)
  local json = run({ "--head", "--json", secret }, { reply("200 OK", "") })
  assert(json.code == 0 and not json.out:find("hunter2", 1, true), json.out)
  assert(json.out:find("***@cosmic.test", 1, true), json.out)
  local refused = run({ "http://user:hunter2@127.0.0.1:1/" }, nil)
  assert(refused.code == 1 and not refused.err:find("hunter2", 1, true), refused.err)
end

local function test_head_escapes_control_bytes_in_header_values()
  local ran = run({ "--head", url }, { reply("200 OK", "X-Evil: a\027[31mb\1c\127d\te\r\n") })
  assert(ran.code == 0, ran.err)
  assert(not ran.out:find("\027", 1, true), "an escape byte reached the terminal")
  assert(ran.out:find("x-evil: a\\x1B[31mb\\x01c\\x7Fd\te\n", 1, true), ran.out)
end

local function test_a_truncated_body_fails_after_what_arrived()
  local cut = "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nabc"
  local ran = run({ url }, { cut })
  assert(ran.code == 1, tostring(ran.code) .. ran.err)
  assert(ran.err:find("cosmic: fetch: ", 1, true) == 1, ran.err)
  local verified = run({ "--sha256", string.rep("0", 64), url }, { cut })
  assert(verified.code == 1 and verified.out == "", verified.out .. verified.err)
end

local function test_sha256_on_standard_output_with_a_bad_status_sends_nothing()
  local ran = run({ "--sha256", Hash.hex_sha256("no"), url }, { reply("404 Not Found", "", "no") })
  assert(ran.code == 1 and ran.out == "", ran.out)
  assert(ran.err:find("HTTP 404", 1, true), ran.err)
end

-- TODO: drive a real https start that redirects to http (refused) and
-- to https (followed) through `fetch.run`, once the tree has a loopback
-- TLS server (a certificate the test trusts and a socket that can bind
-- and accept); none exists, and a canned reply cannot finish a
-- handshake, so only the decision (`redirect_protocols`, `refusal`) and
-- cosmic/http_test.tl's scripted http cases are covered.
local function test_an_https_start_limits_redirects_to_https_unless_allowed()
  local limited = fetch.redirect_protocols("https://example.test/a", false)
  assert(#limited == 1 and limited[1] == "https")
  limited = fetch.redirect_protocols("HTTPS://example.test/a", false)
  assert(#limited == 1 and limited[1] == "https")
  assert(fetch.redirect_protocols("https://example.test/a", true) == nil)
  assert(fetch.redirect_protocols("http://example.test/a", false) == nil)
end

local function test_a_refused_downgrade_is_named_plainly()
  local curl = 'Protocol "http" is disabled (in redirect)'
  local said = fetch.refusal(curl, { "https" })
  assert(said:find("refused a redirect from https to http", 1, true) ~= nil, said)
  assert(said:find("--allow-downgrade", 1, true) ~= nil, said)
  assert(fetch.refusal(curl, nil) == curl, "a fetch not limited to https says what curl said")
  assert(fetch.refusal("Could not resolve host", { "https" }) == "Could not resolve host")
end

local function test_an_http_redirect_from_an_http_start_is_still_followed()
  local ran = run({ url }, { reply("302 Found", "Location: http://other.test/x\r\n"), reply("200 OK", "", "ok") })
  assert(ran.code == 0 and ran.out == "ok", ran.err)
end

local function test_allow_downgrade_is_a_flag_and_not_a_usage_error()
  local ran = run({ "--allow-downgrade", url }, { reply("200 OK", "", "ok") })
  assert(ran.code == 0 and ran.out == "ok", ran.err)
end

local function test_a_cancelled_download_leaves_no_file_and_fails(tmp: string)
  local path = tmp .. "/got.txt"
  local argv: {integer:string} = { "fetch", url, "-o", path }
  local err: {string} = {}
  local code = fetch.run(argv, {
    script = { reply("200 OK", "", string.rep("y", 200000)) },
    out = function(_text: string): boolean, string return true, "" end,
    err = function(line: string) err[#err + 1] = line end,
    cancelled = function(): boolean return true end,
  })
  assert(code == 1, tostring(code))
  assert(table.concat(err):find("cancelled", 1, true) ~= nil, table.concat(err))
  assert(Fs.stat(path) == nil, "the target was created")
  for _, name in ipairs((assert(Fs.list(tmp)))) do
    assert(not name:find("got.txt", 1, true), "left behind: " .. name)
  end
end

--- The guard `-o` holds is closed on every way out, a complaint that
--- raises included: left open, it would hold SIGINT and SIGTERM for the
--- rest of the process, and a later `Child.guard` would be refused.
local function test_the_guard_is_closed_when_a_complaint_raises(tmp: string)
  local ok, trouble = pcall(fetch.run, { "fetch", url, "-o", tmp .. "/got" } as {integer:string}, {
    script = { reply("404 Not Found", "", "no") },
    out = function(_text: string): boolean, string return true, "" end,
    err = function(_line: string) error("stderr is gone") end,
  })
  assert(not ok and tostring(trouble):find("stderr is gone", 1, true) ~= nil, tostring(trouble))
  local guard, why = Child.guard()
  assert(guard ~= nil, "the guard was left open: " .. tostring(why))
  assert(guard:close())
end

local function sha512_of(text: string): string
  return Codec.hex(Hash.digest("sha512", text))
end

local function test_a_sha256_fragment_verifies_and_refuses(tmp: string)
  local good = Hash.hex_sha256("hello")
  local ran = run({ url .. "#sha256=" .. good }, { reply("200 OK", "", "hello") })
  assert(ran.code == 0 and ran.out == "hello", ran.err)
  local bad = run({ url .. "#sha256=" .. string.rep("0", 64) }, { reply("200 OK", "", "hello") })
  assert(bad.code == 1 and bad.out == "", bad.err)
  assert(bad.err:find("sha256 mismatch: want " .. string.rep("0", 64) .. ", got " .. good, 1, true), bad.err)
  local path = tmp .. "/frag.txt"
  local filed = run({ url .. "#sha256=" .. good:upper(), "-o", path }, { reply("200 OK", "", "hello") })
  assert(filed.code == 0 and Fs.read(path) == "hello", filed.err)
end

local function test_a_sha512_fragment_verifies_and_refuses()
  local good = sha512_of("hello")
  local ran = run({ url .. "#sha512=" .. good }, { reply("200 OK", "", "hello") })
  assert(ran.code == 0 and ran.out == "hello", ran.err)
  local bad = run({ url .. "#sha512=" .. string.rep("0", 128) }, { reply("200 OK", "", "hello") })
  assert(bad.code == 1 and bad.out == "", bad.err)
  assert(bad.err:find("sha512 mismatch: want " .. string.rep("0", 128) .. ", got " .. good, 1, true), bad.err)
  local flagged = run({ "--sha512", good:upper(), url }, { reply("200 OK", "", "hello") })
  assert(flagged.code == 0 and flagged.out == "hello", flagged.err)
end

local function test_the_sum_aliases_work()
  local ran = run({ url .. "#sha256sum=" .. Hash.hex_sha256("hello") }, { reply("200 OK", "", "hello") })
  assert(ran.code == 0 and ran.out == "hello", ran.err)
  local ran512 = run({ url .. "#sha512sum=" .. sha512_of("hello") }, { reply("200 OK", "", "hello") })
  assert(ran512.code == 0, ran512.err)
  local bad = run({ url .. "#sha256sum=" .. string.rep("1", 64) }, { reply("200 OK", "", "hello") })
  assert(bad.code == 1, bad.err)
end

local function test_the_fragment_never_reaches_the_request_or_a_message()
  local ran = run({ "--head", "--json", url .. "#frag" }, { reply("200 OK", "") })
  assert(ran.code == 0, ran.err)
  assert(not ran.out:find("#", 1, true), ran.out)
  local secret = string.rep("a", 64)
  local failed = run({ url .. "#sha256=" .. secret }, { reply("404 Not Found", "", "no") })
  assert(failed.code == 1 and not failed.err:find("#", 1, true) and not failed.err:find(secret, 1, true), failed.err)
  local refused = run({ "http://cosmic.test:notaport/x#sha256=" .. secret }, {})
  assert(not refused.err:find("#", 1, true), refused.err)
end

local function test_a_flag_and_fragment_that_disagree_are_refused_before_any_request()
  local a, b = Hash.hex_sha256("hello"), string.rep("2", 64)
  -- no script: a request would fail as exit 1, not the usage error
  local ran = run({ "--sha256", a, url .. "#sha256=" .. b }, {})
  assert(ran.code == 2 and ran.out == "", tostring(ran.code) .. ran.err)
  assert(ran.err:find("--sha256", 1, true) and ran.err:find("#sha256", 1, true), ran.err)
  assert(ran.err:find(a, 1, true) and ran.err:find(b, 1, true), ran.err)
  local same = run({ "--sha256", a:upper(), url .. "#sha256=" .. a }, { reply("200 OK", "", "hello") })
  assert(same.code == 0 and same.out == "hello", same.err)
  local twice = run({ url .. "#sha256=" .. a .. "&sha256sum=" .. b }, {})
  assert(twice.code == 2, twice.err)
end

local function test_different_algorithms_must_both_match(tmp: string)
  local s256, s512 = Hash.hex_sha256("hello"), sha512_of("hello")
  local ran = run({ "--sha256", s256, url .. "#sha512=" .. s512 }, { reply("200 OK", "", "hello") })
  assert(ran.code == 0 and ran.out == "hello", ran.err)
  local wrong512 = run({ "--sha256", s256, url .. "#sha512=" .. string.rep("0", 128) },
    { reply("200 OK", "", "hello") })
  assert(wrong512.code == 1 and wrong512.out == "" and wrong512.err:find("sha512 mismatch", 1, true), wrong512.err)
  local wrong256 = run({ "--sha512", s512, url .. "#sha256=" .. string.rep("0", 64) },
    { reply("200 OK", "", "hello") })
  assert(wrong256.code == 1 and wrong256.err:find("sha256 mismatch", 1, true), wrong256.err)
  local path = tmp .. "/both.txt"
  local filed = run({ url .. "#sha256=" .. s256, "--sha512", string.rep("0", 128), "-o", path },
    { reply("200 OK", "", "hello") })
  assert(filed.code == 1, filed.err)
  assert(Fs.stat(path) == nil, "the target was created")
  for _, name in ipairs((assert(Fs.list(tmp)))) do
    assert(not name:find("both.txt", 1, true), "left behind: " .. name)
  end
end

local function test_bad_hex_in_a_recognized_fragment_is_a_usage_error()
  for _, fragment in ipairs({ "sha256=abc", "sha256=" .. string.rep("g", 64), "sha256=",
      "sha512=" .. string.rep("a", 64), "sha256sum=" .. string.rep("a", 65) } as {string}) do
    local ran = run({ url .. "#" .. fragment }, {})
    assert(ran.code == 2 and ran.out == "", fragment .. ": " .. tostring(ran.code) .. ran.err)
    assert(ran.err:find("hex digits", 1, true), ran.err)
  end
  local flag = run({ "--sha512", string.rep("a", 64), url }, {})
  assert(flag.code == 2, flag.err)
end

local function test_an_unrecognized_fragment_is_dropped()
  for _, fragment in ipairs({ "", "section", "a=b", "sha1=abc", "&&", "sha256", "SHA256=zz",
      "egg=x&sha256x=1", "x#y" } as {string}) do
    local ran = run({ url .. "#" .. fragment }, { reply("200 OK", "", "hello") })
    assert(ran.code == 0 and ran.out == "hello", fragment .. ": " .. ran.err)
  end
  local mixed = run({ url .. "#egg=x&sha256=" .. Hash.hex_sha256("hello") }, { reply("200 OK", "", "hello") })
  assert(mixed.code == 0, mixed.err)
  local head = run({ "--head", url .. "#sha256=" .. Hash.hex_sha256("x") }, { reply("200 OK", "") })
  assert(head.code == 2, head.err)
end
