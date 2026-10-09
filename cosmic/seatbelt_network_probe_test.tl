--- A diagnostic for the macOS `connect` design (cosmic/sandbox/seatbelt.tl's
--- `relay_port` and `serves_relay`): what Seatbelt lets a child reach on the network, said
--- by starting children under hand-written profiles through the raw spawn's
--- `seatbelt`, as cosmic/child_seatbelt_test.tl does for its own. macOS's CI
--- workers run unsandboxed, so one run of that leg settles the facts the
--- design waits on: which forms of a `remote` rule the system's profile
--- compiler takes, whether a rule for one loopback port lets a child reach that
--- port and no other, over TCP, UDP and IPv6, whether it lets a child bind or
--- listen, whether a unix socket such as mDNSResponder's is reachable under
--- default-deny, and which rules a resolver needs.
---
--- This module is not a regression suite (cosmic/child_relay_seatbelt_test.tl
--- holds the design to what it found): it keeps the facts a profile's
--- network rules rest on checked on each macOS run. Each test says what
--- it saw in the message of its last assertion, and asserts what must hold of
--- the design. Every test calls [`Test.skip`] on any other host, where Landlock
--- and seccomp hold a child, so the whole module skips there.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Test = require("cosmic.test")
local Udp = require("build.udp_fixture")
local sys = require("cosmic.sys")
local type raw_process = require("cosmic.internal.process")

--- Nothing a profile here reads is the tree's: it is the host's, which the
--- children run from.
Test.policy{ env = { "TMPDIR" }, profiles = { "system" } }

--- Whether a test ends by failing with everything it saw, so that one run's
--- log shows it whether or not the assertions held.
local DUMP <const> = false

local type Searcher = function(string): any, any

--- The process table cosmic.child starts a child through.
local function process_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process -- cast: the table core/process.h declares
    end
  end
  error("cosmic.child has no process table")
end

--- Ends the test where Seatbelt does not hold a child.
local function macos_only()
  if assert(sys.uname()).sysname ~= "Darwin" then
    Test.skip("Seatbelt holds a child on macOS alone")
  end
end

--- What a test saw, one line each.
local function new_report(): {string}
  return {}
end

--- Fails with `report` when `DUMP` says so, after the assertions held.
local function conclude(report: {string})
  assert(not DUMP, "\n" .. table.concat(report, "\n"))
end

--- The profile a child that only reads the host and runs programs holds
--- to: file reads and runs of everything, and nothing of the network, Mach
--- services or writes.
local BASE <const>: {string} = {
  "(version 1)", "(deny default)",
  "(allow file-read*)", "(allow file-map-executable)", "(allow process-exec)",
  "(allow sysctl-read)", "(allow process-fork)",
  "(allow signal (target self))", "(allow process-info-pidinfo (target self))",
  "(allow file-write-data (literal \"/dev/null\"))",
}

--- `base` and then `more`, as the text of one profile.
local function profile(base: {string}, more: {string}): string
  local lines: {string} = {}
  for _, line in ipairs(base) do lines[#lines + 1] = line end
  for _, line in ipairs(more) do lines[#lines + 1] = line end
  return table.concat(lines, "\n") .. "\n"
end

--- A child started under a profile.
local record Running
  --- The child's pid, or nil where the start was refused.
  pid: integer
  --- Why the start was refused, when `pid` is nil.
  why: string
  --- The file the child's stdout and stderr go to.
  output: string
end

local counter = 0

--- Starts `argv` under `text` and its `parameters`, its output in a file of
--- `tmp`.
local function start(tmp: string, text: string, parameters: {string:string}, argv: {string}): Running
  counter = counter + 1
  local path = tmp .. "/out-" .. counter
  local out = assert(sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 420))
  local null = assert(sys.open("/dev/null", sys.O_RDONLY))
  local pid, why = process_table().spawn(argv[1], argv, nil, nil, null, out, out, false, nil,
    { seatbelt = { profile = text, parameters = parameters } })
  local _, _ = sys.close(out)
  local _, _ = sys.close(null)
  return { pid = pid, why = why, output = path }
end

--- How a child ended.
local record Ended
  started: boolean
  why: string
  code: integer
  signal: integer
  timed_out: boolean
  text: string
end

--- Waits `seconds` for `running`, ending it then, and says how it ended.
local function reap(running: Running, seconds: number): Ended
  if running.pid == nil then
    return { started = false, why = running.why or "", code = -1, signal = -1, timed_out = false, text = "" }
  end
  local process = process_table()
  local deadline = Clock.monotonic_ns() + Clock.seconds(seconds)
  local timed_out = false
  local status = assert(process.waitpid(running.pid, true))
  while status.pid == 0 do
    if Clock.monotonic_ns() >= deadline then
      local _, _ = sys.kill(running.pid, sys.SIGKILL)
      status = assert(process.waitpid(running.pid, false))
      timed_out = true
      break
    end
    local _, _ = Clock.sleep_ns(Clock.ms(20))
    status = assert(process.waitpid(running.pid, true))
  end
  return { started = true, why = "", code = status.code, signal = status.signal, timed_out = timed_out,
    text = Fs.read(running.output) or "" }
end

--- `argv` run to its end under a profile, for at most `seconds`.
local function run_under(tmp: string, text: string, parameters: {string:string}, argv: {string},
                         seconds?: number): Ended
  return reap(start(tmp, text, parameters, argv), seconds or 8)
end

--- A few words of what a child printed, on one line.
local function brief(text: string): string
  local one = text:gsub("%s+", " "):sub(1, 110)
  return string.format("%q", one)
end

--- How a connection attempt ended, from what the tool said.
local function verdict(ended: Ended): string
  if not ended.started then return "NOSTART(" .. brief(ended.why) .. ")" end
  if ended.timed_out then return "TIMEOUT" end
  if ended.text:find("not permitted", 1, true) then return "DENIED" end
  if ended.text:find("refused", 1, true) then return "REFUSED" end
  if ended.code == 0 then return "CONNECTED" end
  return "OTHER(" .. ended.code .. " " .. brief(ended.text) .. ")"
end

--- What a connect to `host`:`port` ends in under `text`, by two tools: nc
--- and bash's /dev/tcp.
local function tcp_reach(tmp: string, text: string, parameters: {string:string}, host: string,
                         port: integer): string, string
  local nc = run_under(tmp, text, parameters,
    { "/usr/bin/nc", "-n", "-z", "-v", "-w", "2", host, tostring(port) })
  local bash = run_under(tmp, text, parameters,
    { "/bin/bash", "-c", "exec 3<>/dev/tcp/$1/$2", "bash", host, tostring(port) })
  return verdict(nc), verdict(bash)
end

--- Whether either tool's `a` or `b` verdict is `word`.
local function any(a: string, b: string, word: string): boolean
  return a == word or b == word
end

--- A TCP listener on `host`:`port` (0 for any), or nil.
local function listener(host: string, port: integer): Net.Listener | nil, string
  return Net.listen(Net.tcp(host, port), { timeout_ns = Clock.seconds(5) })
end

--- The port a listener or a datagram socket holds.
local function port_of(address: Net.Address): integer
  return address.port
end

--- A rule that holds one port of the loopback, in each form the design might
--- use: the rule's lines and its parameters.
local record Form
  name: string
  lines: {string}
  parameters: {string:string}
  --- Whether the form names the port, so a test of it reaches only that one.
  scoped: boolean
end

local function forms(port: integer): {Form}
  local number = tostring(port)
  return {
    { name = "ip-localhost", scoped = true, parameters = {},
      lines = { "(allow network-outbound (remote ip \"localhost:" .. number .. "\"))" } },
    { name = "tcp-localhost", scoped = true, parameters = {},
      lines = { "(allow network-outbound (remote tcp \"localhost:" .. number .. "\"))" } },
    { name = "ip-127.0.0.1", scoped = true, parameters = {},
      lines = { "(allow network-outbound (remote ip \"127.0.0.1:" .. number .. "\"))" } },
    { name = "tcp-127.0.0.1", scoped = true, parameters = {},
      lines = { "(allow network-outbound (remote tcp \"127.0.0.1:" .. number .. "\"))" } },
    { name = "ip-param", scoped = true, parameters = { PORT = number },
      lines = { "(allow network-outbound (remote ip (string-append \"localhost:\" (param \"PORT\"))))" } },
    { name = "ip-numeric-remote", scoped = false, parameters = {},
      lines = { "(allow network-outbound (remote ip \"1.2.3.4:443\"))" } },
    { name = "ip-star", scoped = false, parameters = {},
      lines = { "(allow network-outbound (remote ip \"*:*\"))" } },
  }
end

--- Whether `/usr/bin/true` starts under `text`: the profile compiled. Why
--- not, when it did not.
local function compiles(tmp: string, text: string, parameters: {string:string}): boolean, string
  local ended = run_under(tmp, text, parameters, { "/usr/bin/true" }, 5)
  return ended.started, ended.why
end

--- Which forms of a `remote` rule the system's profile compiler takes.
local function test_which_remote_forms_the_profile_compiler_takes(tmp: string)
  macos_only()
  local report = new_report()
  local parsed: {string:boolean} = {}
  for _, form in ipairs(forms(8080)) do
    local ok, why = compiles(tmp, profile(BASE, form.lines), form.parameters)
    parsed[form.name] = ok
    report[#report + 1] = form.name .. ": " .. (ok and "compiles" or ("REFUSED " .. brief(why)))
  end
  -- A rule that is not SBPL is refused, so a "compiles" above is the system's
  -- parse and not a start that skips the profile.
  local broken = compiles(tmp, profile(BASE, { "(allow network-outbound (remote ip" }), {})
  report[#report + 1] = "malformed: " .. (broken and "COMPILES" or "refused")
  assert(not broken, "a malformed profile started\n" .. table.concat(report, "\n"))
  assert(compiles(tmp, profile(BASE, {}), {}), "the base profile does not compile\n" .. table.concat(report, "\n"))
  assert(parsed["ip-localhost"], "(remote ip \"localhost:PORT\") does not compile\n" .. table.concat(report, "\n"))
  assert(parsed["tcp-localhost"] and parsed["ip-param"] and parsed["ip-star"], "a form that compiled before does not\n" ..
      table.concat(report, "\n"))
  -- The profile compiler takes no numeric host but "*" and "localhost".
  assert(not parsed["ip-127.0.0.1"] and not parsed["tcp-127.0.0.1"] and not parsed["ip-numeric-remote"],
    "a numeric host compiles\n" .. table.concat(report, "\n"))
  conclude(report)
end

--- What each form of the rule reaches over TCP of two live listeners on
--- 127.0.0.1 and one on ::1, which is the port rule the design relies on.
local function test_a_port_rule_reaches_its_port_and_no_other(tmp: string)
  macos_only()
  local report = new_report()
  local allowed <close> = assert(listener("127.0.0.1", 0))
  local other <close> = assert(listener("127.0.0.1", 0))
  local allowed_port, other_port = port_of(allowed.address), port_of(other.address)
  assert(allowed_port ~= other_port)
  -- The same number on ::1 where it is free, else a port of its own for
  -- which the rule is made over again.
  local v6, v6_why = listener("::1", allowed_port)
  local v6_port = allowed_port
  if v6 == nil then
    local _, _ = v6_why, nil
    v6 = listener("::1", 0)
    if v6 ~= nil then v6_port = port_of(v6.address) end
  end
  report[#report + 1] = "listeners: 127.0.0.1:" .. allowed_port .. " (allowed), 127.0.0.1:" .. other_port ..
    " (other), [::1]:" .. (v6 ~= nil and tostring(v6_port) or ("none: " .. tostring(v6_why)))
  local firsts: {string:string} = {}
  for index, form in ipairs(forms(allowed_port)) do
    if form.scoped then
      local text = profile(BASE, form.lines)
      local ok, why = compiles(tmp, text, form.parameters)
      if not ok then
        report[#report + 1] = form.name .. ": does not compile " .. brief(why)
      else
        local a_nc, a_bash = tcp_reach(tmp, text, form.parameters, "127.0.0.1", allowed_port)
        local o_nc, o_bash = tcp_reach(tmp, text, form.parameters, "127.0.0.1", other_port)
        report[#report + 1] = form.name .. ": allowed port nc=" .. a_nc .. " bash=" .. a_bash ..
          "; other port nc=" .. o_nc .. " bash=" .. o_bash
        if index == 1 then
          firsts.allowed = a_nc .. "/" .. a_bash
          firsts.other = o_nc .. "/" .. o_bash
        end
        if any(a_nc, a_bash, "CONNECTED") then
          -- A rule that reaches its own port is tried on ::1 as well.
          if v6 ~= nil then
            local rule_port = v6_port == allowed_port and form.lines or forms(v6_port)[index].lines
            local v6_text = profile(BASE, rule_port)
            local v_nc, v_bash = tcp_reach(tmp, v6_text, form.parameters, "::1", v6_port)
            report[#report + 1] = "  [::1]:" .. v6_port .. ": nc=" .. v_nc .. " bash=" .. v_bash
          end
        end
      end
    end
  end
  -- No rule at all: the other and the allowed port are denied alike, so a
  -- connect that is allowed above is the rule's.
  local none_nc, none_bash = tcp_reach(tmp, profile(BASE, {}), {}, "127.0.0.1", allowed_port)
  report[#report + 1] = "no rule: nc=" .. none_nc .. " bash=" .. none_bash
  assert(any(none_nc, none_bash, "DENIED") and not any(none_nc, none_bash, "CONNECTED"),
    "a connect with no rule was not denied\n" .. table.concat(report, "\n"))
  local text = profile(BASE, forms(allowed_port)[1].lines)
  local a_nc, a_bash = tcp_reach(tmp, text, {}, "127.0.0.1", allowed_port)
  local o_nc, o_bash = tcp_reach(tmp, text, {}, "127.0.0.1", other_port)
  assert(any(a_nc, a_bash, "CONNECTED"), "the rule's own port was not reached\n" .. table.concat(report, "\n"))
  assert(any(o_nc, o_bash, "DENIED") and not any(o_nc, o_bash, "CONNECTED") and
      not any(o_nc, o_bash, "REFUSED"), "the other port was not denied outright\n" .. table.concat(report, "\n"))
  conclude(report)
end

--- Whether a datagram one tool sent under `text` reached `socket`.
local function udp_arrives(socket: Udp.Bound, text: string, tmp: string, port: integer, host: string): string
  local sent = run_under(tmp, text, {}, { "/bin/bash", "-c", "echo ping > /dev/udp/$1/$2", "bash", host, tostring(port) })
  local packet = Udp.receive(socket, Clock.ms(400))
  return (packet ~= nil and packet.data:find("ping", 1, true) and "DELIVERED" or "not delivered") ..
    " (" .. verdict(sent) .. ")"
end

local function test_a_port_rule_and_udp(tmp: string)
  macos_only()
  local report = new_report()
  local allowed <close> = assert(Udp.bind("127.0.0.1", 0))
  local allowed_port = port_of(allowed.address)
  local other <close> = assert(Udp.bind("127.0.0.1", 0))
  local other_port = port_of(other.address)
  local text = profile(BASE, forms(allowed_port)[1].lines)
  local bare = profile(BASE, {})
  local control = profile({ "(version 1)", "(allow default)" }, {})
  local to_rule = udp_arrives(allowed, text, tmp, allowed_port, "127.0.0.1")
  report[#report + 1] = "udp 127.0.0.1:" .. allowed_port .. " (rule's port): " .. to_rule
  local to_other = udp_arrives(other, text, tmp, other_port, "127.0.0.1")
  report[#report + 1] = "udp 127.0.0.1:" .. other_port .. " (other port): " .. to_other
  assert(to_rule:find("^DELIVERED"), "udp to the rule's port was not sent\n" .. table.concat(report, "\n"))
  assert(to_other:find("^not delivered") and to_other:find("DENIED"), "udp to another port was not denied\n" ..
      table.concat(report, "\n"))
  report[#report + 1] = "udp, no rule: " .. udp_arrives(allowed, bare, tmp, allowed_port, "127.0.0.1")
  local v6 = Udp.bind("::1", allowed_port)
  if v6 ~= nil then
    report[#report + 1] = "udp [::1]:" .. allowed_port .. " (rule's number): " ..
      udp_arrives(v6, text, tmp, allowed_port, "::1")
    Udp.close(v6)
  else
    report[#report + 1] = "udp ::1: no socket to send to"
  end
  -- nc speaks UDP too, which says whether it is the tool or the rule.
  local nc = run_under(tmp, text, {}, { "/bin/sh", "-c", "echo ping | /usr/bin/nc -n -u -w 1 127.0.0.1 " .. allowed_port })
  local packet = Udp.receive(allowed, Clock.ms(400))
  report[#report + 1] = "nc -u to the rule's port: " .. (packet ~= nil and "DELIVERED" or "not delivered") ..
    " (" .. verdict(nc) .. ")"
  -- The control shows the sending works at all on this host.
  local sanity = udp_arrives(other, control, tmp, other_port, "127.0.0.1")
  report[#report + 1] = "udp, allow default: " .. sanity
  assert(sanity:find("^DELIVERED"), "udp is not sent even with no profile to hold it\n" .. table.concat(report, "\n"))
  local bare_said = udp_arrives(allowed, bare, tmp, allowed_port, "127.0.0.1")
  assert(bare_said:find("^not delivered"), "udp was sent with no rule\n" .. table.concat(report, "\n"))
  conclude(report)
end

--- Waits up to `seconds` for a connect to `port` on the loopback to be
--- accepted, then sends "ping\n" through it. Whether it connected.
local function reach_listener(port: integer, seconds: number): boolean
  local deadline = Clock.monotonic_ns() + Clock.seconds(seconds)
  while Clock.monotonic_ns() < deadline do
    local conn = Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Clock.ms(300) })
    if conn ~= nil then
      local _, _ = conn:write("ping\n")
      local _, _ = conn:close()
      return true
    end
    local _, _ = Clock.sleep_ns(Clock.ms(100))
  end
  return false
end

--- Whether a child that listens on a loopback port under `text` is reached by
--- a connection from outside, and what it read of it.
local function listens(tmp: string, text: string, port: integer): string
  local running = start(tmp, text, {}, { "/usr/bin/nc", "-n", "-l", "127.0.0.1", tostring(port) })
  if running.pid == nil then return "NOSTART(" .. brief(running.why or "") .. ")" end
  local reached = reach_listener(port, 1.5)
  local _, _ = Clock.sleep_ns(Clock.ms(300))
  local ended = reap(running, 0.01)
  return (reached and "connectable" or "not connectable") .. ", child read " .. brief(ended.text) ..
    " (" .. (ended.timed_out and "ended by the test" or ("code " .. ended.code)) .. ")"
end

local function test_a_port_rule_and_binding(tmp: string)
  macos_only()
  local report = new_report()
  local probe = assert(listener("127.0.0.1", 0))
  local port = port_of(probe.address)
  local _, _ = probe:close()
  local control = listens(tmp, profile({ "(version 1)", "(allow default)" }, {}), port)
  report[#report + 1] = "allow default: " .. control
  local rule = forms(port)[1].lines
  local only = listens(tmp, profile(BASE, rule), port)
  report[#report + 1] = "port rule alone: " .. only
  local bound = listens(tmp, profile(BASE, { rule[1], "(allow network-bind (local ip \"localhost:*\"))" }), port)
  report[#report + 1] = "port rule and network-bind: " .. bound
  local inbound = listens(tmp, profile(BASE, { rule[1], "(allow network-bind (local ip \"localhost:*\"))",
    "(allow network-inbound (local ip \"localhost:*\"))" }), port)
  report[#report + 1] = "port rule, network-bind and network-inbound: " .. inbound
  assert(control:find("^connectable"), "nc does not listen even with no profile to hold it\n" ..
      table.concat(report, "\n"))
  assert(only:find("^not connectable"), "a port rule alone let a child listen\n" .. table.concat(report, "\n"))
  assert(bound:find("^not connectable"), "network-bind alone let a child listen\n" .. table.concat(report, "\n"))
  assert(inbound:find("^connectable"), "network-bind and network-inbound did not let a child listen\n" ..
      table.concat(report, "\n"))
  conclude(report)
end

--- What a connect to the unix socket at `path` ends in under `text`, by perl,
--- which says what the system answered.
local function unix_reach(tmp: string, text: string, parameters: {string:string}, path: string): string
  local ended = run_under(tmp, text, parameters, { "/usr/bin/perl", "-e",
    "use Socket; socket(S, PF_UNIX, SOCK_STREAM, 0) or die \"socket: $!\\n\"; " ..
      "print connect(S, sockaddr_un($ARGV[0])) ? \"connected\\n\" : \"connect: $!\\n\";", path }, 5)
  if not ended.started then return "NOSTART(" .. brief(ended.why) .. ")" end
  if ended.text:find("connected", 1, true) then return "CONNECTED" end
  if ended.text:find("not permitted", 1, true) then return "DENIED" end
  return "OTHER(" .. ended.code .. " " .. brief(ended.text) .. ")"
end

local function test_a_unix_socket_is_denied_under_default_deny(tmp: string)
  macos_only()
  local report = new_report()
  local mdns = "/var/run/mDNSResponder"
  local real = "/private" .. mdns
  local function rule(path: string): string
    return "(allow network-outbound (remote unix-socket (path-literal \"" .. path .. "\")))"
  end
  report[#report + 1] = mdns .. ": " .. (sys.stat(mdns) ~= nil and "exists" or "absent")
  local control = unix_reach(tmp, profile({ "(version 1)", "(allow default)" }, {}), {}, mdns)
  report[#report + 1] = "allow default: " .. control
  local bare = unix_reach(tmp, profile(BASE, {}), {}, mdns)
  report[#report + 1] = "default-deny: " .. bare
  report[#report + 1] = "with (remote ip \"*:*\"): " ..
    unix_reach(tmp, profile(BASE, { "(allow network-outbound (remote ip \"*:*\"))" }), {}, mdns)
  report[#report + 1] = "with a rule on /var/run/mDNSResponder: " ..
    unix_reach(tmp, profile(BASE, { rule(mdns) }), {}, mdns)
  local granted = unix_reach(tmp, profile(BASE, { rule(real) }), {}, mdns)
  report[#report + 1] = "with a rule on /private/var/run/mDNSResponder: " .. granted
  -- A socket of the test's own, where the path fits sun_path.
  local own = tmp .. "/s"
  local server = Net.listen(Net.unix(own))
  if server ~= nil then
    local resolved = sys.realpath(own) or own
    report[#report + 1] = "own socket, default-deny: " .. unix_reach(tmp, profile(BASE, {}), {}, own)
    report[#report + 1] = "own socket, rule by param: " .. unix_reach(tmp, profile(BASE,
      { "(allow network-outbound (remote unix-socket (path-literal (param \"SOCK\"))))" }), { SOCK = resolved }, own)
    local _, _ = server:close()
  else
    report[#report + 1] = "own socket: none"
  end
  assert(control == "CONNECTED", "the socket is not reached with no profile\n" .. table.concat(report, "\n"))
  assert(bare == "DENIED", mdns .. " was not denied under default-deny\n" .. table.concat(report, "\n"))
  assert(granted == "CONNECTED", "a rule on its real path does not reach it\n" .. table.concat(report, "\n"))
  conclude(report)
end

--- The paths the system's programs run from, as cosmic/sandbox/seatbelt.tl's
--- "system" profile reads them, for a profile that holds the files too.
local SYSTEM <const>: {string} = {
  "/usr", "/bin", "/sbin", "/System/Library", "/Library/Apple/System/Library",
  "/System/Cryptexes/App", "/System/Cryptexes/OS", "/System/Volumes/Preboot/Cryptexes/App/System",
  "/System/Volumes/Preboot/Cryptexes/OS", "/private/var/db/dyld", "/private/var/select",
}

--- A profile that runs the system's programs, reads only what they run
--- from, and has no network, Mach service or write.
local function strict(): {string}
  local lines: {string} = {
    "(version 1)", "(deny default)", "(allow file-read-metadata)", "(allow sysctl-read)",
    "(allow process-fork)", "(allow signal (target self))", "(allow process-info-pidinfo (target self))",
    "(allow file-write-data (literal \"/dev/null\") (literal \"/dev/dtracehelper\"))",
    "(allow file-read-data (literal \"/\"))",
    "(allow file-read* (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/random\") (literal \"/dev/urandom\") " ..
      "(literal \"/etc/passwd\") (literal \"/etc/group\") (literal \"/etc/localtime\") (subpath \"/private/var/db/timezone\"))",
  }
  for _, path in ipairs(SYSTEM) do
    lines[#lines + 1] = "(allow file-read* file-map-executable process-exec (subpath \"" .. path .. "\"))"
  end
  return lines
end

--- The files a resolver may read, in their real paths.
local RESOLVER_FILES <const>: {string} = {
  "/private/etc/resolv.conf", "/private/etc/hosts", "/private/var/run/resolv.conf",
  "/private/etc/resolver", "/private/etc/services", "/private/etc/protocols",
  "/private/etc/nsswitch.conf", "/private/etc/hostconfig",
}

local function resolver_files(skip: string | nil): {string}
  local lines: {string} = {}
  for _, path in ipairs(RESOLVER_FILES) do
    if path ~= skip then lines[#lines + 1] = "(allow file-read* (subpath \"" .. path .. "\"))" end
  end
  return lines
end

--- c-ares's way on a system with resolv.conf: read the file, ask each name
--- server for example.com over UDP, take the first answer.
local DIG <const> = [[
use strict; use Socket;
open(my $f, "<", "/etc/resolv.conf") or die "open resolv.conf: $!\n";
my @ns; while (<$f>) { push @ns, $1 if /^nameserver\s+(\d+\.\d+\.\d+\.\d+)/ }
die "no IPv4 nameserver in resolv.conf\n" unless @ns;
my $q = pack("nnnnnn", 0x1234, 0x0100, 1, 0, 0, 0) .
  join("", map { chr(length $_) . $_ } split(/\./, "example.com")) . "\0" . pack("nn", 1, 1);
for my $ns (@ns) {
  socket(my $s, PF_INET, SOCK_DGRAM, 0) or die "socket: $!\n";
  send($s, $q, 0, sockaddr_in(53, inet_aton($ns))) or do { print "send $ns: $!\n"; next };
  my $r = ''; vec($r, fileno($s), 1) = 1;
  if (select($r, undef, undef, 2) > 0) {
    recv($s, my $buf, 512, 0);
    print "answer from $ns: ", unpack("n", substr($buf, 6, 2)), " records\n"; exit 0;
  }
  print "no answer from $ns\n";
}
exit 1;
]]

--- A resolver and what shows it worked: c-ares's own way, Apple's dnsinfo
--- that c-ares reads through configd (scutil --dns prints it), and the C
--- library's, through mDNSResponder.
local record Resolver
  name: string
  argv: {string}
  works: string
end

local RESOLVERS <const>: {Resolver} = {
  { name = "udp-by-resolv.conf", argv = { "/usr/bin/perl", "-e", DIG }, works = "answer from" },
  { name = "scutil --dns", argv = { "/usr/sbin/scutil", "--dns" }, works = "nameserver[0]" },
  { name = "dscacheutil", argv = { "/usr/bin/dscacheutil", "-q", "host", "-a", "name", "example.com" }, works = "ip_address" },
}

--- What each resolver does under `text`, for the report, and whether the
--- first of them (c-ares's own way) worked.
local function resolve_under(tmp: string, text: string, report: {string}, label: string): boolean, {string:boolean}
  local worked: {string:boolean} = {}
  local first = false
  for index, resolver in ipairs(RESOLVERS) do
    local ended = run_under(tmp, text, {}, resolver.argv, 4)
    local ok = ended.started and ended.text:find(resolver.works, 1, true) ~= nil
    worked[resolver.name] = ok
    if index == 1 then first = ok end
    report[#report + 1] = label .. " / " .. resolver.name .. ": " .. (ok and "WORKS" or "fails") ..
      (ended.started and (" [code " .. ended.code .. " signal " .. ended.signal .. "]") or "") ..
      (ended.started and (" " .. brief(ended.text)) or (" NOSTART " .. brief(ended.why)))
  end
  return first, worked
end

--- Skips the test where this host has no way to ask a name server, since a
--- failure under a profile would then say nothing of the profile.
local function network_or_skip()
  local result = Child.run(RESOLVERS[1].argv, { stdout = "capture", stderr = "capture", stdin = "null",
    timeout_ns = Clock.seconds(6) })
  if result == nil or not (result.stdout or ""):find("answer from", 1, true) then
    Test.skip("no name server answers a host program here: " .. brief((result and result.stdout or "") ..
        (result and result.stderr or "")))
  end
end

--- What Seatbelt denied lately for the programs these tests start, as the
--- system's log names it: operation and name of each refusal.
local function denials(): string
  local _, _ = Clock.sleep_ns(Clock.seconds(1.5))
  local result = Child.run({ "/usr/bin/log", "show", "--last", "1m", "--style", "compact",
    "--predicate", "eventMessage CONTAINS \"Sandbox:\" AND eventMessage CONTAINS \"deny(\"" },
    { stdout = "capture", stderr = "capture", stdin = "null", timeout_ns = Clock.seconds(6) })
  if result == nil then return "log: unavailable" end
  local lines: {string} = {}
  local seen: {string:boolean} = {}
  for line in (result.stdout or ""):gmatch("[^\n]+") do
    for _, name in ipairs({ "perl", "scutil", "dscacheutil", "nc(", "bash", "sh(", "true" }) do
      local at = line:find("Sandbox: " .. name, 1, true)
      if at ~= nil then
        -- The pid differs with each run, and only the operation says.
        local said = line:sub(at):gsub("%(%d+%)", "")
        if not seen[said] then
          seen[said] = true
          lines[#lines + 1] = said
        end
        break
      end
    end
  end
  local first = math.max(1, #lines - 70)
  return "log (" .. #lines .. " refusals" .. (result.timed_out and ", log timed out" or "") .. "):\n" ..
    table.concat(lines, "\n", first, #lines) .. "\nlog stderr: " .. (result.stderr or ""):sub(1, 200)
end

local OUTBOUND <const> = "(allow network-outbound (remote ip \"*:*\"))"

--- With outbound network and the resolver files and nothing else, what each
--- resolver does and which refusals the log shows.
local function test_what_a_resolver_is_refused_with_network_and_resolver_files(tmp: string)
  macos_only()
  network_or_skip()
  local report = new_report()
  local text = profile(strict(), { OUTBOUND })
  local no_files = profile(strict(), { OUTBOUND })
  local bare, _ = resolve_under(tmp, no_files, report, "network, no resolver files")
  local with_files = profile(strict(), { OUTBOUND, table.concat(resolver_files(nil), "\n") })
  -- Only the second run's refusals matter: the log is read once, after both.
  local c_ares, worked = resolve_under(tmp, with_files, report, "network and resolver files")
  report[#report + 1] = denials()
  assert(compiles(tmp, text, {}), "the strict profile does not compile\n" .. table.concat(report, "\n"))
  assert(not bare, "the c-ares way resolved with no resolver file\n" .. table.concat(report, "\n"))
  assert(c_ares, "the c-ares way fails with outbound network and the resolver files\n" .. table.concat(report, "\n"))
  -- Apple's dnsinfo (scutil --dns) needs a Mach service, which the next test names.
  assert(not worked["scutil --dns"], "dnsinfo needs no Mach service\n" .. table.concat(report, "\n"))
  conclude(report)
end

--- Prefixes of Mach services a resolver might look up, from the log's
--- denials in the round before.
local MACH <const>: {string} = {
  "com.apple.SystemConfiguration", "com.apple.dnssd", "com.apple.mDNSResponder",
  "com.apple.networkd", "com.apple.system.notification_center", "com.apple.system.opendirectoryd",
  "com.apple.system.logger", "com.apple.trustd", "com.apple.cfprefsd",
}

local function mach_rules(skip: string | nil): {string}
  local lines: {string} = {}
  for _, prefix in ipairs(MACH) do
    if prefix ~= skip then
      lines[#lines + 1] = "(allow mach-lookup (global-name-prefix \"" .. prefix .. "\"))"
    end
  end
  return lines
end

--- With each Mach service of a list too, and with every one, what works;
--- then which of the list each resolver cannot do without.
local function test_which_mach_services_a_resolver_needs(tmp: string)
  macos_only()
  network_or_skip()
  local report = new_report()
  local base: {string} = { OUTBOUND, table.concat(resolver_files(nil), "\n") }
  local function with(more: {string}): string
    local lines: {string} = {}
    for _, line in ipairs(base) do lines[#lines + 1] = line end
    for _, line in ipairs(more) do lines[#lines + 1] = line end
    return profile(strict(), lines)
  end
  local all = with(mach_rules(nil))
  local c_ares, worked = resolve_under(tmp, all, report, "candidate mach services")
  local every = with({ "(allow mach-lookup)" })
  local _, any_worked = resolve_under(tmp, every, report, "every mach lookup")
  -- Each prefix taken out in turn: the resolver that then fails needs it.
  for _, prefix in ipairs(MACH) do
    local lines: {string} = {}
    for _, line in ipairs(base) do lines[#lines + 1] = line end
    for _, line in ipairs(mach_rules(prefix)) do lines[#lines + 1] = line end
    local text = profile(strict(), lines)
    local needed: {string} = {}
    for _, resolver in ipairs(RESOLVERS) do
      if worked[resolver.name] then
        local ended = run_under(tmp, text, {}, resolver.argv, 3)
        if not (ended.started and ended.text:find(resolver.works, 1, true)) then
          needed[#needed + 1] = resolver.name
        end
      end
    end
    report[#report + 1] = "without " .. prefix .. ": " ..
      (#needed == 0 and "nothing fails" or ("needed by " .. table.concat(needed, ", ")))
    -- Only SystemConfiguration's lookup matters, and only to dnsinfo.
    local expected = prefix == "com.apple.SystemConfiguration" and "scutil --dns" or ""
    assert(table.concat(needed, ", ") == expected, "without " .. prefix .. ", " .. table.concat(needed, ", ") ..
        " fails\n" .. table.concat(report, "\n"))
  end
  local _ = any_worked
  assert(worked["scutil --dns"], "dnsinfo fails with the Mach list\n" .. table.concat(report, "\n"))
  assert(c_ares, "the c-ares way of resolving fails even with outbound, files and the Mach list\n" ..
      table.concat(report, "\n"))
  conclude(report)
end

--- Which resolver files the resolvers cannot do without, and whether a rule on
--- UDP port 53 alone takes the place of all outbound network.
local function test_which_resolver_files_and_network_a_resolver_needs(tmp: string)
  macos_only()
  network_or_skip()
  local report = new_report()
  local function with(files: {string}, network: string): string
    local lines: {string} = { network, "(allow mach-lookup (global-name \"com.apple.SystemConfiguration.DNSConfiguration\"))" }
    for _, line in ipairs(files) do lines[#lines + 1] = line end
    return profile(strict(), lines)
  end
  local _, worked = resolve_under(tmp, with(resolver_files(nil), OUTBOUND), report, "all files")
  for _, path in ipairs(RESOLVER_FILES) do
    local needed: {string} = {}
    for _, resolver in ipairs(RESOLVERS) do
      if worked[resolver.name] then
        local ended = run_under(tmp, with(resolver_files(path), OUTBOUND), {}, resolver.argv, 3)
        if not (ended.started and ended.text:find(resolver.works, 1, true)) then
          needed[#needed + 1] = resolver.name
        end
      end
    end
    report[#report + 1] = "without " .. path .. ": " ..
      (#needed == 0 and "nothing fails" or ("needed by " .. table.concat(needed, ", ")))
    -- /etc/resolv.conf is a link to this one, the only file a resolver reads.
    local expected = path == "/private/var/run/resolv.conf" and "udp-by-resolv.conf" or ""
    assert(table.concat(needed, ", ") == expected, "without " .. path .. ", " .. table.concat(needed, ", ") ..
        " fails\n" .. table.concat(report, "\n"))
  end
  for _, network in ipairs({ "(allow network-outbound (remote udp \"*:53\"))",
      "(allow network-outbound (remote ip \"*:53\"))", "(allow network-outbound (remote udp \"*:*\"))" }) do
    local ok, by = resolve_under(tmp, with(resolver_files(nil), network), report, network)
    assert(ok and by["scutil --dns"], network .. " does not let a resolver work\n" .. table.concat(report, "\n"))
  end
  assert(worked["udp-by-resolv.conf"] and worked["scutil --dns"], "a resolver fails with all the files\n" .. table.concat(report, "\n"))
  conclude(report)
end
