--- Limits failed attempts, such as wrong passwords or one-time codes, for
--- a [`cosmic.web`] app: after `limit` failures for one key within
--- `window_ns`, that key is refused until the oldest of them is
--- `window_ns` old. It lives in memory, so a restart forgets it, and each
--- process of an app keeps its own.
---
---     local login = Attempts.limiter{ limit = 5, window_ns = Clock.minutes(5) }
---
---     -- in the handler, after reading the form:
---     local key = req.client and req.client.host or "-"
---     local wait_ns = login:wait_ns(key)
---     if wait_ns > 0 then return Attempts.too_many(wait_ns) end
---     if not good_password(form) then
---       login:failed(key)
---       return Web.abort(401)
---     end
---     login:reset(key)
---
--- The key is what is limited, and choosing it is the trade-off:
---
--- - **One key for everything** (`"login"`) stops a guesser however many
---   addresses it has, but anyone can lock everyone out by failing
---   `limit` times a window. It fits an app with a few known users and a
---   second way in.
--- - **The client's address** (`req.client.host`) locks out the guesser
---   alone, but one with many addresses gets `limit` tries from each
---   (an IPv6 host often holds a whole /64). Behind a proxy every request
---   comes from the proxy's address, one key for everyone, unless the app
---   sets `trusted_proxy`; set it only where clients cannot reach the app
---   past the proxy, or they choose their own key.
--- - **The account name** limits guesses at one account from anywhere,
---   and lets anyone lock that account out.
---
--- Keys can be combined: check an address key and an account key, and
--- record a failure under both.
---
--- Asking ([`Attempts.Limiter.wait_ns`], `allowed`) is a check, not a
--- reservation: requests that wait on the run between asking and
--- `failed` (reading a body, a network call) each see the count from
--- before the others failed. Read the input first, then ask, check the
--- secret and record, with no wait in between.
---
--- Memory is bounded: a key holds at most `limit` times, and at most
--- `max_keys` keys are kept. A new key that would pass `max_keys` first
--- drops every key whose failures have all aged out, then, if none has,
--- the eighth of them whose newest failures are oldest. So `max_keys`
--- failures under new keys (made-up account names, many addresses) free
--- a refused key and start its count over: limit an account key together
--- with an address key, or raise `max_keys` past what a guesser can
--- send in a window. With a single key nothing is ever dropped.
--- @public

local Clock = require("cosmic.clock")
local Response = require("cosmic.web.response")
local Types = require("cosmic.web.types")

local record Attempts
  --- What [`Attempts.limiter`] takes.
  record Options
    --- The failures one key may have within `window_ns`; the next attempt
    --- is refused. At least 1.
    limit: integer
    --- How long a failure counts, in nanoseconds. At least 1.
    window_ns: integer
    --- The most keys kept at once (10000). At least 1.
    max_keys?: integer
    --- The clock, in nanoseconds ([`Clock.monotonic_ns`]); a test passes
    --- its own. A reading below an earlier one is taken as the earlier.
    now_ns?: function(): integer
  end

  --- Counts the failures of each key: made by [`Attempts.limiter`].
  interface Limiter
    --- The failures one key may have within `window_ns`.
    limit: integer
    --- How long a failure counts, in nanoseconds.
    window_ns: integer
    --- Whether `key` may make an attempt now. Asking records nothing.
    allowed: function(Limiter, key: string): boolean
    --- How long until `key` may make an attempt, in nanoseconds: 0 when
    --- it may now. Asking records nothing.
    wait_ns: function(Limiter, key: string): integer
    --- Records a failed attempt for `key` now. Record only an attempt
    --- that `allowed` let through: one recorded while refused pushes the
    --- refusal later.
    failed: function(Limiter, key: string)
    --- Forgets `key`'s failures, as after a success.
    reset: function(Limiter, key: string)
  end
end

local DEFAULT_MAX_KEYS <const> = 10000

local class Tracked is Attempts.Limiter
  limit: integer
  window_ns: integer
  max_keys: integer
  clock: function(): integer
  --- The latest reading of `clock`, which a reading below it is raised to.
  mut last: integer
  --- Each key's failure times, oldest first; never empty.
  times: mut {string: {integer}}
  --- How many keys `times` holds.
  mut count: integer

  --- The clock, held from going backwards so the times stay in order.
  function tick(self): integer
    local now = math.max(self.clock(), self.last)
    self.last = now
    return now
  end

  --- Forgets `key`, which `times` holds.
  function drop(self, key: string)
    self.times[key] = nil
    self.count = self.count - 1
  end

  --- `key`'s failure times within the window, oldest first, or nil (and
  --- the key forgotten) when none is left. `now - at` cannot overflow, as
  --- no time is after `now`.
  function live(self, key: string, now: integer): {integer}?
    local list = self.times[key]
    if list == nil then return nil end
    if now - assert(list[1]) < self.window_ns then return list end
    if now - assert(list[#list]) >= self.window_ns then
      self:drop(key)
      return nil
    end
    local kept: mut {integer} = {}
    for _, at in ipairs(list) do
      if now - at < self.window_ns then kept[#kept + 1] = at end
    end
    self.times[key] = kept
    return kept
  end

  --- Brings the count of keys below `max_keys`: by dropping those that
  --- have aged out, else the eighth (at least one) whose newest failures
  --- are oldest, so a flood of new keys pays for a sweep once in
  --- `max_keys / 8` of them.
  function make_room(self, now: integer)
    local keys: mut {string} = {}
    for key in pairs(self.times) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do self:live(key, now) end
    if self.count < self.max_keys then return end
    local newest: mut {string: integer} = {}
    local held: mut {string} = {}
    for key, list in pairs(self.times) do
      newest[key] = assert(list[#list])
      held[#held + 1] = key
    end
    table.sort(held, function(x: string, y: string): boolean
      local nx, ny = assert(newest[x]), assert(newest[y])
      if nx ~= ny then return nx < ny end
      return x < y
    end)
    for i = 1, math.max(1, self.max_keys // 8) do
      local key = held[i]
      if key == nil then break end
      self:drop(key)
    end
  end

  function wait_ns(self, key: string): integer
    local now = self:tick()
    local list = self:live(key, now)
    if list == nil or #list < self.limit then return 0 end
    -- Written so as not to overflow: `now - list[1]` is below the window.
    return self.window_ns - (now - assert(list[1]))
  end

  function allowed(self, key: string): boolean
    return self:wait_ns(key) == 0
  end

  function failed(self, key: string)
    local now = self:tick()
    local list = self:live(key, now)
    local kept: mut {integer} = {}
    if list == nil then
      if self.count >= self.max_keys then self:make_room(now) end
      self.count = self.count + 1
    else
      local from = math.max(1, #list - self.limit + 2)
      for i = from, #list do kept[#kept + 1] = assert(list[i]) end
    end
    kept[#kept + 1] = now
    self.times[key] = kept
  end

  function reset(self, key: string)
    if self.times[key] ~= nil then self:drop(key) end
  end
end

--- `value` when it is an integer of at least 1; raises naming `name`.
local function positive(value: integer, name: string): integer
  if math.type(value) ~= "integer" or value < 1 then
    error(("attempts: %s must be an integer of at least 1"):format(name), 3)
  end
  return value
end

--- A limiter that refuses a key after `opts.limit` failures within
--- `opts.window_ns`, until the oldest of them ages out: see this module's
--- description for choosing the key. Make one per thing limited (login,
--- one-time codes), when the app is built, and share it between requests.
--- Raises, naming the option, for a limit, window or `max_keys` that is
--- not an integer of at least 1.
--- @param opts Attempts.Options How many failures, and for how long
--- @return Attempts.Limiter The limiter
function Attempts.limiter(opts: Attempts.Options): Attempts.Limiter
  local made: Tracked = {
    limit = positive(opts.limit, "limit"),
    window_ns = positive(opts.window_ns, "window_ns"),
    max_keys = positive(opts.max_keys or DEFAULT_MAX_KEYS, "max_keys"),
    clock = opts.now_ns or Clock.monotonic_ns,
    last = math.mininteger, times = {}, count = 0,
  }
  return made
end

--- A `Retry-After` value for a wait of `wait_ns`: whole seconds, rounded
--- up, at least 1.
--- @param wait_ns integer The wait, in nanoseconds
--- @return string The header's value
function Attempts.retry_after(wait_ns: integer): string
  return tostring(math.max(1, Clock.ceil(wait_ns, Clock.seconds(1))))
end

--- A 429 problem reply ([`Web.problem`]) with `Retry-After` for a wait of
--- `wait_ns`, as [`Attempts.Limiter.wait_ns`] answers it. A page that
--- shows a form again instead sets the status and header on its own reply:
--- `Web.html(page, { status = 429, headers = { ["Retry-After"] =
--- Attempts.retry_after(wait_ns) } })`.
--- @param wait_ns integer How long until another attempt is allowed
--- @param detail string | nil What to tell the client
--- @return Types.Response The reply
function Attempts.too_many(wait_ns: integer, detail?: string): Types.Response
  local res = Response.problem(429, detail or "Too many failed attempts; try again later.")
  Response.set_header(res, "Retry-After", Attempts.retry_after(wait_ns))
  return res
end

return Attempts
