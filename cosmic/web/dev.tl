--- The development loop of a web app: a supervisor that restarts the
--- program when its files change, and, in the app, a page reload when the
--- program comes back and a stylesheet swap when only a `.css` file under
--- `static/` changed.
---
--- The app's side is [`Dev.app`], a [`Web.app`] that turns development mode
--- on when the environment variable `COSMIC_WEB_DEV` is `1` (the
--- supervisor sets it) and is the plain app otherwise, so one program
--- is both:
---
---     local Dev = require("cosmic.web.dev")
---     local app = Dev.app{ routes = {
---       Dev.static("/static"),
---       Web.get("/", home),
---     } }
---
--- In development mode the app shows a fault's stack ([`Web.AppSpec`]'s
--- `debug`), serves `static/` from disk with `Cache-Control: no-store`
--- ([`Dev.static`]), adds one `<script src="/_web/dev.js" defer>` to every
--- `text/html` page with a `</body>`, and answers two paths for that
--- script under `/_web/dev`. The script reloads the page when the process it
--- reached is not the one it first met, and swaps the stylesheets when the
--- event stream says only `.css` moved. Since such an app shows source
--- paths and values to whoever asks, [`Web.serve`] refuses it a listener
--- beyond the loopback or a `trusted_proxy`, and unless the app names
--- `trusted_hosts` it answers only `localhost`, `127.0.0.1` and `[::1]`
--- (any port), so a page of another site cannot reach it by a name that
--- resolves to the loopback (DNS rebinding); the script and the stream
--- honour the same check.
---
--- The supervisor is [`Dev.supervise`], run as a program of its own,
--- `cosmic dev.tl` with a `dev.tl` of
--- `return function() return Dev.supervise{} end`: it starts
--- `cosmic app.tl`, compares the files' sizes and times every 300 ms, and
--- replaces the process on a change, SIGTERM first, so the app's graceful
--- stop runs. Templates compile into modules when the tree is built, so a
--- restart is what a template edit needs; files under `static/` are served
--- from disk and so never restart anything. Files the supervisor does not
--- follow into (`node_modules`, build output) are named in `ignore`.

local Assets = require("cosmic.web.assets")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Headers = require("cosmic.web.headers")
local Html = require("cosmic.html")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local Response = require("cosmic.web.response")
local Signal = require("cosmic.signal")
local Sse = require("cosmic.web.sse")
local StaticFiles = require("cosmic.web.static")
local Types = require("cosmic.web.types")
local App = require("cosmic.web.app")
local Request = require("cosmic.web.request")

local record Dev
  --- What [`Dev.app`] and [`Dev.static`] take; every field is optional.
  record Options
    --- Whether development mode is on; nil reads `COSMIC_WEB_DEV` (on for
    --- `1`, and for nothing else).
    enabled: boolean
    --- The directory the page's stylesheets come from and whose changes
    --- the browser follows ("static" by default).
    static: string
    --- How often the open event streams look at `static` (250 ms by
    --- default).
    interval_ns: integer
    --- What tells a page its process is not the one it met: nil reads
    --- `COSMIC_WEB_BOOT`, which the supervisor counts up, else a token
    --- made when the app is.
    boot: string
  end

  --- What [`Dev.supervise`] takes; every field is optional.
  record SuperviseOptions
    --- The program to run, as an argument list: this program on `app.tl`
    --- (`cosmic app.tl`) by default.
    command: {string}
    --- Starts the program given its whole environment, in place of
    --- [`Child.start`] on `command` with that environment; for a program that
    --- needs more than an argument list. Nil and why where it cannot start.
    start: function(env: {string:string}): Child.Handle | nil, string
    --- Directories whose files are watched (the working directory by
    --- default). A change to one's size or time, or an added or removed
    --- file, restarts the program.
    watch: {string}
    --- Files left out, by glob (`*` and `?`): one without a "/" is matched
    --- against a file's or directory's name, one with it against its path
    --- from the watched directory, and one that begins with "/" against
    --- that path from its start. By default the hidden files, databases
    --- and their journals, editors' backups, `node_modules` and the root's
    --- `static` directory (see `static`). Giving `ignore` replaces that list.
    ignore: {string}
    --- The directory (from the watched root) whose changes the browser
    --- follows without a restart and the default `ignore` leaves out:
    --- "static" by default; the `static` of [`Dev.app`]'s options.
    static: string
    --- How often the files are looked at (300 ms by default). A change
    --- restarts the program once a look finds nothing further moved.
    interval_ns: integer
    --- How long a program has to stop after SIGTERM before SIGKILL (3
    --- seconds by default).
    grace_ns: integer
    --- Where the supervisor's lines go (standard error by default).
    log: function(text: string)
    --- Called after each start with the boot's number, from 1, and the
    --- program's process id; for a test.
    on_boot: function(boot: integer, pid: integer)
    --- Asked after each look at the files: true ends the supervisor, as a
    --- Ctrl-C does. For a test.
    stop: function(): boolean
  end
end

local DEFAULT_INTERVAL_NS <const> = Clock.ms(250)
local SUPERVISE_INTERVAL_NS <const> = Clock.ms(300)
local DEFAULT_GRACE_NS <const> = Clock.seconds(3)
local RECONNECT_MS <const> = 300
local LISTED <const> = 20

local DEFAULT_IGNORE <const>: {string} = {
  ".*", "*.db", "*.db-wal", "*.db-shm", "*.db-journal", "*~", "node_modules",
}

local LOCAL_HOSTS <const>: {string} = { "localhost", "127.0.0.1", "[::1]" }

local OPTION_FIELDS <const>: {string:boolean} = {
  enabled = true, static = true, interval_ns = true, boot = true,
}

local SUPERVISE_FIELDS <const>: {string:boolean} = {
  command = true, start = true, watch = true, ignore = true, static = true, interval_ns = true,
  grace_ns = true, log = true, on_boot = true, stop = true,
}

--- The browser's half: a reload when the process changed, a swap of the
--- stylesheets when the stream says css. The script itself is not inline
--- (it is served from `/_web/dev.js`); the tag that loads it carries the
--- request's CSP nonce ([`Headers.NONCE`]) when the app draws one, as a CSP
--- that requires a nonce refuses an element without it.
-- The guard keeps a second copy of the script (htmx runs the scripts of a
-- swapped page) from opening another stream.
local SCRIPT <const> = [==[
(function () {
  "use strict";
  if (window.__cosmicDev) return;
  window.__cosmicDev = true;
  var boot = null;
  var source = null;

  function sheets(doc) {
    return Array.prototype.slice.call(doc.querySelectorAll('link[rel~="stylesheet"]'));
  }

  function swap() {
    fetch(location.href, { credentials: "same-origin", headers: { Accept: "text/html" } })
      .then(function (r) { return r.text(); })
      .then(function (html) {
        var current = sheets(document);
        var next = sheets(new DOMParser().parseFromString(html, "text/html"));
        var have = current.map(function (l) { return l.getAttribute("href"); });
        var pending = next.length;
        function drop() {
          pending -= 1;
          if (pending <= 0) current.forEach(function (l) { l.remove(); });
        }
        if (pending === 0) { drop(); return; }
        next.forEach(function (n) {
          var l = n.cloneNode(false);
          var href = n.getAttribute("href");
          if (have.indexOf(href) >= 0) {
            l.setAttribute("href", href + (href.indexOf("?") < 0 ? "?" : "&") + "_dev=" + Date.now());
          }
          l.onload = l.onerror = drop;
          if (current.length > 0) current[0].parentNode.insertBefore(l, current[0]);
          else document.head.appendChild(l);
        });
      })
      .catch(function () { location.reload(); });
  }

  function connect() {
    source = new EventSource("/_web/dev/events");
    source.addEventListener("boot", function (e) {
      if (boot !== null && boot !== e.data) location.reload();
      boot = e.data;
    });
    source.addEventListener("reload", function () { location.reload(); });
    source.addEventListener("css", swap);
    source.onerror = function () {
      // A browser retries a lost connection itself, but gives up on a reply
      // that is not an event stream, such as a proxy's error while the
      // program starts.
      if (source.readyState === 2) setTimeout(connect, 300);
    };
  }

  connect();
})();
]==]

--- The tag that loads the script, with `nonce` when the request drew one.
local function tag(nonce: string | nil): string
  if nonce == nil or nonce == "" then return '<script src="/_web/dev.js" defer></script>' end
  return '<script src="/_web/dev.js" nonce="' .. Html.raw_attr(Html.escape_attr(nonce)) .. '" defer></script>'
end

--- Raises for an `opts` that is no table or holds a field `known` lacks.
local function checked(opts: any, known: {string:boolean}, what: string)
  if opts == nil then return end
  if not opts is {any:any} then error("web: " .. what .. " takes a table", 3) end
  for key in pairs(opts) do
    if not (key is string and known[key]) then
      error(("web: %s has no field %s"):format(what, tostring(key)), 3)
    end
  end
end

--- Raises where `value` is present and no integer of at least `least`.
local function counted(value: any, name: string, least: integer)
  if value == nil then return end
  if not value is integer or value < least then
    error(("web: %s must be an integer of at least %d"):format(name, least), 3)
  end
end

--- Whether `COSMIC_WEB_DEV` asks for development mode.
local function from_environment(): boolean
  return Env.get("COSMIC_WEB_DEV") == "1"
end

local function is_enabled(opts: Dev.Options | nil): boolean
  if opts ~= nil and opts.enabled ~= nil then return opts.enabled end
  return from_environment()
end

-- Watching files.

--- A glob (`*` any run, `?` any one byte) as an anchored Lua pattern.
local function pattern_of(glob: string): string
  local body = glob:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".")
  return "^" .. body .. "$"
end

--- A test of whether an entry is ignored, from `globs`; see
--- [`Dev.SuperviseOptions`]'s `ignore`.
local function ignorer(globs: {string}): function(rel: string, name: string): boolean
  local names: {string} = {}
  local paths: {string} = {}
  local anchored: {string} = {}
  for _, glob in ipairs(globs) do
    if glob:sub(1, 1) == "/" then
      anchored[#anchored + 1] = pattern_of(glob)
    elseif glob:find("/", 1, true) then
      paths[#paths + 1] = pattern_of(glob)
    else
      names[#names + 1] = pattern_of(glob)
    end
  end
  return function(rel: string, name: string): boolean
    for _, p in ipairs(names) do
      if name:find(p) then return true end
    end
    for _, p in ipairs(paths) do
      if rel:find(p) then return true end
    end
    for _, p in ipairs(anchored) do
      if ("/" .. rel):find(p) then return true end
    end
    return false
  end
end

-- Files are compared by size and modification time, so an edit that keeps
-- the size within one tick of a filesystem with coarse times (a second on
-- some) goes unseen; the next edit shows it.
-- TODO: watch with inotify (Linux) and kqueue (macOS) once cosmic.fs has a
-- watch binding, and sleep until an event instead of looking at every file's
-- size and time each interval; doc/roadmap.md lists the binding.
--- What each file under `roots` looks like now, by its path: size and
--- modification time to the nanosecond, following links. Nil and why where
--- a root cannot be listed; a root that is not there is empty when
--- `absent_ok`. A file that vanishes between the listing and its stat is
--- left out, as it is a change.
local function scan(roots: {string}, ignored: function(string, string): boolean,
                    absent_ok?: boolean): {string:string} | nil, string
  local found: {string:string} = {}
  for _, root in ipairs(roots) do
    local files: {string} = {}
    local present, _ = Fs.exists(root)
    if not (absent_ok and present == false) then
      local listed, why = Fs.walk_following(root, function(rel: string, name: string, _kind: Fs.Kind): boolean
        return ignored(rel, name)
      end)
      if listed == nil then return nil, why end
      files = listed
    end
    for _, rel in ipairs(files) do
      local path = root == "." and rel or (root .. "/" .. rel)
      local st, _ = Fs.stat(path)
      if st ~= nil then
        found[path] = ("%d:%d.%09d"):format(st.size, st.mtime, st.mtime_ns)
      end
    end
  end
  return found, ""
end

--- The paths that are in one of `before` and `after` and not the other or
--- differ between them, sorted.
local function changed(before: {string:string}, after: {string:string}): {string}
  local paths: {string} = {}
  for path, state in pairs(after) do
    if before[path] ~= state then paths[#paths + 1] = path end
  end
  for path in pairs(before) do
    if after[path] == nil then paths[#paths + 1] = path end
  end
  table.sort(paths)
  return paths
end

-- The event stream of a page.

--- An event source that looks at a directory while a stream waits and says
--- what moved: "css" when every change is to a stylesheet, "reload" else.
local record Watch is Sse.EventSource
  roots: {string}
  ignored: function(string, string): boolean
  interval_ns: integer
  last: {string:string} | nil
  trouble: boolean
  sink: Types.Sink
  queue: {Sse.Event}
  shut: boolean
  notifier: Poll.Notifier
  next: function(Watch, timeout_ns?: integer): Sse.Event | nil, string
  close: function(Watch)
end

--- The event for the moved `paths`.
local function event_for(paths: {string}): Sse.Event
  local css = true
  for _, path in ipairs(paths) do
    if not path:find("%.css$") then css = false end
  end
  local shown: {string} = {}
  for i = 1, math.min(#paths, LISTED) do shown[i] = paths[i] end
  return Sse.Event.text(css and "css" or "reload", table.concat(shown, "\n"))
end

--- Looks at the directory once, queueing an event for what moved.
--- A directory that is not there is empty, so its creation and removal are
--- changes; one that cannot be read keeps what was last seen (and is said
--- once), and a first look that failed only sets the baseline.
local function look(self: Watch)
  local now, why = scan(self.roots, self.ignored, true)
  if now == nil then
    if not self.trouble then self.sink:line("web dev: cannot watch static files: " .. why) end
    self.trouble = true
    return
  end
  self.trouble = false
  local before = self.last
  self.last = now
  if before == nil then return end
  local paths = changed(before, now)
  if #paths > 0 then self.queue[#self.queue + 1] = event_for(paths) end
end

function Watch.next(self: Watch, timeout_ns?: integer): Sse.Event | nil, string
  local deadline: integer = nil
  if timeout_ns ~= nil then deadline = Clock.monotonic_ns() + timeout_ns end
  while true do
    if self.queue[1] ~= nil then return table.remove(self.queue, 1), "" end
    if self.shut then return nil, "" end
    local wait = self.interval_ns
    if deadline ~= nil then
      local left = deadline - Clock.monotonic_ns()
      if left <= 0 then return nil, Poll.TIMEOUT end
      if left < wait then wait = left end
    end
    local _, _ = self.notifier:wait(wait)
    if self.shut then return nil, "" end
    look(self)
  end
end

function Watch.close(self: Watch)
  self.shut = true
  self.notifier:notify_all()
end

-- TODO: each open stream scans `static` on its own, so n tabs cost n scans
-- per interval; replace them with one shared scanner (or the inotify
-- binding at the TODO above) that feeds every stream.
--- The stream a page's script listens to: the process's boot token first,
--- then what moves under `static`.
local function events(req: Types.Request, boot: string, static: string, interval_ns: integer): Types.Response
  local roots = { static }
  local ignored = ignorer({ ".*" })
  local first, _ = scan(roots, ignored, true)
  local source: Watch = {
    roots = roots, ignored = ignored, interval_ns = interval_ns, last = first,
    trouble = first == nil, sink = req.app.spec.sink,
    queue = {}, shut = false, notifier = Poll.notifier(), next = Watch.next, close = Watch.close,
  }
  return Sse.EventStream(req, source, {
    retry_ms = RECONNECT_MS, initial = { Sse.Event.text("boot", boot) },
  })
end

-- The app's half.

--- `res` with the script's tag (`tag`) before its last `</body>`, as a
--- copy; `res` itself where it is no page of markup in a string, or has no
--- end of body.
local function injected(res: Types.Response, nonce: string | nil): Types.Response
  local body = res.body
  if not body is string then return res end
  local kind = Response.header(res, "Content-Type")
  if kind == nil or not kind:lower():find("^text/html") then return res end
  if Response.header(res, "Content-Encoding") ~= nil then return res end
  local lowered = body:lower()
  local at: integer = nil
  local from = 1
  while true do
    local found = lowered:find("</body>", from, true)
    if found == nil then break end
    at, from = found, found + 1
  end
  if at == nil then return res end
  local page = body:sub(1, at - 1) .. tag(nonce) .. body:sub(at)
  local headers: {string: string | {string}} = {}
  for name, value in pairs(res.headers or {}) do headers[name] = value end
  local copy: Types.Response = {}
  for key, value in pairs(res as {any:any}) do (copy as {any:any})[key] = value end
  copy.headers = headers
  copy.body = page
  if res.length ~= nil then copy.length = #page end
  if Response.header(copy, "Content-Length") ~= nil then
    Response.set_header(copy, "Content-Length", tostring(#page))
  end
  return copy
end

--- Whether the request names a host the app answers to.
local function host_ok(req: Types.Request): boolean
  local named = req.host ~= nil and Request.parse_host(req.host) or nil
  if named == nil then return false end
  for _, host in ipairs(req.app.spec.trusted_hosts or {}) do
    if host == named.host then return true end
  end
  return false
end

--- The middleware of development mode: the script, its event stream, and
--- the tag in the pages. The two paths answer only a host the app trusts;
--- a page already swapped in by htmx (`HX-Request`) gets no second tag.
local function reload(boot: string, static: string, interval_ns: integer): Types.Middleware
  return function(inner: Types.Handler): Types.Handler
    return function(req: Types.Request): Types.Response
      local ours = req.method == "GET" and (req.path == "/_web/dev.js" or req.path == "/_web/dev/events")
      if ours and not host_ok(req) then return inner(req) end
      if req.method == "GET" and req.path == "/_web/dev.js" then
        return { status = 200, body = SCRIPT, headers = {
          ["Content-Type"] = "text/javascript; charset=utf-8",
          ["Cache-Control"] = "no-store", ["X-Content-Type-Options"] = "nosniff",
        } }
      end
      if req.method == "GET" and req.path == "/_web/dev/events" then
        return events(req, boot, static, interval_ns)
      end
      local reply = inner(req)
      if req.headers["hx-request"] ~= nil then return reply end
      return injected(reply, req:get(Headers.NONCE))
    end
  end
end

--- The boot token for `opts`.
local function boot_of(opts: Dev.Options | nil): string
  if opts ~= nil and opts.boot ~= nil then return opts.boot end
  return Env.get("COSMIC_WEB_BOOT") or tostring(Clock.now_ns())
end

local function checked_options(opts: Dev.Options | nil, level: integer)
  checked(opts, OPTION_FIELDS, "dev")
  if opts == nil then return end
  local enabled: any = opts.enabled
  local static: any = opts.static
  local boot: any = opts.boot
  if enabled ~= nil and type(enabled) ~= "boolean" then
    error("web: dev: enabled must be a boolean", level)
  end
  if static ~= nil and (type(static) ~= "string" or static == "") then
    error("web: dev: static must be a path", level)
  end
  if boot ~= nil and type(boot) ~= "string" then error("web: dev: boot must be a string", level) end
  counted(opts.interval_ns, "dev: interval_ns", 1)
end

--- A [`Web.app`] that is in development mode when the environment says
--- so, else the plain app: see the module. Raises as [`Web.app`] does,
--- and for a field of `opts` of the wrong kind.
--- @param spec Types.AppSpec What the app is made of
--- @param opts Options | nil Whether development mode is on, and where `static` is
--- @return Types.App The app
function Dev.app(spec: Types.AppSpec, opts?: Dev.Options): Types.App
  checked_options(opts, 3)
  if not is_enabled(opts) then return App.new(spec) end
  if type(spec) ~= "table" then error("web: app takes a table", 2) end
  local given: Dev.Options = opts or {}
  local hosts = spec.trusted_hosts or LOCAL_HOSTS
  local stack: {Types.Middleware} = {
    reload(boot_of(opts), given.static or "static", given.interval_ns or DEFAULT_INTERVAL_NS),
  }
  for _, layer in ipairs(spec.middleware or {}) do stack[#stack + 1] = layer end
  return App.new({
    routes = spec.routes, middleware = stack, lifespan = spec.lifespan, debug = true,
    trailing_slash = spec.trailing_slash, trusted_hosts = hosts,
    trusted_proxy = spec.trusted_proxy, error_pages = spec.error_pages,
    error_view = spec.error_view, sink = spec.sink, builtin = spec.builtin,
    hubs = spec.hubs, max_streams = spec.max_streams, dev = true,
  })
end

--- A route serving `static/` under `prefix` ("/static" by default),
--- named "static" ([`StaticFiles.mount`]): from disk and never cached in
--- development mode, the program's own files otherwise.
--- @param prefix string | nil Where the files are mounted
--- @param opts Options | nil Whether development mode is on, and where `static` is
--- @return Types.Route The route
function Dev.static(prefix?: string, opts?: Dev.Options): Types.Route
  checked_options(opts, 3)
  local mount = prefix or "/static"
  if not is_enabled(opts) then return StaticFiles.mount(mount) end
  local root = opts and opts.static or "static"
  return StaticFiles.mount(mount, {
    source = Assets.directory(root), cache_control = "no-store", immutable_control = "no-store",
  })
end

-- The supervisor.

local function say(text: string)
  local _, _ = Fs.put(Fs.stderr, text .. "\n")
end

--- How an exited program ended, for a line.
local function ended(result: Child.Result): string
  if result.signal ~= nil then return ("was ended by signal %d"):format(result.signal) end
  return ("exited with status %d"):format(result.code or -1)
end

--- Runs the program and restarts it on a change until a SIGINT or SIGTERM
--- arrives or `stop` says so. The program inherits the supervisor's
--- standard streams and gets `COSMIC_WEB_DEV=1` and `COSMIC_WEB_BOOT=<n>`
--- (1 for the first start) beside the supervisor's environment. A
--- program that exits (a compile error exits at once) is left be until
--- the next change, not started again in a loop.
--- @param opts SuperviseOptions | nil What to run and watch
--- @return boolean True when stopped; false where the watched directories
---   cannot be read or the signals cannot be held
--- @return string Why not
function Dev.supervise(opts?: Dev.SuperviseOptions): boolean, string
  checked(opts, SUPERVISE_FIELDS, "dev.supervise")
  local given: Dev.SuperviseOptions = opts or {}
  counted(given.interval_ns, "dev.supervise: interval_ns", 1)
  counted(given.grace_ns, "dev.supervise: grace_ns", 0)
  local log = given.log or say
  local interval_ns = given.interval_ns or SUPERVISE_INTERVAL_NS
  local grace_ns = given.grace_ns or DEFAULT_GRACE_NS
  local roots = given.watch or { "." }
  local ignore = given.ignore
  if ignore == nil then
    ignore = {}
    for i, glob in ipairs(DEFAULT_IGNORE) do ignore[i] = glob end
    ignore[#ignore + 1] = "/" .. (given.static or "static")
  end
  local ignored = ignorer(ignore)
  local start = given.start
  if start == nil then
    local command = given.command
    if command == nil then
      local program, why = Proc.executable()
      if program == nil then return false, "web: dev: no program to run: " .. why end
      command = { program, "app.tl" }
    end
    start = function(env: {string:string}): Child.Handle | nil, string
      return Child.start(command, { env = env })
    end
  end
  local seen, why = scan(roots, ignored)
  if seen == nil then return false, why end
  -- TODO: hold SIGHUP as well once cosmic.signal's guard can: a closed
  -- terminal ends the supervisor at once and leaves the program running.
  -- TODO: once cosmic.child can start a program with PR_SET_PDEATHSIG, set
  -- it, so a supervisor ended by SIGKILL does not leave the app orphaned.
  local made, held = Signal.guard()
  if made == nil then return false, "web: dev: " .. held end
  local guard: Signal.Guard = made
  local handle: Child.Handle = nil
  local boot = 0

  local function launch()
    boot = boot + 1
    local env = Env.all()
    env.COSMIC_WEB_DEV = "1"
    env.COSMIC_WEB_BOOT = tostring(boot)
    log(("web dev: starting (boot %d)"):format(boot))
    local started, trouble = start(env)
    if started == nil then
      log("web dev: cannot start the program: " .. trouble .. "; waiting for a change")
      return
    end
    handle = started
    if given.on_boot ~= nil then given.on_boot(boot, started.pid) end
  end

  local function halt()
    if handle == nil then return end
    local h = handle
    handle = nil
    local _, _ = h:stop()
    -- TODO: give the program `grace_ns` when a SIGINT or SIGTERM stops the
    -- supervisor too: the guard's signal cuts this wait short, and
    -- cosmic.child ends the program after its own 250 ms. The fix is a
    -- wait here that the guard does not end (a loop over `h:try_wait`
    -- until `grace_ns` passes), once a second signal during it is decided
    -- on: end the program at once, or wait on.
    local _, _ = h:wait(grace_ns)
    local _, _ = h:close()
  end

  -- A change is acted on once a look finds nothing further moved, so an
  -- editor's burst of writes (or a build's) restarts the program once.
  local pending: {string} = nil
  launch()
  while guard:cancelled() == 0 do
    if handle ~= nil then
      local done, _ = Child.wait_any({ handle }, interval_ns)
      if done ~= nil then
        local result, _ = handle:wait()
        local _, _ = handle:close()
        handle = nil
        log("web dev: the program " .. (result ~= nil and ended(result) or "is gone") ..
            "; waiting for a change")
      end
    else
      local _, _ = Clock.sleep_ns(interval_ns)
    end
    local now, _ = scan(roots, ignored)
    if now ~= nil then
      local paths = changed(seen, now)
      seen = now
      if #paths > 0 then
        pending = pending or paths
      elseif pending ~= nil then
        local moved = pending
        pending = nil
        log(("web dev: %s changed; restarting"):format(moved[1] .. (#moved > 1 and (" and %d more"):format(#moved - 1) or "")))
        halt()
        launch()
      end
    end
    if given.stop ~= nil and given.stop() then break end
  end
  halt()
  assert(guard:release())
  return true, ""
end

return Dev
