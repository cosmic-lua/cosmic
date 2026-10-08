--- The live host of cosmic_ci/github.tl: what it asks of the API, over
--- [`cosmic.http`]'s `script` (no network is reached), and of `git`, as a
--- recording of git's answers.
local Github = require("cosmic_ci.github")
local GithubApi = require("cosmic_ci.github_api")

--- A whole reply: a status line, `head`'s header lines, and `body`.
local function reply(status: string, head: string, body?: string): string
  body = body or ""
  return "HTTP/1.1 " .. status .. "\r\n" .. head ..
    "Content-Length: " .. tostring(#body) .. "\r\nConnection: close\r\n\r\n" .. body
end

--- The live host over a plain-HTTP API whose calls `script` answers in
--- order, and what each request wrote.
local function host_with(script: {{string}}): Github.Host, {string}
  local sent: {string} = {}
  local host = Github.live({ GH_TOKEN = "secret", GITHUB_API_URL = "http://api.test" },
    { script = script, sent = sent })
  return host, sent
end

local function has(text: string, needle: string)
  assert(text:find(needle, 1, true), "lacks " .. needle .. ":\n" .. text)
end

--- A lookup GETs the path with the token the environment holds and
--- answers the object it got.
local function test_a_lookup_gets_the_path_and_decodes_its_answer()
  local host, sent = host_with({ { reply("200 OK", "", '{"merge_base_commit":{"sha":"abc"}}') } })
  local pages, why = host.fetch("repos/o/r/compare/main...x", false, 30)
  assert(pages ~= nil, why)
  local page = pages[1] as {string: any}
  assert(#pages == 1 and (page.merge_base_commit as {string: string}).sha == "abc")
  assert(#sent == 1)
  has(sent[1], "GET /repos/o/r/compare/main...x HTTP/1.1\r\n")
  has(sent[1], "\r\nAuthorization: Bearer secret\r\n")
end

--- A listing answers every page, each fetched where the `Link` header of
--- the one before names it, however the header is written.
local function test_a_listing_follows_the_link_header_to_every_page()
  local host, sent = host_with({
    { reply("200 OK", 'Link: <http://api.test/repos/o/r/actions/caches?page=2>; rel="next", ' ..
        '<http://api.test/repos/o/r/actions/caches?page=3>; rel="last"\r\n', '{"actions_caches":[{"id":1}]}') },
    { reply("200 OK", 'link: <http://api.test/repos/o/r/actions/caches?page=3>; rel="prev"; x="y", ' ..
        '<http://api.test/repos/o/r/actions/caches?page=3>;rel=next\r\n', '{"actions_caches":[{"id":2}]}') },
    { reply("200 OK", 'Link: <http://api.test/repos/o/r/actions/caches?page=1>; rel="first"\r\n',
      '{"actions_caches":[{"id":3}]}') },
  })
  local pages, why = host.fetch("repos/o/r/actions/caches?per_page=1", true, 30)
  assert(pages ~= nil and #pages == 3, why)
  for i, page in ipairs(pages) do
    local caches = (page as {string: any}).actions_caches as {{string: integer}}
    assert(caches[1].id == i)
  end
  assert(#sent == 3)
  has(sent[1], "GET /repos/o/r/actions/caches?per_page=1 HTTP/1.1\r\n")
  has(sent[2], "GET /repos/o/r/actions/caches?page=2 HTTP/1.1\r\n")
  has(sent[3], "GET /repos/o/r/actions/caches?page=3 HTTP/1.1\r\n")
end

--- A listing whose next page is on another origin fails, and the token
--- goes nowhere but the API.
local function test_a_next_link_to_another_origin_fails_the_listing()
  local host, sent = host_with({
    { reply("200 OK", 'Link: <http://evil.test/steal>; rel="next"\r\n', "{}") },
    { reply("200 OK", "", "{}") },
  })
  local pages, why = host.fetch("repos/o/r/actions/caches", true, 30)
  assert(pages == nil and why:find("refusing to send the token to", 1, true) and
      why:find("page 2", 1, true), tostring(why))
  assert(#sent == 1, "the token was sent on")
end

--- A next link that names a page already fetched fails the listing at once.
local function test_a_next_link_that_repeats_a_page_fails_the_listing()
  local loop = 'Link: <http://api.test/repos/o/r/actions/caches?page=2>; rel="next"\r\n'
  local host, sent = host_with({ { reply("200 OK", loop, "{}") }, { reply("200 OK", loop, "{}") },
    { reply("200 OK", loop, "{}") } })
  local pages, why = host.fetch("repos/o/r/actions/caches", true, 30)
  assert(pages == nil and why:find("repeats", 1, true), tostring(why))
  assert(#sent == 2, "the loop was followed")
end

--- A lookup that the API refuses, answers no JSON, or never answers fails
--- naming the status, the request and why.
local function test_a_lookup_that_fails_answers_nil()
  local host = host_with({
    { reply("404 Not Found", "", '{"message":"Not Found"}') },
    { reply("200 OK", "", "not json") },
    { reply("500 Internal Server Error", "", "") },
    { reply("200 OK", "", "not json") },
  })
  local pages, why = host.fetch("x/missing", false, 30)
  assert(pages == nil and why == "GET x/missing: HTTP 404: Not Found", why)
  pages, why = host.fetch("x/junk", false, 30)
  assert(pages == nil and why:find("GET x/junk: ", 1, true) == 1, tostring(why))
  pages, why = host.fetch("x/broken", true, 30)
  assert(pages == nil and why == "GET x/broken: HTTP 500", tostring(why))
  pages, why = host.fetch("x/junk", true, 30)
  assert(pages == nil and why:find("GET x/junk: ", 1, true) == 1, tostring(why))
  local none, trouble = host_with({}).fetch("x/unanswered", false, 1)
  assert(none == nil and trouble:find("GET x/unanswered: ", 1, true) == 1, tostring(trouble))
end

--- Without a token no lookup is made, and each fails saying so.
local function test_a_host_with_no_token_fails_every_lookup()
  local bare = Github.live({})
  local pages, why = bare.fetch("repos/o/r", false, 1)
  assert(pages == nil and why:find("GH_TOKEN or GITHUB_TOKEN", 1, true), tostring(why))
  pages, why = bare.fetch("repos/o/r", true, 1)
  assert(pages == nil and why:find("GH_TOKEN or GITHUB_TOKEN", 1, true), tostring(why))
  local deleted: boolean
  deleted, why = bare.delete("repos/o/r/actions/caches/1", 1)
  assert(deleted == false and why:find("GH_TOKEN or GITHUB_TOKEN", 1, true), tostring(why))
end

--- A request is cut off after the seconds the lookup gives.
local function test_a_lookup_carries_its_time_limit()
  local limits: {integer | nil} = {}
  local fetch, delete = Github.over({ base = "http://api.test",
    now_ns = function(): integer return 0 end,
    fetch = function(): boolean, string return false, "" end,
    send = function(request: GithubApi.Request): GithubApi.Reply | nil, string
      limits[#limits + 1] = request.timeout_ns
      return { status = 200, headers = {}, body = "{}" }, ""
    end })
  assert(fetch("a", false, 7) and fetch("b", true, 8) and delete("c", 9))
  assert(limits[1] == 7000000000 and limits[2] == 8000000000 and limits[3] == 9000000000,
    tostring(limits[1]) .. " " .. tostring(limits[2]) .. " " .. tostring(limits[3]))
end

--- A delete is a DELETE of the path, and fails where the API refuses it.
local function test_a_delete_sends_delete()
  local host, sent = host_with({ { reply("204 No Content", "") },
    { reply("403 Forbidden", "", '{"message":"Must have admin rights"}') } })
  assert(host.delete("repos/o/r/actions/caches/7", 30))
  has(sent[1], "DELETE /repos/o/r/actions/caches/7 HTTP/1.1\r\n")
  has(sent[1], "\r\nAuthorization: Bearer secret\r\n")
  local deleted, why = host.delete("repos/o/r/actions/caches/8", 30)
  assert(deleted == false and why == "DELETE repos/o/r/actions/caches/8: HTTP 403: Must have admin rights", why)
end

--- The harness moved where git answers 1 to a diff of build/harness_epoch.tl,
--- by the path from the repository's root, which the driver, run in ci/,
--- needs. A base git does not hold, any other status, and no git at all are
--- no sign that it moved. (A recorded git stands in: no test runs the host's.)
local function test_the_harness_moved_is_gits_answer()
  local base = string.rep("a", 40)
  local function moved(known: integer | nil, diff: integer | nil): boolean, {string}
    local lines: {string} = {}
    local answer = Github.harness_moved(function(argv: {string}): integer | nil
      lines[#lines + 1] = table.concat(argv, " ")
      return argv[1] == "cat-file" and known or diff
    end, base)
    return answer, lines
  end
  local answer, lines = moved(0, 1)
  assert(answer and lines[1] == "cat-file -e " .. base .. "^{commit}" and
      lines[2] == "diff --quiet " .. base .. " HEAD -- :/build/harness_epoch.tl", table.concat(lines, "\n"))
  assert(not moved(0, 0), "an unchanged harness moved")
  assert(not moved(0, 2) and not moved(0, nil), "a refused diff moved the harness")
  answer, lines = moved(128, 1)
  assert(not answer and #lines == 1, "a base git lacks moved the harness")
  assert(not moved(nil, 1), "no git moved the harness")
end
