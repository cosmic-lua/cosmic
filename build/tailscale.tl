--- `cosmic tailscale`: the machine's own Tailscale node from the command
--- line, through [`cosmic.tailscale`], with no `tailscale` binary: what
--- a program would ask the daemon, asked by hand.
---
--- `cosmic tailscale status` prints this node and each peer, one line
--- each: its first address, its MagicDNS name, its owner (its tags, for
--- a tagged node), its OS and how traffic reaches it. A node that is not
--- running says its state first, and exits 1, as `tailscale status` does.
---
--- `cosmic tailscale whois <address>` prints the node an address of the
--- tailnet belongs to, the user it acts for and the capabilities the
--- tailnet policy's grants give it on this node, one line each. An
--- address no node has exits 1. `whois` and `ping` take a node's name
--- too (its MagicDNS name, the name's first label or its host name),
--- which `status` turns into the node's first address.
---
--- `cosmic tailscale cert [domain]` gets the certificate of one of the
--- node's names ([`Status.cert_domains`], the first by default) and its
--- key, and writes them to `<domain>.crt` and `<domain>.key`, as the
--- `tailscale cert` command does, or to `--cert-file` and `--key-file`
--- (`-`: standard output, the key first where both go there). The key
--- file gets mode 0600. Each is written to `<file>.new` and renamed over
--- its name once both are written, so a failed write leaves the old
--- pair as it was. `--min-validity
--- <duration>` (`30d`, `12h`) has the daemon renew first a certificate
--- that expires sooner.
---
--- `cosmic tailscale ping <address>` prints the round trip to a peer over
--- the tailnet, and the path the reply took; `--kind` picks the ping
--- (`disco`, `ICMP`, `TSMP` or `peerapi`).
---
--- `cosmic tailscale file` sends and takes files with Taildrop. `file
--- targets` lists the nodes a file can go to; `file send <file|->
--- <target>` sends one, streamed, to a target named by its MagicDNS name,
--- the name's first label, its host name, an address or its stable id,
--- under the file's own name or `--name` (which standard input needs,
--- and which is read whole first: a send names its size before its bytes).
--- `file list` lists the files sent to this node that wait, with their
--- sizes; `file get <dir>` writes each into the directory, through a
--- temporary file renamed into place, prints the path it wrote, and has
--- the daemon drop it (`--keep` leaves it waiting). A file whose name is
--- taken is skipped and waits on, exiting 1, unless `--conflict
--- overwrite` writes over it or `--conflict rename` writes `name (1).ext`.
--- `--wait` waits for a file when none waits yet.
---
--- `--json` prints the answer of `status`, `whois`, `ping`, `file
--- targets` or `file list` as JSON
--- object, the fields of [`cosmic.tailscale`]'s record. `--socket
--- <path>` names the daemon's socket, where it is not where
--- [`Tailscale.connect`] looks.
---
--- Like `cosmic json` it prints no summary. Exit 0 is ok, 1 a daemon that
--- could not be asked or refused, a node that is not running, or an
--- address or name no node has, 2 a command
--- line or a write it refuses. Complaints go to standard error as
--- `cosmic: tailscale: ...`. Its `spec` (build/verb_spec.tl) is `bare`.

local Cli = require("cosmic.cli")
local Clock = require("cosmic.clock")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Stream = require("cosmic.stream")
local Tailscale = require("cosmic.tailscale")
local Time = require("cosmic.time")
local bare = require("build.bare")
local plural = require("build.plural")
local verb_spec = require("build.verb_spec")

--- The `cosmic tailscale` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  mut spec: verb_spec.Spec
  --- A file `open` answers: its bytes as they are read, and how many.
  record Opened
    reader: Stream.Reader
    size: integer
  end
  --- Where `run` writes and which daemon it asks: what a test stands in
  --- for.
  record Io
    --- Writes to standard output, as given. False and why when the bytes
    --- did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- Writes a file whole with a mode: [`Fs.write`].
    write: function(path: string, data: string, mode: integer): boolean, string
    --- Renames a file over another: [`Fs.rename`].
    rename: function(from: string, to: string): boolean, string
    --- A file to read as it is sent, and its size: [`Stream.open`] and
    --- [`Fs.stat`]; a directory is refused.
    open: function(path: string): verb.Opened?, string
    --- The whole of standard input, or nil and why.
    stdin: function(): string?, string
    --- A file written through a temporary neighbour, renamed into place
    --- on `close`: [`Stream.create`].
    create: function(path: string): Stream.Writer?, string
    --- Whether a path is there: [`Fs.exists`].
    exists: function(path: string): boolean?, string
    --- Whether a path is a directory there.
    is_dir: function(path: string): boolean
    --- The client of the daemon: [`Tailscale.connect`].
    connect: function(opts: Tailscale.Daemon): Tailscale.Client?, string
  end
end

local spec = assert(assert(Cli.verbs["tailscale"]).spec)

local usage = "cosmic tailscale [--socket <path>] status [--json] | whois [--json] <address|name> | " ..
  "cert [--cert-file <file|->] [--key-file <file|->] [--min-validity <duration>] [domain] | " ..
  "ping [--kind disco|ICMP|TSMP|peerapi] [--json] <address|name> | " ..
  "file targets [--json] | file send [--name <name>] <file|-> <target> | file list [--json] | " ..
  "file get [--wait] [--conflict skip|overwrite|rename] [--keep] <dir>"

--- The options each subcommand takes, beside `--socket`, which all do.
local TAKES <const>: {string: {string: boolean}} = {
  status = { ["--json"] = true },
  whois = { ["--json"] = true },
  cert = { ["--cert-file"] = true, ["--key-file"] = true, ["--min-validity"] = true },
  ping = { ["--kind"] = true, ["--json"] = true },
  file = { ["--json"] = true, ["--name"] = true, ["--wait"] = true, ["--conflict"] = true, ["--keep"] = true },
}

--- The options each `file` action takes.
local FILE_TAKES <const>: {string: {string: boolean}} = {
  targets = { ["--json"] = true },
  send = { ["--name"] = true },
  list = { ["--json"] = true },
  get = { ["--wait"] = true, ["--conflict"] = true, ["--keep"] = true },
}

local KINDS <const>: {string: Tailscale.PingKind} = {
  disco = "disco", ICMP = "ICMP", TSMP = "TSMP", peerapi = "peerapi",
}

--- A day of 24 hours, in nanoseconds.
local DAY_NS <const> = 86400 * 1000000000

--- Mode 0600: a key file only its owner reads.
local OWNER_ONLY <const> = 0x180
--- Mode 0644: a certificate chain anyone reads.
local READABLE <const> = 0x1a4

local standard: verb.Io = {
  out = bare.out,
  err = bare.err,
  write = function(path: string, data: string, mode: integer): boolean, string
    return Fs.write(path, data, mode)
  end,
  rename = function(from: string, to: string): boolean, string return Fs.rename(from, to) end,
  open = function(path: string): verb.Opened?, string
    local st, why = Fs.stat(path)
    if st == nil then return nil, why end
    if st.kind ~= "file" then return nil, path .. ": not a file" end
    local reader, trouble = Stream.open(path)
    if reader == nil then return nil, trouble end
    return { reader = reader, size = st.size }, ""
  end,
  stdin = function(): string?, string
    return bare.stdin_text("send reads standard input, which is a terminal: name a file")
  end,
  create = function(path: string): Stream.Writer?, string return Stream.create(path) end,
  exists = function(path: string): boolean?, string return Fs.exists(path) end,
  is_dir = function(path: string): boolean
    local st, _ = Fs.stat(path)
    return st ~= nil and st.kind == "dir"
  end,
  connect = function(opts: Tailscale.Daemon): Tailscale.Client?, string
    return Tailscale.connect(opts)
  end,
}

--- `text` with a `-` for nothing, so a column is never blank.
local function shown(text: string): string
  return if text == "" then "-" else text end
end

--- Whether `word` is an IP address, alone or with a port, as the
--- LocalAPI takes one: digits and dots, or a colon in it.
local function numeric(word: string): boolean
  return word:match("^[%d.]+$") ~= nil or word:find(":", 1, true) ~= nil
end

--- The address `word` names: itself where it is an IP address, else the
--- first address of the peer (or this node) whose MagicDNS name, its
--- first label or its host name it is. Nil and why for no such node.
local function address_of(ts: Tailscale.Client, word: string): string?, string
  if numeric(word) then return word, "" end
  local status, why = ts:status()
  if status == nil then return nil, (why:gsub("^tailscale: ", "")) end
  local wanted = word:lower():gsub("%.$", "")
  local nodes: mut {Tailscale.Peer} = {}
  local me = status.self
  if me ~= nil then nodes[#nodes + 1] = me end
  for _, peer in ipairs(status.peers) do nodes[#nodes + 1] = peer end
  for _, node in ipairs(nodes) do
    local name = node.dns_name:lower()
    if name == wanted or name:match("^[^.]*") == wanted or node.host_name:lower() == wanted then
      local first = node.addresses[1]
      if first == nil then return nil, "the node " .. word .. " has no address" end
      return first, ""
    end
  end
  return nil, "no node of the tailnet is named " .. word
end

--- `value` as one line of JSON and a newline.
local function json_line(value: Json.Value): string
  return assert(Json.encode(value)) .. "\n"
end

--- `list` as a JSON array, an empty one too.
local function strings(list: {string}): {Json.Value}
  local out: mut {Json.Value} = {}
  for _, item in ipairs(list) do out[#out + 1] = item end
  return Json.array(out)
end

--- `list` as a JSON array, an empty one too.
local function values_of(list: {Json.Value}): {Json.Value}
  local out: mut {Json.Value} = {}
  for _, item in ipairs(list) do out[#out + 1] = item end
  return Json.array(out)
end

local function user_json(user: Tailscale.User): Json.Value
  local out: mut {string: Json.Value} = {
    id = user.id, login_name = user.login_name, display_name = user.display_name,
  }
  local picture = user.picture_url
  if picture ~= nil then out["picture_url"] = picture end
  return out
end

local function peer_json(peer: Tailscale.Peer): Json.Value
  local out: mut {string: Json.Value} = {
    id = peer.id, host_name = peer.host_name, dns_name = peer.dns_name, os = peer.os, user_id = peer.user_id,
    addresses = strings(peer.addresses), tags = strings(peer.tags), online = peer.online, active = peer.active,
    exit_node = peer.exit_node, exit_node_option = peer.exit_node_option, relay = peer.relay, direct = peer.direct,
  }
  local seen, expiry = peer.last_seen, peer.key_expiry
  if seen ~= nil then out["last_seen"] = seen end
  if expiry ~= nil then out["key_expiry"] = expiry end
  return out
end

--- `lines`, each a list of columns, as text whose columns line up: two
--- spaces between, the last column unpadded.
local function aligned(lines: {{string}}): string
  local widths: mut {integer: integer} = {}
  for _, columns in ipairs(lines) do
    for i, column in ipairs(columns) do
      if i < #columns and #column > (widths[i] or 0) then widths[i] = #column end
    end
  end
  local out: mut {string} = {}
  for _, columns in ipairs(lines) do
    local parts: mut {string} = {}
    for i, column in ipairs(columns) do
      parts[i] = if i < #columns then column .. string.rep(" ", (widths[i] or 0) - #column) else column end
    end
    out[#out + 1] = table.concat(parts, "  ") .. "\n"
  end
  return table.concat(out)
end

--- How traffic reaches `peer`, as `tailscale status` says it: `-` for
--- an idle one that is online.
local function reached(peer: Tailscale.Peer): string
  if not peer.online then
    local seen = peer.last_seen
    return if seen ~= nil then "offline, last seen " .. seen else "offline" end
  end
  local how: mut {string} = {}
  if peer.active then
    if peer.direct ~= "" then
      how[#how + 1] = "active; direct " .. peer.direct
    elseif peer.relay ~= "" then
      how[#how + 1] = "active; relay " .. string.format("%q", peer.relay)
    else
      how[#how + 1] = "active"
    end
  end
  if peer.exit_node then
    how[#how + 1] = "exit node"
  elseif peer.exit_node_option then
    how[#how + 1] = "offers exit node"
  end
  if #how == 0 then return "-" end
  return table.concat(how, "; ")
end

--- The columns of `peer`'s line.
local function peer_line(status: Tailscale.Status, peer: Tailscale.Peer, state: string): {string}
  local user = status.users[peer.user_id]
  local owner = if #peer.tags > 0 then table.concat(peer.tags, ",")
    elseif user ~= nil then user.login_name
    else "user " .. tostring(peer.user_id) end
  return { peer.addresses[1] or "-", shown(peer.dns_name), owner, shown(peer.os), state }
end

--- `status` as JSON: its users keyed by id as text, since JSON's keys
--- are.
local function status_json(status: Tailscale.Status): Json.Value
  local users: mut {string: Json.Value} = {}
  for id, user in pairs(status.users) do users[tostring(id)] = user_json(user) end
  local peers: mut {Json.Value} = {}
  for _, peer in ipairs(status.peers) do
    local value = peer_json(peer)
    peers[#peers + 1] = value
  end
  local out: mut {string: Json.Value} = {
    version = status.version, backend_state = status.backend_state, addresses = strings(status.addresses),
    health = strings(status.health), tailnet = status.tailnet, magic_dns_suffix = status.magic_dns_suffix,
    magic_dns = status.magic_dns, cert_domains = strings(status.cert_domains), peers = Json.array(peers), users = users,
  }
  local auth, me = status.auth_url, status.self
  if auth ~= nil then out["auth_url"] = auth end
  if me ~= nil then out["self"] = peer_json(me) end
  return out
end

--- `cosmic tailscale status`.
local function show_status(to: verb.Io, complain: function(line: string), ts: Tailscale.Client,
                           parsed: Flags.Parsed): integer
  if #parsed.words > 0 then
    complain("status takes no words; " .. usage)
    return bare.refused
  end
  local status, why = ts:status()
  if status == nil then
    complain((why:gsub("^tailscale: ", "")))
    return bare.failed
  end
  -- A node that is not running exits 1, as `tailscale status` does, so a
  -- script can tell.
  local running = status.backend_state == "Running"
  if parsed.set["--json"] == true then
    local wrote = bare.written(complain, to.out(json_line(status_json(status))))
    return if wrote ~= bare.ok or running then wrote else bare.failed end
  end
  local text: mut {string} = {}
  local me = status.self
  if me == nil or not running then
    local auth = status.auth_url
    text[#text + 1] = status.backend_state .. (if auth ~= nil then ": log in at " .. auth else "" end) .. "\n"
  end
  local lines: mut {{string}} = {}
  if me ~= nil then lines[#lines + 1] = peer_line(status, me, "this node") end
  for _, peer in ipairs(status.peers) do
    lines[#lines + 1] = peer_line(status, peer, reached(peer))
  end
  text[#text + 1] = aligned(lines)
  for _, health in ipairs(status.health) do text[#text + 1] = "health: " .. health .. "\n" end
  local wrote = bare.written(complain, to.out(table.concat(text)))
  return if wrote ~= bare.ok or running then wrote else bare.failed end
end

--- `cosmic tailscale whois <address>`.
local function show_whois(to: verb.Io, complain: function(line: string), ts: Tailscale.Client,
                          parsed: Flags.Parsed): integer
  if #parsed.words ~= 1 then
    complain(("whois takes one address, not %d; %s"):format(#parsed.words, usage))
    return bare.refused
  end
  local address, unknown = address_of(ts, assert(parsed.words[1]))
  if address == nil then
    complain(unknown)
    return bare.failed
  end
  local result = ts:whois_result(address)
  local who = result.whois
  if who == nil then
    complain((result.reason:gsub("^tailscale: ", "")))
    return bare.failed
  end
  if parsed.set["--json"] == true then
    local caps: mut {string: Json.Value} = {}
    for name, values in pairs(who.caps) do caps[name] = values_of(values) end
    local node: {string: Json.Value} = {
      id = who.node.id, stable_id = who.node.stable_id, name = who.node.name, host_name = who.node.host_name,
      os = who.node.os, user_id = who.node.user_id, addresses = strings(who.node.addresses),
      tags = strings(who.node.tags),
    }
    local value: {string: Json.Value} = { node = node, user = user_json(who.user), tagged = who.tagged, caps = caps }
    return bare.written(complain, to.out(json_line(value)))
  end
  local lines: mut {{string}} = {
    { "node", who.node.name .. " (" .. who.node.stable_id .. ")" },
    { "addresses", shown(table.concat(who.node.addresses, " ")) },
  }
  if who.tagged then
    lines[#lines + 1] = { "tags", table.concat(who.node.tags, " ") }
  else
    lines[#lines + 1] = { "user", who.user.login_name .. " (" .. who.user.display_name .. ")" }
  end
  if who.node.os ~= "" then lines[#lines + 1] = { "os", who.node.os } end
  local names: mut {string} = {}
  for name in pairs(who.caps) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local values = assert(who.caps[name])
    lines[#lines + 1] = { "cap", name .. (if #values > 0 then " " .. json_line(values_of(values)):sub(1, -2) else "" end) }
  end
  return bare.written(complain, to.out(aligned(lines)))
end

--- `--min-validity`'s duration as nanoseconds: hours, minutes and
--- seconds, and days of 24 hours. Nil after a complaint.
local function validity(complain: function(line: string), text: string): integer?
  local d, why = Time.parse_duration(text)
  if d == nil then
    complain("--min-validity: " .. why .. "; " .. usage)
    return nil
  end
  if (d.years or 0) ~= 0 or (d.months or 0) ~= 0 then
    complain("--min-validity is days, hours, minutes and seconds, not years or months: " .. text)
    return nil
  end
  local days, rest = d.days or 0, d.ns or 0
  if days < 0 or rest < 0 then
    complain("--min-validity is not negative: " .. text)
    return nil
  end
  -- Past what nanoseconds hold, and no certificate lives so long.
  if days > (math.maxinteger - rest) // DAY_NS then
    complain("--min-validity is too long: " .. text)
    return nil
  end
  local ns = days * DAY_NS + rest
  if ns < 0 then
    complain("--min-validity is not negative: " .. text)
    return nil
  end
  return ns
end

--- A file `cert` writes: its path ("-": standard output), its bytes and
--- its mode.
local record Output
  path: string
  data: string
  mode: integer
end

--- `cosmic tailscale cert [domain]`.
local function write_cert(to: verb.Io, complain: function(line: string), ts: Tailscale.Client,
                          parsed: Flags.Parsed): integer
  if #parsed.words > 1 then
    complain(("cert takes at most one domain, not %d; %s"):format(#parsed.words, usage))
    return bare.refused
  end
  local min_validity: integer? = nil
  local validity_text = parsed.values["--min-validity"]
  if validity_text ~= nil then
    min_validity = validity(complain, validity_text)
    if min_validity == nil then return bare.refused end
  end
  local cert_file, key_file = parsed.values["--cert-file"], parsed.values["--key-file"]
  if cert_file == "" or key_file == "" then
    complain(bare.empty_file .. "; " .. usage)
    return bare.refused
  end
  if cert_file ~= nil and cert_file == key_file and cert_file ~= "-" then
    complain("--cert-file and --key-file name one file, which the key would write over")
    return bare.refused
  end
  local domain = parsed.words[1]
  if domain ~= nil then
    domain = domain:gsub("%.$", "")
    if domain == "" or domain:match("^[%w.-]+$") == nil then
      complain("no such domain " .. string.format("%q", parsed.words[1]) .. "; " .. usage)
      return bare.refused
    end
  else
    local status, why = ts:status()
    if status == nil then
      complain((why:gsub("^tailscale: ", "")))
      return bare.failed
    end
    domain = status.cert_domains[1]
    if domain == nil then
      local auth = status.auth_url
      if status.backend_state ~= "Running" then
        complain("the node is " .. status.backend_state .. (if auth ~= nil then ": log in at " .. auth else "" end) ..
            ", so it has no name to get a certificate for")
      else
        complain("the node has no name to get a certificate for: is HTTPS enabled for the tailnet?")
      end
      return bare.failed
    end
  end
  local name = assert(domain)
  local pair, why = ts:cert(name, { min_validity_ns = min_validity })
  if pair == nil then
    complain((why:gsub("^tailscale: ", "")))
    return bare.failed
  end
  -- Each file is written beside itself first and renamed over its name
  -- only once both are written, so a write that fails leaves a key and a
  -- certificate that were a pair as they were, never one new and one old.
  local files: {Output} = {
    { path = key_file or (name .. ".key"), data = pair.key, mode = OWNER_ONLY },
    { path = cert_file or (name .. ".crt"), data = pair.cert, mode = READABLE },
  }
  local staged: mut {string} = {}
  for _, file in ipairs(files) do
    local path = file.path
    if path ~= "-" then
      local ok, trouble = to.write(path .. ".new", file.data, file.mode)
      if not ok then
        complain(trouble .. "; nothing was written over")
        return bare.refused
      end
      staged[#staged + 1] = path
    end
  end
  for _, path in ipairs(staged) do
    local ok, trouble = to.rename(path .. ".new", path)
    if not ok then
      complain(trouble)
      return bare.refused
    end
  end
  -- The key first, then the chain, where both go to standard output.
  for _, file in ipairs(files) do
    if file.path == "-" and not bare.delivered(complain, to.out(file.data)) then
      return bare.refused
    end
  end
  return bare.ok
end

--- `cosmic tailscale ping <address>`.
local function show_ping(to: verb.Io, complain: function(line: string), ts: Tailscale.Client,
                         parsed: Flags.Parsed): integer
  if #parsed.words ~= 1 then
    complain(("ping takes one address, not %d; %s"):format(#parsed.words, usage))
    return bare.refused
  end
  local kind_word = parsed.values["--kind"] or "disco"
  local kind = KINDS[kind_word]
  if kind == nil then
    complain("--kind is disco, ICMP, TSMP or peerapi, not " .. kind_word)
    return bare.refused
  end
  local address, unknown = address_of(ts, assert(parsed.words[1]))
  if address == nil then
    complain(unknown)
    return bare.failed
  end
  local ping, why = ts:ping(address, kind)
  if ping == nil then
    complain((why:gsub("^tailscale: ", "")))
    return bare.failed
  end
  if parsed.set["--json"] == true then
    local value: mut {string: Json.Value} = { latency_ns = ping.latency_ns }
    local endpoint, region, relay = ping.endpoint, ping.derp_region, ping.peer_relay
    if endpoint ~= nil then value["endpoint"] = endpoint end
    if region ~= nil then value["derp_region"] = region end
    if relay ~= nil then value["peer_relay"] = relay end
    return bare.written(complain, to.out(json_line(value)))
  end
  local via = if ping.endpoint ~= nil then "direct " .. assert(ping.endpoint)
    elseif ping.peer_relay ~= nil then "peer relay " .. assert(ping.peer_relay)
    elseif ping.derp_region ~= nil then "DERP " .. assert(ping.derp_region)
    else "the tailnet" end
  local ms = string.format("%.1fms", ping.latency_ns / 1e6)
  return bare.written(complain, to.out("pong from " .. address .. " via " .. via .. " in " .. ms .. "\n"))
end

--- The file target `word` names: its node's stable id, MagicDNS name,
--- the name's first label, its host name or one of its addresses. Nil and
--- why for none, or for a name two targets share.
local function target_of(targets: {Tailscale.FileTarget}, word: string): Tailscale.FileTarget?, string
  local wanted = word:lower():gsub("%.$", "")
  local found: mut {Tailscale.FileTarget} = {}
  for _, target in ipairs(targets) do
    local node = target.node
    local name = node.name:lower()
    local hit = node.stable_id == word or name == wanted or name:match("^[^.]*") == wanted or
      node.host_name:lower() == wanted
    for _, address in ipairs(node.addresses) do
      if address == word then hit = true end
    end
    if hit then found[#found + 1] = target end
  end
  if #found == 1 then return assert(found[1]), "" end
  if #found > 1 then
    return nil, word .. " names more than one target; name one by its stable id"
  end
  return nil, "no node takes files as " .. word .. " (`cosmic tailscale file targets` lists those that do)"
end

--- `file targets`.
local function file_targets(to: verb.Io, complain: function(line: string), ts: Tailscale.Client,
                            parsed: Flags.Parsed): integer
  if #parsed.words > 0 then
    complain("file targets takes no words; " .. usage)
    return bare.refused
  end
  local targets, why = ts:file_targets()
  if targets == nil then
    complain((why:gsub("^tailscale: ", "")))
    return bare.failed
  end
  if parsed.set["--json"] == true then
    local list: mut {Json.Value} = {}
    for _, target in ipairs(targets) do
      local node = target.node
      local value: {string: Json.Value} = {
        stable_id = node.stable_id, name = node.name, host_name = node.host_name, os = node.os,
        addresses = strings(node.addresses), peerapi_url = target.peerapi_url,
      }
      list[#list + 1] = value
    end
    return bare.written(complain, to.out(json_line(Json.array(list))))
  end
  local lines: mut {{string}} = {}
  for _, target in ipairs(targets) do
    local node = target.node
    lines[#lines + 1] = { shown(node.name), node.stable_id, node.addresses[1] or "-", shown(node.os) }
  end
  return bare.written(complain, to.out(aligned(lines)))
end

--- `file send <file|-> <target>`.
local function file_send(to: verb.Io, complain: function(line: string), ts: Tailscale.Client,
                         parsed: Flags.Parsed): integer
  if #parsed.words ~= 2 then
    complain("file send takes a file and a target, not " .. plural.count(#parsed.words, "word") .. "; " .. usage)
    return bare.refused
  end
  local path, word = assert(parsed.words[1]), assert(parsed.words[2])
  if path == "" then
    complain(bare.empty_file .. "; " .. usage)
    return bare.refused
  end
  local name = parsed.values["--name"] or (if path == "-" then nil else path:match("([^/]+)/*$") end)
  if name == nil then
    complain("a file sent from standard input needs --name; " .. usage)
    return bare.refused
  end
  if not Tailscale.file_name_ok(name) then
    complain("no file may go as " .. string.format("%q", name) ..
        ": a name is one path element, with no control byte or backslash, not ending in .partial or .deleted")
    return bare.refused
  end
  local body: Stream.Reader
  local size: integer
  if path == "-" then
    local text, why = to.stdin()
    if text == nil then
      complain(why)
      return bare.refused
    end
    body, size = Stream.from_string(text), #text
  else
    local opened, why = to.open(path)
    if opened == nil then
      complain(why)
      return bare.refused
    end
    body, size = opened.reader, opened.size
  end
  local targets, why = ts:file_targets()
  if targets == nil then
    local _, _ = body:close()
    complain((why:gsub("^tailscale: ", "")))
    return bare.failed
  end
  local target, unknown = target_of(targets, word)
  if target == nil then
    local _, _ = body:close()
    complain(unknown)
    return bare.failed
  end
  local sent, trouble = ts:send_file(target.node.stable_id, name, body, size)
  local _, _ = body:close()
  if not sent then
    complain((trouble:gsub("^tailscale: ", "")))
    return bare.failed
  end
  return bare.ok
end

--- `file list`.
local function file_list(to: verb.Io, complain: function(line: string), ts: Tailscale.Client,
                         parsed: Flags.Parsed): integer
  if #parsed.words > 0 then
    complain("file list takes no words; " .. usage)
    return bare.refused
  end
  local files, why = ts:waiting_files()
  if files == nil then
    complain((why:gsub("^tailscale: ", "")))
    return bare.failed
  end
  if parsed.set["--json"] == true then
    local list: mut {Json.Value} = {}
    for _, file in ipairs(files) do
      local value: {string: Json.Value} = { name = file.name, size = file.size }
      list[#list + 1] = value
    end
    return bare.written(complain, to.out(json_line(Json.array(list))))
  end
  local lines: mut {{string}} = {}
  for _, file in ipairs(files) do lines[#lines + 1] = { tostring(file.size), file.name } end
  return bare.written(complain, to.out(aligned(lines)))
end

--- How long `file get --wait` asks the daemon to hold each call.
local WAIT_NS <const> = 3600 * 1000000000

--- `name` with ` (n)` before its extension, for the nth file of that
--- name: `report (1).pdf`, as `tailscale file get --conflict=rename` names it.
local function numbered(name: string, n: integer): string
  local stem, extension = name:match("^(.+)(%.[^.]+)$")
  if stem == nil or extension == nil then return name .. " (" .. tostring(n) .. ")" end
  return stem .. " (" .. tostring(n) .. ")" .. extension
end

--- `file get <dir>`.
local function file_get(to: verb.Io, complain: function(line: string), ts: Tailscale.Client,
                        parsed: Flags.Parsed): integer
  if #parsed.words ~= 1 then
    complain(("file get takes one directory, not %d; %s"):format(#parsed.words, usage))
    return bare.refused
  end
  local dir = assert(parsed.words[1]):gsub("/+$", "")
  if dir == "" then dir = "/" end
  if not to.is_dir(dir) then
    complain(dir .. ": not a directory")
    return bare.refused
  end
  local conflict = parsed.values["--conflict"] or "skip"
  if conflict ~= "skip" and conflict ~= "overwrite" and conflict ~= "rename" then
    complain("--conflict is skip, overwrite or rename, not " .. conflict)
    return bare.refused
  end
  local files: {Tailscale.WaitingFile}
  while true do
    local asked = Clock.monotonic_ns()
    local got, why = ts:waiting_files({ wait_ns = if parsed.set["--wait"] == true then WAIT_NS else nil end })
    if got == nil then
      complain((why:gsub("^tailscale: ", "")))
      return bare.failed
    end
    files = got
    if #files > 0 or parsed.set["--wait"] ~= true then break end
    -- A daemon that answers at once, as one that holds no call does, is
    -- asked again a second later, not at once.
    if Clock.monotonic_ns() - asked < 1000000000 then
      local _, _ = Clock.sleep_ns(1000000000)
    end
  end
  local code = bare.ok
  local prefix = if dir == "/" then "" else dir end
  for _, file in ipairs(files) do
    local path = prefix .. "/" .. file.name
    local there, unknown = to.exists(path)
    local skip = false
    if there == nil then
      complain(unknown)
      code = bare.failed
      skip = true
    elseif there and conflict == "skip" then
      complain(path .. ": there already, so " .. file.name .. " waits on (--conflict overwrite or rename takes it)")
      code = bare.failed
      skip = true
    elseif there and conflict == "rename" then
      local n = 1
      while true do
        path = prefix .. "/" .. numbered(file.name, n)
        local taken, _ = to.exists(path)
        if taken ~= true then break end
        n = n + 1
      end
    end
    if not skip then
      local reader, why = ts:open_file(file.name)
      local writer: Stream.Writer? = nil
      local trouble = why
      if reader ~= nil then writer, trouble = to.create(path) end
      local copied: integer? = nil
      if reader ~= nil and reader.size ~= file.size then
        trouble = "the daemon sends " .. plural.count(reader.size, "byte") .. ", not the " .. tostring(file.size) ..
          " it listed"
      elseif reader ~= nil and writer ~= nil then
        copied, trouble = Stream.copy(reader, writer)
        if copied ~= nil then
          local closed, lost = writer:close()
          if not closed then copied, trouble = nil, lost end
        else
          local _, _ = writer:abort()
        end
      end
      if reader ~= nil then local _, _ = reader:close() end
      if writer ~= nil and copied == nil then local _, _ = writer:abort() end
      if copied == nil then
        complain(file.name .. ": " .. (trouble:gsub("^tailscale: ", "")))
        code = bare.failed
      else
        if parsed.set["--keep"] ~= true then
          local deleted, lost = ts:delete_file(file.name)
          if not deleted then
            complain(file.name .. ": written to " .. path .. ", but " .. (lost:gsub("^tailscale: ", "")))
            code = bare.failed
          end
        end
        if not bare.delivered(complain, to.out(path .. "\n")) then return bare.refused end
      end
    end
  end
  return code
end

local FILE_ACTIONS <const>: {string: function(verb.Io, function(string), Tailscale.Client, Flags.Parsed): integer} = {
  targets = file_targets, send = file_send, list = file_list, get = file_get,
}

--- `cosmic tailscale file <targets|send|list|get> ...`: Taildrop.
local function file_action(to: verb.Io, complain: function(line: string), ts: Tailscale.Client,
                           parsed: Flags.Parsed): integer
  local action = table.remove(parsed.words, 1)
  local takes = if action == nil then nil else FILE_TAKES[action] end
  if action == nil or takes == nil then
    complain((if action == nil then "name file targets, send, list or get" else "no file action " .. action end) ..
        "; " .. usage)
    return bare.refused
  end
  for _, name in ipairs(parsed.given) do
    if name ~= "--socket" and takes[name] ~= true then
      complain(name .. " is not an option of file " .. action .. "; " .. usage)
      return bare.refused
    end
  end
  return assert(FILE_ACTIONS[action])(to, complain, ts, parsed)
end

local SUBCOMMANDS <const>: {string: function(verb.Io, function(string), Tailscale.Client, Flags.Parsed): integer} = {
  status = show_status, whois = show_whois, cert = write_cert, ping = show_ping, file = file_action,
}

--- `cosmic tailscale <status|whois|cert|ping> ...`: asks the daemon and
--- returns the exit code: 0 ok, 1 a daemon that failed or refused, or
--- an address no node has, 2 a command line or a write it refuses.
--- @param argv the command line, `tailscale` at slot 1
--- @param io where output goes and which daemon is asked; the process's own when nil
function verb.run(argv: {string}, io?: verb.Io): integer
  local to = io or standard
  local complain = bare.complainer("tailscale", to.err)
  local got, trouble = Flags.parse(argv, 2, spec)
  if got == nil then
    complain(trouble .. "; " .. usage)
    return bare.refused
  end
  local parsed: Flags.Parsed = got
  local sub = table.remove(parsed.words, 1)
  local takes = if sub == nil then nil else TAKES[sub] end
  if sub == nil or takes == nil then
    complain((if sub == nil then "name status, whois, cert, ping or file" else "no subcommand " .. sub end) .. "; " .. usage)
    return bare.refused
  end
  for _, name in ipairs(parsed.given) do
    if name ~= "--socket" and takes[name] ~= true then
      complain(name .. " is not an option of " .. sub .. "; " .. usage)
      return bare.refused
    end
  end
  local socket = parsed.values["--socket"]
  if socket == "" then
    complain(bare.empty_file .. "; " .. usage)
    return bare.refused
  end
  local ts, why = to.connect({ socket = socket })
  if ts == nil then
    complain((why:gsub("^tailscale: ", "")))
    return bare.failed
  end
  return assert(SUBCOMMANDS[sub])(to, complain, ts, parsed)
end

--- The `tailscale` verb as [`build/verb_list.tl`] lists it. It reads no
--- tree, so it is never stale-checked.
verb.spec = {
  name = "tailscale",
  guide = "a node of your tailnet",
  tests = { "build.tailscale_test" },
  run = function(argv: {string}): integer return verb.run(argv) end,
  bare = true,
  takes = "status, whois, cert, ping or file, and its options",
  exits = "`tailscale` prints what the daemon answered, and nothing after; it exits 1 when the daemon could not be asked or refused, the node is not running, or no node has the address or name, 2 when it refuses its command line or a write.",
  passthrough = "its output is the daemon's answer, so its exit status is the verdict (build/tailscale_test.tl)",
}

return verb
