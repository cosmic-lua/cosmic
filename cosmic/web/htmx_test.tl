local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Html = require("cosmic.html")
local Htmx = require("cosmic.web.htmx")
local Json = require("cosmic.json")
local Test = require("cosmic.test")
local Web = require("cosmic.web")

Test.policy{ grants = {
  { path = "vendor/htmx/dist/htmx.min.js", letters = "r" },
  { path = "vendor/htmx-ext-sse/dist/sse.min.js", letters = "r" },
} }

--- Runs `fn` as the handler of a GET or POST to `/` with `headers`, and
--- answers what the client saw.
local function through(fn: function(Web.Request): Web.Response, headers?: {string:string},
                       method?: string): Web.TestResponse
  local app = Web.app{ routes = { Web.route({ "GET", "POST" }, "/", fn) } }
  local client = Web.test_client(app)
  if method == "POST" then return client:post("/", { headers = headers or {} }) end
  return client:get("/", { headers = headers or {} })
end

--- The response [`Htmx.apply`] writes `reply` to, or why it refused.
local function applied(reply: Htmx.Reply): Web.Response | nil, string
  return Htmx.apply(Web.empty(200), reply)
end

local function header(res: Web.Response, name: string): string | nil
  return Web.header(res, name)
end

local function test_request_reads_the_hx_headers()
  local seen: Htmx.Request | nil = nil
  through(function(req: Web.Request): Web.Response
    seen = Htmx.request(req)
    return Web.text("")
  end, { ["HX-Request"] = "true", ["HX-Target"] = "list", ["HX-Trigger"] = "btn",
    ["HX-Trigger-Name"] = "save", ["HX-Current-URL"] = "http://x.test/items", ["HX-Prompt"] = "yes" })
  local first = assert(seen, "the handler never ran")
  assert(first.active and not first.boosted and not first.history_restore)
  assert(first.target == "list" and first.trigger == "btn" and first.trigger_name == "save")
  assert(first.current_url == "http://x.test/items" and first.prompt == "yes")
  through(function(req: Web.Request): Web.Response
    seen = Htmx.request(req)
    return Web.text("")
  end)
  local second = assert(seen, "the handler never ran")
  assert(not second.active and second.target == nil and second.prompt == nil)
end

local function test_only_the_literal_true_sets_a_flag()
  local flags: {boolean} = {}
  through(function(req: Web.Request): Web.Response
    local seen = Htmx.request(req)
    flags = { seen.active, seen.boosted, seen.history_restore }
    return Web.text("")
  end, { ["HX-Request"] = "TRUE", ["HX-Boosted"] = "1", ["HX-History-Restore-Request"] = "yes" })
  assert(not flags[1] and not flags[2] and not flags[3])
end

local function test_a_fragment_is_wanted_only_by_a_plain_htmx_request()
  local function partial(headers: {string:string}): boolean
    local answer = false
    through(function(req: Web.Request): Web.Response
      answer = Htmx.partial(req)
      return Web.text("")
    end, headers)
    return answer
  end
  assert(partial({ ["HX-Request"] = "true" }))
  assert(not partial({}))
  assert(not partial({ ["HX-Request"] = "true", ["HX-Boosted"] = "true" }))
  assert(not partial({ ["HX-Request"] = "true", ["HX-History-Restore-Request"] = "true" }))
end

local function test_apply_writes_each_header()
  local res = assert(applied({
    redirect = "/items", push_url = "/items?page=2", replace_url = false, refresh = true,
    retarget = "#errors", reswap = "outerHTML swap:1s", reselect = "#main",
  }))
  assert(header(res, "HX-Redirect") == "/items" and header(res, "HX-Push-Url") == "/items?page=2")
  assert(header(res, "HX-Replace-Url") == "false" and header(res, "HX-Refresh") == "true")
  assert(header(res, "HX-Retarget") == "#errors" and header(res, "HX-Reswap") == "outerHTML swap:1s")
  assert(header(res, "HX-Reselect") == "#main")
  local pushed = assert(applied({ push_url = true }))
  assert(header(pushed, "HX-Push-Url") == "true")
  local located = assert(applied({ location = "/next" }))
  assert(header(located, "HX-Location") == "/next")
end

local function test_events_are_names_alone_or_ascii_json()
  local plain = assert(applied({ trigger = { { name = "showMessage" }, { name = "closeModal" } } }))
  assert(header(plain, "HX-Trigger") == "showMessage, closeModal")
  local res = assert(applied({
    trigger = { { name = "showMessage", detail = { level = "info", text = "caf\u{e9} \u{1F600}" } },
      { name = "closeModal" } },
    trigger_after_swap = { { name = "swapped" } },
    trigger_after_settle = { { name = "settled", detail = 7 } },
  }))
  local sent = assert(header(res, "HX-Trigger"))
  assert(not sent:find("[\128-\255]"), "the header must be ASCII")
  assert(sent:find("caf\\u00e9", 1, true) and sent:find("\\ud83d\\ude00", 1, true), sent)
  local decoded = assert(Json.decode(sent))
  assert(decoded is {string:any})
  local message = decoded.showMessage
  assert(message is {string:any} and message.level == "info" and message.text == "caf\u{e9} \u{1F600}")
  local closing = decoded.closeModal
  assert(closing is {string:any})
  assert(sent:find('"closeModal":{}', 1, true), sent)
  assert(header(res, "HX-Trigger-After-Swap") == "swapped")
  assert(header(res, "HX-Trigger-After-Settle") == '{"settled":7}')
end

local function test_a_location_object_is_ascii_json_with_a_checked_path()
  local res = assert(applied({ location = { path = "/items", target = "#list", swap = "innerHTML",
    values = { name = "\u{e9}" } } }))
  local decoded = assert(Json.decode(assert(header(res, "HX-Location"))))
  assert(decoded is {string:any} and decoded.path == "/items" and decoded.target == "#list")
  assert(not assert(header(res, "HX-Location")):find("[\128-\255]"))
  local values = decoded.values
  assert(values is {string:any} and values.name == "\u{e9}")
  local refused, why = applied({ location = { path = "//evil.example/x" } })
  assert(refused == nil and why:find("same-origin", 1, true), tostring(why))
  local bad, bad_why = applied({ location = { path = "/ok", target = "#a\n#b" } })
  assert(bad == nil and bad_why:find("location target", 1, true), tostring(bad_why))
end

local function test_a_redirect_must_stay_on_the_origin()
  for _, target in ipairs({ "//evil.example", "/\\evil.example", "https://evil.example/", "javascript:alert(1)",
      " /x", "", "data:text/html,x", "/a\r\nSet-Cookie: x=1" }) do
    for _, field in ipairs({ "redirect", "location", "push_url", "replace_url" }) do
      local reply: {string:any} = { [field] = target }
      local res, why = applied(reply as Htmx.Reply)
      assert(res == nil, field .. " accepted " .. target)
      assert(why:find("htmx: ", 1, true) == 1, why)
    end
  end
  local external = assert(applied({ redirect = Html.href("https://login.example/start?x=1") }))
  assert(header(external, "HX-Redirect") == "https://login.example/start?x=1")
  -- A SafeUrl was vouched for; Html.href already turned this one into a dead link.
  local dead = assert(applied({ redirect = Html.href("javascript:alert(1)") }))
  assert(header(dead, "HX-Redirect") == "about:invalid")
end

local function test_nothing_is_written_when_anything_is_refused()
  local res = Web.empty(200)
  local done, why = Htmx.apply(res, { redirect = "/fine", refresh = true, reswap = "sideways" })
  assert(done == nil and why:find("reswap", 1, true), tostring(why))
  assert(header(res, "HX-Redirect") == nil and header(res, "HX-Refresh") == nil)
end

local function test_selectors_swaps_and_events_are_checked()
  for _, reply in ipairs({
      { retarget = "" }, { retarget = "#a\nb" }, { reselect = "#a\0b" }, { reswap = "sideways" },
      { reswap = "innerHTMLx" }, { reswap = "" },
      { trigger = {} }, { trigger = { { name = "" } } }, { trigger = { { name = "a,b" } } },
      { trigger = { { name = "a\"b" } } }, { trigger = { { name = "a\nb" } } },
      { trigger = { { name = "{\"a\":1}" } } }, { trigger = { { name = "caf\u{e9}" } } },
      { trigger = { { name = "ok", detail = { fn = print } } } },
  } as {Htmx.Reply}) do
    local res, why = applied(reply)
    assert(res == nil and why:find("htmx: ", 1, true) == 1, tostring(why))
  end
  for _, style in ipairs({ "innerHTML", "outerHTML", "textContent", "beforebegin", "afterbegin", "beforeend",
      "afterend", "delete", "none", "innerHTML transition:true" }) do
    assert(applied({ reswap = style }) ~= nil, style)
  end
end

local function test_redirect_to_is_a_header_for_htmx_and_a_303_otherwise()
  local function redirect(headers: {string:string}, to: string | Html.SafeUrl): Web.TestResponse
    return through(function(req: Web.Request): Web.Response
      return (assert(Htmx.redirect_to(req, to)))
    end, headers, "POST")
  end
  local htmx = redirect({ ["HX-Request"] = "true" }, "/items")
  assert(htmx.status == 200 and htmx.body == "" and htmx.headers["hx-redirect"] == "/items")
  assert(htmx.redirect_location == nil)
  for _, headers in ipairs({ {}, { ["HX-Request"] = "true", ["HX-Boosted"] = "true" } } as {{string:string}}) do
    local plain = redirect(headers, "/items")
    assert(plain.status == 303 and plain.redirect_location == "/items" and plain.headers["hx-redirect"] == nil)
  end
  local external = redirect({}, Html.href("https://example.com/next"))
  assert(external.status == 303 and external.redirect_location == "https://example.com/next")
  through(function(req: Web.Request): Web.Response
    local refused, why = Htmx.redirect_to(req, "//evil.example")
    assert(refused == nil and why:find("same-origin", 1, true), tostring(why))
    local relative, relative_why = Htmx.redirect_to(req, "items")
    assert(relative == nil and relative_why:find("redirect", 1, true), tostring(relative_why))
    return Web.text("")
  end)
end

local function test_page_answers_a_fragment_or_the_whole_page_and_varies()
  local function handler(req: Web.Request): Web.Response
    return Htmx.page(req, Html.trust("<li>row</li>"), function(content: Html.SafeHtml): Html.SafeHtml
      return Html.concat({ Html.trust("<html><body><ul>"), content, Html.trust("</ul></body></html>") })
    end)
  end
  local fragment = through(handler, { ["HX-Request"] = "true" })
  assert(fragment.body == "<li>row</li>" and fragment.headers["content-type"] == "text/html; charset=utf-8")
  local whole = through(handler)
  assert(whole.body == "<html><body><ul><li>row</li></ul></body></html>")
  local boosted = through(handler, { ["HX-Request"] = "true", ["HX-Boosted"] = "true" })
  assert(boosted.body == whole.body)
  local restored = through(handler, { ["HX-Request"] = "true", ["HX-History-Restore-Request"] = "true" })
  assert(restored.body == whole.body)
  for _, res in ipairs({ fragment, whole, boosted, restored }) do
    assert(res.headers["vary"] == "HX-Request, HX-History-Restore-Request, HX-Boosted", res.headers["vary"])
    assert(res.headers["cache-control"] == "no-cache")
  end
end

local function test_stop_polling_is_a_286_the_server_accepts()
  local res = through(function(_req: Web.Request): Web.Response
    return Htmx.stop_polling(Html.trust("<b>done</b>"))
  end)
  assert(res.status == 286 and res.body == "<b>done</b>" and res.headers["content-type"] == "text/html; charset=utf-8")
  local empty = through(function(_req: Web.Request): Web.Response return Htmx.stop_polling() end)
  assert(empty.status == 286 and empty.body == "")
end

--- The `content` of the htmx-config meta tag in `markup`, entities decoded.
local function config_of(markup: string): {string:any}
  local content = assert(markup:match('<meta name="htmx%-config" content="([^"]*)">'))
  content = content:gsub("&#(%d+);", function(code: string): string
    return string.char(math.tointeger(tonumber(code)))
  end)
  content = content:gsub("&quot;", '"'):gsub("&amp;", "&")
  local config = assert(Json.decode(content))
  assert(config is {string:any})
  return config
end

local PLAN_CONFIG <const> = [[{ "allowEval": false, "allowScriptTags": false, "includeIndicatorStyles": false,
  "selfRequestsOnly": true,
  "responseHandling": [
    {"code": "204", "swap": false},
    {"code": "[23]..", "swap": true},
    {"code": "422", "swap": true, "error": true},
    {"code": "[45]..", "swap": false, "error": true},
    {"code": "...", "swap": false} ] }]]

local function test_head_writes_the_closed_configuration()
  local markup = Html.raw(Htmx.head())
  local want = assert(Json.decode(PLAN_CONFIG))
  local got_text = assert(Json.encode(config_of(markup)))
  local want_text = assert(Json.encode(want))
  assert(assert(Json.canonical(got_text)) == assert(Json.canonical(want_text)))
  assert(markup:find("^<meta name=\"htmx%-config\""), markup)
  assert(not markup:find("sse", 1, true))
end

local function test_head_writes_scripts_with_integrity_and_a_fixed_versioned_path()
  local markup = Html.raw(Htmx.head())
  local tag = '<script src="/_web/htmx-' .. Htmx.version .. '.min.js" integrity="' .. Htmx.integrity() ..
    '" crossorigin="anonymous" defer></script>'
  assert(markup:find(tag, 1, true), markup)
  assert(Htmx.path() == "/_web/htmx-" .. Htmx.version .. ".min.js")
  assert(Htmx.integrity():find("^sha384%-[%w+/]+=*$"))
  local both = Html.raw(Htmx.head({ sse = true }))
  assert(both:find(tag, 1, true))
  assert(both:find('src="' .. Htmx.path("sse") .. '" integrity="' .. Htmx.integrity("sse") .. '"', 1, true), both)
  assert(Htmx.path("sse") == "/_web/htmx-ext-sse-" .. Htmx.sse_version .. ".min.js")
end

local function test_head_takes_a_nonce_a_prefix_and_the_overrides_it_names()
  local markup = Html.raw(Htmx.head({ nonce = 'n"1', prefix = "/app", sse = true,
    config = { allow_eval = true, allow_script_tags = true, history_cache_size = 0 } }))
  local config = config_of(markup)
  assert(config.allowEval == true and config.allowScriptTags == true and config.historyCacheSize == 0)
  assert(config.inlineScriptNonce == 'n"1' and config.selfRequestsOnly == true)
  assert(config.includeIndicatorStyles == false)
  assert(not markup:find('n"1', 1, true), "the nonce is escaped")
  assert(select(2, markup:gsub(" nonce=", "")) == 2, markup)
  assert(markup:find('src="/app/_web/htmx-', 1, true) and markup:find('src="/app/_web/htmx-ext-sse-', 1, true), markup)
  for _, nonce in ipairs({ "a\nb", "a\0b", "a\rb", "a\127b" }) do
    local ok, err = pcall(Htmx.head, { nonce = nonce })
    assert(not ok and tostring(err):find("nonce", 1, true), nonce)
  end
  for _, prefix in ipairs({ '"><script>x</script>', "app", "//evil.example", "/a b", "/app/" }) do
    local ok, err = pcall(Htmx.head, { prefix = prefix })
    assert(not ok and tostring(err):find("prefix", 1, true), prefix)
  end
end

local function test_indicator_css_styles_the_classes_htmx_toggles()
  local css = Htmx.indicator_css()
  assert(css:find(".htmx-indicator{opacity:0", 1, true) and css:find(".htmx-request .htmx-indicator", 1, true))
  assert(css:find(".htmx-request.htmx-indicator", 1, true))
end

local function sri_of(data: string): string
  return "sha384-" .. Codec.base64(Hash.digest("sha384", data))
end

local function test_the_integrity_is_that_of_the_bytes_served_and_of_the_vendored_file()
  local client = Web.test_client(Web.app{})
  local js = client:get(Htmx.path())
  assert(js.status == 200 and sri_of(js.body) == Htmx.integrity(), "htmx.min.js")
  assert(js.body == assert(Fs.read("vendor/htmx/dist/htmx.min.js")))
  local sse = client:get(Htmx.path("sse"))
  assert(sse.status == 200 and sri_of(sse.body) == Htmx.integrity("sse"), "sse.min.js")
  assert(sse.body == assert(Fs.read("vendor/htmx-ext-sse/dist/sse.min.js")))
  assert(js.body:find('version:"' .. Htmx.version .. '"', 1, true))
end

local function test_the_assets_are_served_immutable_with_a_strong_etag_and_304()
  local client = Web.test_client(Web.app{})
  local res = client:get(Htmx.path())
  assert(res.headers["content-type"] == "text/javascript; charset=utf-8")
  assert(res.headers["cache-control"] == "public, max-age=31536000, immutable")
  assert(res.headers["cross-origin-resource-policy"] == "same-origin")
  assert(res.headers["x-content-type-options"] == "nosniff")
  local etag = assert(res.headers["etag"])
  assert(etag == '"' .. Hash.hex_sha256(res.body):sub(1, 32) .. '"', etag)
  for _, sent in ipairs({ etag, "W/" .. etag, '"other", ' .. etag, "*" }) do
    local again = client:get(Htmx.path(), { headers = { ["If-None-Match"] = sent } })
    assert(again.status == 304 and again.body == "", sent)
    assert(again.headers["etag"] == etag and again.headers["cache-control"] == res.headers["cache-control"])
  end
  local stale = client:get(Htmx.path(), { headers = { ["If-None-Match"] = '"0000"' } })
  assert(stale.status == 200 and stale.body == res.body)
  local head = client:head(Htmx.path())
  assert(head.status == 200 and head.body == "" and head.headers["etag"] == etag)
end

local function test_other_paths_and_methods_under_the_prefix_are_refused()
  local client = Web.test_client(Web.app{})
  assert(client:get("/_web/nothing.js").status == 404)
  assert(client:get("/_web").status == 404)
  assert(client:get("/_web/").status == 404)
  assert(client:get(Htmx.path() .. "/").status == 404)
  assert(client:get("/_web/a/b").status == 404)
  local post = client:post(Htmx.path(), {})
  assert(post.status == 405 and post.headers["allow"] == "GET, HEAD")
end

local function test_the_assets_have_ranges_and_gzip_from_the_static_files_handler()
  local client = Web.test_client(Web.app{})
  local whole = client:get(Htmx.path())
  local part = client:get(Htmx.path(), { headers = { ["Range"] = "bytes=0-9" } })
  assert(part.status == 206 and part.body == whole.body:sub(1, 10), part.status)
  assert(part.headers["content-range"] == "bytes 0-9/" .. #whole.body)
  assert(part.headers["cross-origin-resource-policy"] == "same-origin")
  local packed = client:get(Htmx.path(), { headers = { ["Accept-Encoding"] = "gzip" } })
  assert(packed.status == 200 and packed.headers["content-encoding"] == "gzip")
  assert(packed.headers["etag"] == whole.headers["etag"]:sub(1, -2) .. '-gzip"')
  assert(packed.headers["vary"] == "Accept-Encoding" and #packed.body < #whole.body)
  assert(packed.headers["cache-control"] == "public, max-age=31536000, immutable")
end

local function test_a_root_catch_all_does_not_shadow_the_assets_and_builtin_false_leaves_the_prefix_to_routes()
  local routes: {Web.Route} = { Web.get("/*rest", function(_req: Web.Request): Web.Response
    return Web.text("catch-all")
  end) }
  local on = Web.test_client(Web.app{ routes = routes })
  assert(on:get(Htmx.path()).headers["etag"] ~= nil and on:get("/anything").body == "catch-all")
  assert(on:get("/_web/nothing").status == 404)
  local off = Web.test_client(Web.app{ routes = routes, builtin = false })
  assert(off:get(Htmx.path()).body == "catch-all")
  -- The reservation is the built-in files': without them an app routes /_web/ itself.
  local own: {Web.Route} = { Web.get("/_web/mine", function(_req: Web.Request): Web.Response
    return Web.text("mine")
  end), Web.mount("/_web/sub", { Web.get("/x", function(_req: Web.Request): Web.Response
    return Web.text("sub")
  end) }) }
  local routed = Web.test_client(Web.app{ routes = own, builtin = false })
  assert(routed:get("/_web/mine").body == "mine" and routed:get("/_web/sub/x").body == "sub")
  local ok, err = pcall(Web.app, { routes = own })
  assert(not ok and tostring(err):find("reserved", 1, true), tostring(err))
end

local function test_the_assets_arrive_through_the_middleware_of_the_app()
  local seen: {string} = {}
  local app = Web.app{ middleware = { function(inner: Web.Handler): Web.Handler
    return function(req: Web.Request): Web.Response
      seen[#seen + 1] = req.path
      return inner(req)
    end
  end } }
  assert(Web.test_client(app):get(Htmx.path()).status == 200)
  assert(seen[1] == Htmx.path())
end
