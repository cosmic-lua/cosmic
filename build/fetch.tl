--- `cosmic fetch`: one GET, a small curl over `cosmic.http`, for the
--- ten-second question ("what does this URL send?") and for a download
--- checked against a digest. With no `-o` the body goes to standard
--- output, so `cosmic fetch <url> | cosmic json '.items'` reads it; with
--- `-o` it goes to a file that is renamed into place only once the
--- whole body is in and matches `--sha256`.
---
--- Like `cosmic json` it ends in no verdict line -- its standard output
--- is the body -- and its exit status is the verdict: 0 the body was
--- delivered, 1 the fetch failed (no connection, a status outside 2xx,
--- a digest that does not match, a body that broke off), 2 a command
--- line, a URL or a write it cannot use. build/dispatch.tl's `bare`
--- names it.
---
--- Three decisions, each a plain comment and not a TODO, since each
--- stays:
---
--- * GET only. It fetches; it does not post, put or send headers. A
---   caller that needs more writes the script with `cosmic.http`.
--- * A status outside 2xx fails by default, as `curl -f` does, and there
---   is no flag to turn that off: an error page piped into `cosmic json`
---   or saved as a download is the trap this verb exists to avoid. To
---   read what an error says, `--head` prints the status and headers,
---   and then fails on a non-2xx as well.
--- * `--sha256` with no `-o` buffers the whole body in memory and writes
---   it only once the digest matches, rather than refusing the pair:
---   bytes already on a pipe cannot be taken back, and
---   `cosmic fetch --sha256 <hex> <url> | cosmic json` is the useful
---   line. The cost is the body's size in memory; `-o` streams.
---
--- Redirects are followed as `cosmic.http` follows them: up to 10 hops
--- (`Http.Options.max_redirects`), a longer chain failing the fetch.
--- Certificates are always verified; there is no option that turns that
--- off, and none will be added.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Stream = require("cosmic.stream")

--- The `cosmic fetch` verb: `run` is what `build/dispatch.tl` calls.
local record verb
  --- Where `run` writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given: the caller adds newlines.
    --- False and why when the bytes did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- `Http.Options.script`, for a test: canned replies in place of a
    --- connection.
    script: {string}
  end
end

local spec = Cli.options.fetch

local usage = "cosmic fetch <url> [-o <file>] [--sha256 <hex>] [--head [--json]]"

--- Whether `url` names an http or https host, the only schemes there
--- are. `Http.open` would refuse others too, but as a failed fetch and
--- not a usage error.
local function is_url(url: string): boolean
  local host = url:match("^https?://([^/?#]*)") or url:match("^HTTPS?://([^/?#]*)")
  return host ~= nil and host ~= ""
end

local standard: verb.Io = {
  out = function(text: string): boolean, string
    return Fs.put(Fs.stdout, text)
  end,
  err = function(line: string)
    local _, _ = Fs.put(Fs.stderr, line .. "\n")
  end,
}

--- Closes a response, which always succeeds.
local function done(response: Http.Response)
  local _, _ = response:close()
end

--- `cosmic fetch <url> [options]`: returns the exit code.
--- @param argv the command line, `fetch` at slot 1
--- @param io where the body and complaints go; the process's own when nil
function verb.run(argv: {integer:string}, io?: verb.Io): integer
  local to = io or standard
  local function complain(line: string)
    to.err("cosmic: fetch: " .. line)
  end
  local function refuse(why: string): integer
    complain(why .. "; " .. usage)
    return 2
  end
  local flags, trouble = Flags.parse(argv, 2, spec)
  if flags == nil then return refuse(trouble) end
  local parsed: Flags.Parsed = flags
  if #parsed.words ~= 1 then
    return refuse("give one URL, not " .. #parsed.words .. " words")
  end
  local url = parsed.words[1]
  if not is_url(url) then
    return refuse(url .. " is not an http:// or https:// URL")
  end
  local target = parsed.values["-o"]
  if target ~= nil and target == "" then
    return refuse("an empty file name after -o")
  end
  local want = parsed.values["--sha256"]
  if want ~= nil then
    if #want ~= 64 or want:find("[^%x]") then
      return refuse("--sha256 wants 64 hex digits, not " .. want)
    end
    want = want:lower()
  end
  local head = parsed.set["--head"] or false
  local as_json = parsed.set["--json"] or false
  if as_json and not head then
    return refuse("--json shapes what --head prints")
  end
  if head and (target ~= nil or want ~= nil) then
    return refuse("--head prints no body, so there is nothing for -o or --sha256")
  end

  local options: Http.Options = { script = to.script }
  local function failed_status(status: integer): integer
    complain(url .. ": HTTP " .. status)
    return 1
  end
  local function written(ok: boolean, why: string): integer
    if ok then return 0 end
    complain("standard output: " .. why)
    return 2
  end

  if target ~= nil then
    options.sha256 = want
    local ok, why = Http.download(url, target, options)
    if not ok then
      complain(why)
      return 1
    end
    return 0
  end

  local response, open_trouble = Http.open(url, options)
  if response == nil then
    complain(url .. ": " .. open_trouble)
    return 1
  end
  local ok2 = response.status >= 200 and response.status < 300

  if head then
    local names: {string} = {}
    for name in pairs(response.headers) do names[#names + 1] = name end
    table.sort(names)
    local text: string
    if as_json then
      local encoded, encode_trouble = Json.encode({
        status = response.status, url = response.url, headers = response.headers,
      }, { pretty = true })
      if encoded == nil then
        complain(encode_trouble)
        done(response)
        return 1
      end
      text = encoded .. "\n"
    else
      -- The reason phrase is not kept, so the status line is `HTTP <code>`.
      local lines: {string} = { "HTTP " .. response.status }
      for _, name in ipairs(names) do
        -- A repeated Set-Cookie arrives joined with "\n": a line each.
        for value in (response.headers[name] .. "\n"):gmatch("(.-)\n") do
          lines[#lines + 1] = name .. ": " .. value
        end
      end
      text = table.concat(lines, "\n") .. "\n"
    end
    done(response)
    local code = written(to.out(text))
    if code == 0 and not ok2 then return failed_status(response.status) end
    return code
  end

  if not ok2 then
    done(response)
    return failed_status(response.status)
  end

  if want ~= nil then
    local body, read_trouble = Stream.read_all(response)
    done(response)
    if body == nil then
      complain(url .. ": " .. read_trouble)
      return 1
    end
    local got = Hash.hex_sha256(body)
    if got ~= want then
      complain(url .. ": sha256 mismatch: want " .. want .. ", got " .. got)
      return 1
    end
    return written(to.out(body))
  end

  while true do
    local chunk, read_trouble = response:read()
    if chunk == nil then
      done(response)
      if read_trouble ~= "" then
        complain(url .. ": " .. read_trouble)
        return 1
      end
      return 0
    end
    local sent, why = to.out(chunk)
    if not sent then
      done(response)
      return written(false, why)
    end
  end
end

return verb
