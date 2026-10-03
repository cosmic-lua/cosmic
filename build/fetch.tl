--- `cosmic fetch`: one GET, a small curl over [`cosmic.http`], for the
--- ten-second question ("what does this URL send?") and for a download
--- checked against a digest. With no `-o` the body goes to standard
--- output, so `cosmic fetch <url> | cosmic json '.items'` reads it; with
--- `-o` it goes to a file that is renamed into place only once the
--- whole body is in and matches every digest asked for. The digests are
--- computed while the file is written, and a mismatch leaves no target
--- and no `.part`.
---
--- A digest comes from `--sha256` or `--sha512`, or from the URL's
--- fragment: `<url>#sha256=<hex>` (`#sha256sum=`, `#sha512=` and
--- `#sha512sum=` too, several joined by `&`), the form pip reads, so one
--- string names what to fetch and what it must be. The fragment is taken
--- off before anything is sent and never printed. One that names none of
--- these is dropped, unless a parameter reads as a checksum this verb
--- does not check (`sha1=`, `SHA256=`, `sha-256=`, `sha256:`, `md5=`),
--- which is exit 2: a body left unverified by a typo is the failure this
--- exists to stop. A digest that is not hex of the right length is exit 2
--- before any request. A flag and a fragment for the same algorithm must
--- agree, or that is exit 2 too. For different algorithms both are
--- checked, and every one must match; a mismatch names the algorithm, the
--- digest wanted and the one got.
---
--- Like `cosmic json` it ends in no verdict line -- its standard output
--- is the body -- and its exit status is the verdict: 0 the body was
--- delivered, 1 the fetch failed (no connection, a status outside 2xx,
--- a digest that does not match, a body that broke off, an `-o` write
--- that failed), 2 a command line, a URL or a write it cannot use. Only
--- a failed write to standard output is 2; a failed write of the `-o`
--- file is 1, a failed fetch like the rest. Its `spec`
--- (build/verb_spec.tl) is `bare`.
---
--- Three decisions, each a plain comment and not a TODO, since each
--- stays:
---
--- * GET only. It fetches; it does not post, put or send headers. A
---   caller that needs more writes the script with [`cosmic.http`].
--- * A status outside 2xx fails by default, as `curl -f` does, and there
---   is no flag to turn that off: an error page piped into `cosmic json`
---   or saved as a download is the trap this verb exists to avoid. To
---   read what an error says, `--head` prints the status and headers,
---   and then fails on a non-2xx as well.
--- * A digest with no `-o` buffers the whole body in memory, with no
---   cap, and writes it only once the digest matches, rather than
---   refusing the pair: bytes already on a pipe cannot be taken back, and
---   `cosmic fetch --sha256 <hex> <url> | cosmic json` is the useful
---   line. The cost is the body's size in memory; `-o` streams.
---
--- Redirects are followed as [`cosmic.http`] follows them: up to 10 hops
--- ([`Http.Options.max_redirects`]), a longer chain failing the fetch. A
--- fetch that starts at an https URL refuses a redirect to http by
--- default (exit 1, saying so), and `--allow-downgrade` follows it. That
--- is the safe default, like the verb's others (a failing status, every
--- certificate verified): a plaintext hop hands the request, and any
--- body, to whoever is on the path, who can also swap the body, and
--- nobody chose it who typed https. It differs from curl's default, which
--- follows the downgrade, on purpose; for a mirror that still bounces to
--- http, `--allow-downgrade` with a digest names what the script accepts.
--- An http start URL may redirect to either.
---
--- A body that breaks off after some bytes went to standard output
--- leaves those bytes sent (exit 1), since a pipe cannot take them back.
---
--- An interrupt (SIGINT or SIGTERM) during an `-o` download removes the
--- temporary file, never creates the target, and exits by that signal:
--- the verb holds a [`Child.guard`] for the download, [`Http.download`]
--- asks it between chunks and a wait for data ends when it catches one,
--- and closing the guard delivers the signal again. A kill nothing can
--- catch (SIGKILL) or that the verb does not hold (SIGHUP) leaves the
--- `.part` file beside the target: a plain limit of the platform, not a
--- gap.
---
--- Certificates are always verified; there is no option that turns that
--- off, and none will be added.

local bare = require("build.bare")
local Child = require("cosmic.child")
local Cli = require("cosmic.cli")
local Codec = require("cosmic.codec")
local Flags = require("cosmic.flags")
local plural = require("build.plural")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Stream = require("cosmic.stream")
local verb_spec = require("build.verb_spec")
local String = require("cosmic.string")

--- The `cosmic fetch` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- Where `run` writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given: the caller adds newlines.
    --- False and why when the bytes did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- [`Http.Options.script`], for a test: canned replies in place of a
    --- connection.
    script: {string}
    --- What `-o` asks between chunks, for a test: true ends the download
    --- as an interrupt does. The verb's own is its [`Child.guard`]'s.
    cancelled: function(): boolean
  end
  --- The schemes a redirect of `url` may lead to, for
  --- `Http.Options.redirect_protocols`: https only when `url` is https
  --- and `allow_downgrade` is not given, nil (both) otherwise.
  redirect_protocols: function(url: string, allow_downgrade: boolean): {string}
  --- What to print for `why`, an `Http` failure, when the fetch was
  --- limited to https redirects: a plain sentence where curl's is
  --- `Protocol "http" is disabled (in redirect)`; `why` as given
  --- otherwise, or when `protocols` is nil.
  refusal: function(why: string, protocols: {string}): string
end

local spec = Cli.verbs.fetch.spec

local usage = "cosmic fetch <url[#sha256=<hex>]> [-o <file>] [--sha256 <hex>] [--sha512 <hex>] " ..
  "[--allow-downgrade] [--head [--json]]"

--- The digests a fetch can be held to: the flag `--<name>`, the fragment
--- keys that name it in a URL (`#sha256=<hex>`, the form pip reads, and
--- `#sha256sum=<hex>`), and the hex digits it takes.
local record Algorithm
  name: string
  digits: integer
  keys: {string}
end
local algorithms: {Algorithm} = {
  { name = "sha256", digits = 64, keys = { "sha256", "sha256sum" } },
  { name = "sha512", digits = 128, keys = { "sha512", "sha512sum" } },
}

function verb.redirect_protocols(url: string, allow_downgrade: boolean): {string}
  if allow_downgrade or url:match("^(%a+)://"):lower() ~= "https" then return nil end
  return { "https" }
end

function verb.refusal(why: string, protocols: {string}): string
  if protocols ~= nil and why:find('Protocol "http" is disabled (in redirect)', 1, true) then
    return "refused a redirect from https to http (--allow-downgrade follows it)"
  end
  return why
end

--- Whether `key` is a fragment key that names one of `algorithms`.
local function recognized(key: string): boolean
  for _, algorithm in ipairs(algorithms) do
    for _, name in ipairs(algorithm.keys) do
      if key == name then return true end
    end
  end
  return false
end

--- Whether a fragment parameter reads as an attempt at a checksum: a name
--- (up to its `=` or `:`) that, ignoring case and any `-` or `_`, begins
--- like a hash's (`sha1`, `md5`) or is one of the words for a digest.
--- Dropping such a parameter as an ordinary fragment would fetch unverified
--- what the user believes is checked.
local function looks_like_a_checksum(parameter: string): boolean
  local name = (parameter:match("^[^=:]*"):lower():gsub("[-_ ]", ""))
  local patterns: {string} = { "^sha%d", "^sha$", "^md%d", "^blake", "^crc%d", "^ripemd", "^whirlpool",
    "^hash$", "^hash%d", "^checksum", "^digest$", "^integrity$" }
  for _, pattern in ipairs(patterns) do
    if name:find(pattern) then return true end
  end
  return false
end

--- `body`'s digest in hex, by the name of one of `algorithms`.
local function digest_of(name: string, body: string): string
  if name == "sha512" then return Codec.hex(Hash.digest("sha512", body)) end
  return Codec.hex(Hash.digest("sha256", body))
end

--- Whether `url` names an http or https host, the only schemes there
--- are. [`Http.open`] would refuse others too, but as a failed fetch and
--- not a usage error.
local function is_url(url: string): boolean
  local authority = url:match("^%a+://([^/?#]*)")
  if authority == nil then return false end
  local scheme = url:match("^(%a+)://"):lower()
  if scheme ~= "http" and scheme ~= "https" then return false end
  local host = authority:match("([^@]*)$")
  if host:sub(1, 1) == "[" then
    return host:match("^%[.+%]") ~= nil
  end
  return host:match("^[^:]*") ~= ""
end

--- `text` with every byte a terminal would act on -- below 0x20 but a
--- tab and a newline, and 0x7f -- written `\xNN`, so a hostile server's
--- header cannot inject an escape sequence or a line of its own. A
--- newline passes because it is harmless here: curl splits header lines
--- at it, and `--head` splits a joined Set-Cookie value at it and
--- prefixes each piece with the header name, so a newline never starts a
--- line the server chose.
local function escaped(text: string): string
  return bare.escape(text, { keep_tab_newline = true })
end

local standard: verb.Io = { out = bare.out, err = bare.err }

--- Closes a response, which always succeeds.
local function done(response: Http.Response)
  local _, _ = response:close()
end

--- `cosmic fetch <url> [options]`: returns the exit code.
--- @param argv the command line, `fetch` at slot 1
--- @param io where the body and complaints go; the process's own when nil
function verb.run(argv: {integer:string}, io?: verb.Io): integer
  local to = io or standard
  -- `shown` is the URL as it may be printed; a complaint that carries
  -- the URL as given in a transport diagnostic is rewritten to it.
  local shown = ""
  local given = ""
  local say = bare.complainer("fetch", to.err)
  local function complain(line: string)
    if given ~= "" and shown ~= given then
      line = line:gsub(given:gsub("%p", "%%%0"), (shown:gsub("%%", "%%%%")))
    end
    say(line)
  end
  local function refuse(why: string): integer
    complain(why .. "; " .. usage)
    return bare.refused
  end
  local flags, trouble = Flags.parse(argv, 2, spec)
  if flags == nil then return refuse(trouble) end
  local parsed: Flags.Parsed = flags
  if #parsed.words ~= 1 then
    return refuse("give one URL, not " .. plural.count(#parsed.words, "word"))
  end
  -- The fragment never reaches a request, a redirect or a message: it
  -- is taken off first, and only the digests it names are kept.
  local url, fragment = parsed.words[1]:match("^([^#]*)#(.*)$")
  if url == nil then url = parsed.words[1] end
  shown, given = bare.redact_url(url), url
  if not is_url(url) then
    return refuse(url .. " is not an http:// or https:// URL")
  end
  local target = parsed.values["-o"]
  if target ~= nil and target == "" then
    return refuse("an empty file name after -o")
  end
  -- What the body must hash to, by algorithm, and where each came from.
  local wants: {string:string} = {}
  local from: {string:string} = {}
  local function want_digest(algorithm: Algorithm, digest: string, source: string, sep: string): string
    local name = algorithm.name
    if #digest ~= algorithm.digits or digest:find("[^%x]") then
      return source .. " wants " .. plural.count(algorithm.digits, "hex digit") .. ", not " .. digest
    end
    digest = digest:lower()
    if wants[name] ~= nil and wants[name] ~= digest then
      return from[name] .. " and " .. source .. sep .. digest .. " name different " .. name .. " digests"
    end
    wants[name], from[name] = digest, source .. sep .. digest
    return nil
  end
  for _, algorithm in ipairs(algorithms) do
    local given_flag = parsed.values["--" .. algorithm.name]
    if given_flag ~= nil then
      local why = want_digest(algorithm, given_flag, "--" .. algorithm.name, " ")
      if why ~= nil then return refuse(why) end
    end
  end
  for parameter in (fragment or ""):gmatch("[^&]+") do
    local key, value = parameter:match("^([^=]+)=(.*)$")
    if looks_like_a_checksum(parameter) and not recognized(key) then
      return refuse("#" .. parameter:match("^[^=]*"):sub(1, 40) ..
          " looks like a checksum but is not one this verb checks (it reads #sha256=, " ..
          "#sha256sum=, #sha512= and #sha512sum=, in lowercase), and the body would go unverified")
    end
    for _, algorithm in ipairs(algorithms) do
      for _, name in ipairs(algorithm.keys) do
        if key == name then
          local why = want_digest(algorithm, value, "#" .. key, "=")
          if why ~= nil then return refuse(why) end
        end
      end
    end
  end
  local head = parsed.set["--head"] or false
  local as_json = parsed.set["--json"] or false
  if as_json and not head then
    return refuse("--json shapes what --head prints")
  end
  if head and (target ~= nil or next(wants) ~= nil) then
    return refuse("--head prints no body, so there is nothing for -o or a digest")
  end

  local options: Http.Options = { script = to.script }
  options.redirect_protocols = verb.redirect_protocols(url, parsed.set["--allow-downgrade"] or false)
  local function failed_status(status: integer): integer
    complain(shown .. ": HTTP " .. status)
    return bare.failed
  end
  local function written(ok: boolean, why: string): integer
    return bare.written(complain, ok, why)
  end

  if target ~= nil then
    options.sha256, options.sha512 = wants.sha256, wants.sha512
    local function download(interrupted: function(): boolean): integer
      options.cancelled = to.cancelled or interrupted
      local result = Http.download_result(url, target, options)
      if result.kind == "downloaded" then return bare.ok end
      if result.kind == "http_status" then return failed_status(assert(result.status)) end
      complain(verb.refusal(result.reason, options.redirect_protocols))
      return bare.failed
    end
    -- Held for the download and closed however it leaves, a raise of
    -- `complain` included: closing delivers a caught signal again, so the
    -- process still dies of it. A guard that cannot be had (no
    -- descriptor left for its pipe) leaves the download uninterruptible
    -- as it was.
    local held, _ = Child.guard()
    if held == nil then
      return download(function(): boolean return false end)
    end
    local guard <close> = held
    return download(function(): boolean return guard:cancelled() ~= 0 end)
  end

  local response, open_trouble = Http.open(url, options)
  if response == nil then
    complain(shown .. ": " .. verb.refusal(open_trouble, options.redirect_protocols))
    return bare.failed
  end
  local ok2 = response.status >= 200 and response.status < 300

  if head then
    local names: {string} = {}
    for name in pairs(response.headers) do names[#names + 1] = name end
    table.sort(names)
    local text: string
    if as_json then
      local encoded, encode_trouble = Json.encode({
        status = response.status, url = bare.redact_url(response.url), headers = response.headers,
      }, { pretty = true })
      if encoded == nil then
        complain(encode_trouble)
        done(response)
        return bare.failed
      end
      text = encoded .. "\n"
    else
      -- The reason phrase is not kept, so the status line is `HTTP <code>`.
      local lines: {string} = { "HTTP " .. response.status }
      for _, name in ipairs(names) do
        -- A repeated Set-Cookie arrives joined with "\n": a line each.
        for value in String.lines(response.headers[name]) do
          lines[#lines + 1] = escaped(name .. ": " .. value)
        end
      end
      text = table.concat(lines, "\n") .. "\n"
    end
    done(response)
    local code = written(to.out(text))
    if code == bare.ok and not ok2 then return failed_status(response.status) end
    return code
  end

  if not ok2 then
    done(response)
    return failed_status(response.status)
  end

  if next(wants) ~= nil then
    local body, read_trouble = Stream.read_all(response)
    done(response)
    if body == nil then
      complain(shown .. ": " .. read_trouble)
      return bare.failed
    end
    for _, algorithm in ipairs(algorithms) do
      local wanted = wants[algorithm.name]
      local got = wanted ~= nil and digest_of(algorithm.name, body)
      if wanted ~= nil and got ~= wanted then
        complain(shown .. ": " .. algorithm.name .. " mismatch: want " .. wanted .. ", got " .. got)
        return bare.failed
      end
    end
    return written(to.out(body))
  end

  while true do
    local chunk, read_trouble = response:read()
    if chunk == nil then
      done(response)
      if read_trouble ~= "" then
        complain(shown .. ": " .. read_trouble)
        return bare.failed
      end
      return bare.ok
    end
    local sent, why = to.out(chunk)
    if not sent then
      done(response)
      return written(false, why)
    end
  end
end

--- The `fetch` verb as [`build/verb_list.tl`] lists it. Reads a URL it is
--- given, never the tree: never stale-checked (`bare` in
--- build/verb_spec.tl).
verb.spec = {
  name = "fetch",
  guide = "questions about a data file",
  tests = { "build.fetch_test", "build.fetch_tool_test" },
  run = function(argv: {integer:string}): integer return verb.run(argv) end,
  bare = true,
  takes = "a URL",
  exits = "`fetch` prints the body and nothing after, and exits 0 when it was delivered, 1 when the fetch failed, 2 for a command line or URL it refused.",
  passthrough = "its output is the body for a pipe, so its exit status is the verdict (build/fetch_test.tl)",
}

return verb
