--- Tasks that wait on descriptors and time together: many functions
--- running in one thread, each running until it waits, while the others
--- run in turn -- the loop a server serves many connections on.
---
---     Poll.run(function()
---       local worker = Poll.spawn(function()
---         assert(Poll.readable(fd, Clock.seconds(5)))
---         print(sys.read(fd, 4096))
---       end)
---       assert(worker:join())
---     end)
---
--- [`Poll.run`] runs its function as the first task, and returns once every
--- task has ended. A task waits by calling `wait` (`readable` and
--- `writable` are calls to it), `delay` or a Task's `join`, each of which
--- answers true and "" once what it waits for happens, or false and
--- [`Poll.TIMEOUT`] once its `timeout_ns` passes first, or false and
--- [`Poll.CANCELLED`] once the task is cancelled; `ready` waits on
--- several descriptors at once, and answers what each had, as
--- [`sys.poll`] does, or nil and the same two words; a Task's `kill`
--- ends one outright, for a task that goes on after its waits fail.
--- `wait` is the one that goes on where there is no task to wait in --
--- outside a run, in a coroutine of its own, in a finalizer -- holding
--- the thread in [`sys.poll`] until it answers, so a module waits with
--- one call wherever it runs; the others raise there. In a `<close>`
--- handler of a task the run ends, `wait` raises too. Nothing else
--- here waits: a call that blocks the thread (a blocking read,
--- [`Http.get`], a SQLite query) holds every task until it returns.
---
--- An error a task raises ends [`Poll.run`] at once: every other task is
--- closed where it waits, its `<close>` variables closed, and `run`
--- raises the error -- a message with the task's stack beneath it,
--- which the run's own stack would not show. A task that must go on
--- after a failure catches it itself.

local Clock = require("cosmic.clock")
local errors = require("cosmic.internal.errors")
local sys = require("cosmic.sys")

local record Poll
  --- A function running under [`Poll.run`] beside the others, answered by
  --- [`Poll.spawn`].
  interface Task
    --- Waits for the task to end, at most `timeout_ns` nanoseconds (no
    --- limit when nil): true and "" once it has returned, false and
    --- [`Poll.TIMEOUT`] or [`Poll.CANCELLED`] otherwise -- CANCELLED, too, for
    --- a task killed, or one a failed run closed where it waited.
    join: function(Task, timeout_ns?: integer): boolean, string
    --- Ends the task at its next wait: the wait it is in, if any, and
    --- every one after, answers false and [`Poll.CANCELLED`] at once --
    --- but for one in [`Poll.shielded`], which waits on as though the
    --- task were not cancelled. A task that has ended is left alone.
    cancel: function(Task)
    --- Ends the task now, where it waits or before it starts, without
    --- resuming it: the pending `<close>` variables of its own coroutine
    --- are closed (not those of a coroutine it made and left
    --- suspended), none of its waits answers it again, and each task
    --- joining it answers false and [`Poll.CANCELLED`]. A task that has
    --- ended is left alone. Unlike `cancel`, it is called from a task's
    --- own coroutine, and raises elsewhere in the run, and in the task
    --- it would kill. A `<close>` handler of a task being killed cannot
    --- wait, spawn or kill: each raises at once, and [`Poll.in_task`]
    --- still answers true there, so a module that waits raises rather
    --- than hold the thread. What such a handler raises, `kill` raises,
    --- the task ended all the same -- an error in the killing task,
    --- which ends the run unless that task catches it. Only a task that
    --- waits can be killed: one that computes without waiting holds the
    --- run, and every other task, until it waits.
    kill: function(Task)
  end

  --- What a wait answers once its `timeout_ns` passes first: the one
  --- word every module that waits answers, [`cosmic.child`] and
  --- [`cosmic.net`] included.
  TIMEOUT: string
  --- What a wait answers once its task is cancelled.
  CANCELLED: string
  --- The longest wait [`sys.poll`] takes, in nanoseconds, and so the
  --- longest timeout any wait here, in [`cosmic.child`] and in
  --- [`cosmic.net`] takes: 2^31-1 milliseconds, about 24 days.
  MOST_NS: integer
end

Poll.TIMEOUT = "timed out"
Poll.CANCELLED = "cancelled"

Poll.MOST_NS = Clock.ms(0x7fffffff)
--- One millisecond, which [`sys.poll`] counts its waits in.
local MS <const> = Clock.ms(1)
--- The highest descriptor [`sys.poll`] takes: a C `int`.
local MOST_FD <const> = 0x7fffffff
--- What [`sys.poll`] answers of a descriptor whether asked or not.
local UNASKED <const> = sys.POLLERR | sys.POLLHUP | sys.POLLNVAL
--- How many done waits the timer heap holds before it is rebuilt
--- without them, however few are live: rebuilding a small heap saves
--- nothing.
local STALE_FLOOR <const> = 64

--- One wait a task is parked in, and what ends it: a descriptor ready, a
--- time reached, a task joined. `done` is set once one of them has
--- answered it, so the others that still hold it pass it by.
local record Wait
  task: State
  fd: integer
  events: integer
  --- For a wait on several descriptors ([`Poll.ready`]) in place of
  --- `fd` and `events`: each descriptor, its events, and what happened
  --- to it, by place.
  fds: {integer}
  masks: {integer}
  answers: {integer}
  --- Its descriptors' entries among the run's, while it waits on them.
  watches: {Watch}
  at: integer
  --- When it began among the run's waits: the order those a poll
  --- answers together are woken in, and the tie-break between timers.
  seq: integer
  --- Set while it is in the run's `timers`, done or not.
  in_heap: boolean
  --- The task a join waits on.
  joined: State
  --- Set once a poll, or a descriptor closing, has answered it.
  hit: boolean
  --- What the wait answers once `at` is reached: a delay's success, or
  --- a `ready`'s, which answers no descriptor ready; any other wait's
  --- TIMEOUT.
  expiry_ok: boolean
  done: boolean
end

--- One descriptor of a wait, among the waits on that descriptor.
local record Watch
  wait: Wait
  fd: integer
  mask: integer
  --- Its place among the wait's `fds`, 0 for a wait on one descriptor.
  place: integer
  --- Its place in its descriptor's `watches`.
  index: integer
end

--- A descriptor the run polls, and every wait on it.
local record Watched
  --- Its place in the run's `fds` and `events`.
  slot: integer
  watches: {Watch}
  --- How many of `watches` ask each mask: the descriptor's events are
  --- their union.
  masks: {integer:integer}
end

-- How a task is made. What a run keeps of a task is one record, which is
-- also the handle `spawn` answers, so a task costs one table and no
-- closure: its methods are defined once, on the record's own table, which
-- a task reaches through `__index`, and its state is in fields. The
-- note on how an object is made in cosmic/stream.tl says why Teal
-- makes the public type an interface ([`Poll.Task`]) and the record
-- implement it, and how the constructor is written.

--- What a run keeps of a task, which `spawn` answers.
local record State is Poll.Task
  co: thread
  --- The run the task belongs to: a handle kept past it answers as a
  --- task that has ended.
  loop: Loop
  started: boolean
  --- Set while the task is yielded in one of this module's waits.
  waiting: boolean
  ended: boolean
  --- Set for a task killed, or one a failed run closed where it waited.
  killed: boolean
  cancelled: boolean
  --- How many [`Poll.shielded`] calls the task is in: while any, a
  --- cancel answers none of its waits.
  shields: integer
  parked: Wait
  joiners: {Wait}
  join: function(State, timeout_ns?: integer): boolean, string
  cancel: function(State)
  kill: function(State)
end

local state_mt: metatable<State> = { __index = State }

--- A task to resume, with what its wait answers.
local record Wake
  task: State
  ok: boolean
  why: string
end

--- A [`Poll.shielded`] call's hold on its task, let go as the call
--- returns or raises, or as its task is closed.
local record Shielding
  task: State
  metamethod __close: function(Shielding)
end

--- A run's state while [`Poll.run`] runs; nil otherwise.
local record Loop
  tasks: {thread: State}
  live: integer
  ready: {Wake}
  --- What [`sys.poll`] is handed, kept as waits begin and end: each
  --- descriptor waited on, and the union of the events its waits ask,
  --- by slot.
  fds: {integer}
  events: {integer}
  watched: {integer:Watched}
  --- Time waits, a binary heap on `at` then `seq`.
  timers: {Wait}
  --- How many of `timers` are done: each leaves only on reaching the
  --- top, or when the heap is rebuilt without them.
  stale: integer
  seq: integer
  --- Set while the run closes its tasks, when nothing may start or wait.
  closing: boolean
end

local loop: Loop = nil

local function earlier(a: Wait, b: Wait): boolean
  if a.at ~= b.at then return a.at < b.at end
  return a.seq < b.seq
end

local function heap_push(heap: {Wait}, w: Wait)
  heap[#heap + 1] = w
  local i = #heap
  while i > 1 do
    local parent = i // 2
    if not earlier(heap[i], heap[parent]) then break end
    heap[i], heap[parent] = heap[parent], heap[i]
    i = parent
  end
end

local function sift_down(heap: {Wait}, i: integer)
  while true do
    local l, r, least = 2 * i, 2 * i + 1, i
    if l <= #heap and earlier(heap[l], heap[least]) then least = l end
    if r <= #heap and earlier(heap[r], heap[least]) then least = r end
    if least == i then return end
    heap[i], heap[least] = heap[least], heap[i]
    i = least
  end
end

--- Takes the nearest wait from the run's timers.
local function pop_timer(): Wait
  local heap = loop.timers
  local top = heap[1]
  local last = table.remove(heap)
  if #heap > 0 then
    heap[1] = last
    sift_down(heap, 1)
  end
  top.in_heap = false
  if top.done then loop.stale = loop.stale - 1 end
  return top
end

--- Rebuilds the run's timers from the waits not done. `at` then `seq`
--- orders every pair of waits, so the rebuilt heap answers in the same
--- order the old one would have.
local function compact_timers()
  local heap, kept = loop.timers, 0
  for i = 1, #heap do
    local w = heap[i]
    if w.done then
      w.in_heap = false
    else
      kept = kept + 1
      heap[kept] = w
    end
  end
  for i = #heap, kept + 1, -1 do heap[i] = nil end
  loop.stale = 0
  for i = kept // 2, 1, -1 do sift_down(heap, i) end
end

--- Enters `w`'s wait on `fd` for `mask` among the waits on `fd`, whose
--- polled events take in `mask`.
local function enter(w: Wait, fd: integer, mask: integer, place: integer)
  local entry = loop.watched[fd]
  if entry == nil then
    local slot = #loop.fds + 1
    entry = { slot = slot, watches = {}, masks = {} }
    loop.fds[slot], loop.events[slot] = fd, 0
    loop.watched[fd] = entry
  end
  local watch: Watch = { wait = w, fd = fd, mask = mask, place = place, index = #entry.watches + 1 }
  entry.watches[watch.index] = watch
  entry.masks[mask] = (entry.masks[mask] or 0) + 1
  loop.events[entry.slot] = loop.events[entry.slot] | mask
  w.watches[#w.watches + 1] = watch
end

--- Takes `watch` from among the waits on its descriptor, and the
--- descriptor from what is polled once none is left.
local function leave(watch: Watch)
  local fd = watch.fd
  local entry = loop.watched[fd]
  local watches = entry.watches
  local last = watches[#watches]
  watches[watch.index], last.index = last, watch.index
  watches[#watches] = nil
  if #watches == 0 then
    local slot, top = entry.slot, #loop.fds
    local moved = loop.fds[top]
    loop.fds[slot], loop.events[slot] = moved, loop.events[top]
    loop.watched[moved].slot = slot
    loop.fds[top], loop.events[top] = nil, nil
    loop.watched[fd] = nil
    return
  end
  local left = entry.masks[watch.mask] - 1
  if left > 0 then
    entry.masks[watch.mask] = left
    return
  end
  entry.masks[watch.mask] = nil
  local events = 0
  for mask in pairs(entry.masks) do events = events | mask end
  loop.events[entry.slot] = events
end

--- Takes a join's wait from the joiners of the task it waits on, the
--- rest left in their order.
local function unjoin(w: Wait)
  local joiners = w.joined.joiners
  for i = #joiners, 1, -1 do
    if joiners[i] == w then
      table.remove(joiners, i)
      return
    end
  end
end

--- Marks `w` answered: it leaves what is polled now, and the joiners of
--- a task still running; and the timer heap once it reaches the top,
--- or once the done waits there outnumber the live ones and the heap is
--- rebuilt without them.
local function finish(w: Wait)
  w.done = true
  -- A task that has ended answers its joiners while it walks them, and
  -- is marked ended first, so none is taken from under the walk.
  if w.joined ~= nil and not w.joined.ended then unjoin(w) end
  if w.watches ~= nil then
    for _, watch in ipairs(w.watches) do leave(watch) end
    w.watches = nil
  end
  if w.in_heap then
    loop.stale = loop.stale + 1
    if loop.stale > STALE_FLOOR and loop.stale * 2 > #loop.timers then compact_timers() end
  end
end

--- Answers `w`, once: the run resumes its task with `ok` and `why`.
local function wake(w: Wait, ok: boolean, why: string)
  if w.done then return end
  finish(w)
  w.task.parked = nil
  loop.ready[#loop.ready + 1] = { task = w.task, ok = ok, why = why }
end

local function began_first(a: Wait, b: Wait): boolean
  return a.seq < b.seq
end

--- Answers each of `hits` ready, in the order they began.
local function wake_hits(hits: {Wait})
  table.sort(hits, began_first)
  for _, w in ipairs(hits) do wake(w, true, "") end
end

--- The task the calling coroutine is, raising at `level` where there is
--- none: a wait outside [`Poll.run`], in a coroutine a task made of its
--- own, or while the run closes its tasks.
local function current(what: string, level: integer): State
  if loop == nil then error("poll: " .. what .. " outside Poll.run", level + 1) end
  if loop.closing then error("poll: " .. what .. " while Poll.run closes its tasks", level + 1) end
  local task = loop.tasks[coroutine.running()]
  if task == nil then error("poll: " .. what .. " outside a task's own coroutine", level + 1) end
  if task.killed then error("poll: " .. what .. " while its task is killed", level + 1) end
  return task
end

--- Raises "`module`: `name` must be ...", `name` the argument or field
--- and `module` the one that reads it ("net", "timeout_ns"), at `level`
--- as `error` takes it in the
--- function that calls this (1 is that function, 2 its caller), unless
--- `value` is nil or an integer from 0 to [`Poll.MOST_NS`]: what every
--- `timeout_ns` is held to, so a field or argument set wrong is named
--- where it is read.
function Poll.checked_ns(value: any, module: string, name: string, level: integer)
  if value == nil then return end
  if not (value is integer and value >= 0 and value <= Poll.MOST_NS) then
    error(module .. ": " .. name .. " must be nil or an integer from 0 to " .. Poll.MOST_NS,
      level + 1)
  end
end

--- Parks `task` in `w`, bounded by `timeout_ns`, and answers what ends
--- it. A cancelled task still yields, answered at once, so a task that
--- waits in a loop lets the others run.
local function park(task: State, w: Wait, timeout_ns: integer | nil): boolean, string
  task.parked = w
  loop.seq = loop.seq + 1
  w.seq = loop.seq
  if task.cancelled and task.shields == 0 then
    wake(w, false, Poll.CANCELLED)
  else
    if w.fd ~= nil then
      w.watches = {}
      enter(w, w.fd, w.events, 0)
    elseif w.fds ~= nil then
      w.watches = {}
      for place, fd in ipairs(w.fds) do enter(w, fd, w.masks[place], place) end
    end
    if timeout_ns ~= nil then
      w.at, w.in_heap = Clock.monotonic_ns() + timeout_ns, true
      heap_push(loop.timers, w)
    end
  end
  task.waiting = true
  local ok, why = coroutine.yield(w)
  task.waiting = false
  if not w.done then error("poll: a task was resumed other than by Poll.run", 2) end
  if ok == true then return true, "" end
  if ok == false and why is string then return false, why end
  error("poll: a task was resumed other than by Poll.run", 2)
end

--- The task the calling coroutine is, for a wait that goes on without
--- one: nil where there is none -- outside a run, in a coroutine a task
--- made of its own, or where the task cannot yield (a finalizer).
--- Raises at `level` for a task whose `<close>` handler is running, as
--- the run closes its tasks or one is killed: nothing may wait there.
local function waiting_task(what: string, level: integer): State | nil
  if loop == nil then return nil end
  local task = loop.tasks[coroutine.running()]
  if task == nil then return nil end
  if loop.closing then error("poll: " .. what .. " while Poll.run closes its tasks", level + 1) end
  if task.killed then error("poll: " .. what .. " while its task is killed", level + 1) end
  if not coroutine.isyieldable() then return nil end
  return task
end

--- Checks a descriptor: the caller's `fd`, or `fds[place]`, raising at
--- `level` above this function's caller.
local function checked_fd(fd: any, name: string, level: integer)
  if not (fd is integer and fd >= 0 and fd <= MOST_FD) then
    error("poll: " .. name .. " must be a descriptor", level + 1)
  end
end

--- Checks a mask of POLL* events, as [`checked_fd`] does.
local function checked_events(mask: any, name: string, level: integer)
  if not (mask is integer and mask >= 0 and mask <= 0x7fff) then
    error("poll: " .. name .. " must be a mask of POLL* events", level + 1)
  end
end

--- `timeout_ns`, which [`Poll.checked_ns`] has held to what a wait can
--- last, as [`sys.poll`] and the raw socket calls count it: in whole
--- milliseconds rounded up so a wait with time left never polls for none,
--- or -1 for no limit.
function Poll.milliseconds(timeout_ns: integer | nil): integer
  if timeout_ns == nil then return -1 end
  return Clock.ceil(timeout_ns, MS)
end

--- Waits for `fd` to have `events` through the run's task, or, for a
--- caller that is none, by holding the thread in [`sys.poll`]. The
--- wait goes on past a signal, which ends [`sys.poll`] early with
--- nothing ready.
local function wait_on(fd: integer, events: integer, timeout_ns: integer | nil,
                       what: string): boolean, string
  Poll.checked_ns(timeout_ns, "poll", "timeout_ns", 3)
  checked_fd(fd, "fd", 3)
  checked_events(events, "events", 3)
  local task = waiting_task(what, 3)
  if task ~= nil then
    return park(task, { task = task, fd = fd, events = events }, timeout_ns)
  end
  local deadline = timeout_ns ~= nil and Clock.monotonic_ns() + timeout_ns or nil
  while true do
    local left = deadline ~= nil and math.max(deadline - Clock.monotonic_ns(), 0) or nil
    local revents, trouble = sys.poll({ fd }, { events }, Poll.milliseconds(left))
    if revents == nil then return false, trouble end
    if revents[1] ~= 0 then return true, "" end
    if deadline ~= nil and Clock.monotonic_ns() >= deadline then return false, Poll.TIMEOUT end
  end
end

--- Waits until `fd` has any of `events` ([`sys.POLLIN`], [`sys.POLLOUT`])
--- or has failed, at most `timeout_ns` nanoseconds (no limit when nil):
--- true and "" once it has, false and [`Poll.TIMEOUT`] once `timeout_ns`
--- passes first, false and [`Poll.CANCELLED`] once the task is cancelled,
--- or false and why the descriptor could not be waited on. In a task
--- the other tasks run meanwhile. A caller that is none holds the thread:
--- one [`sys.poll`] for the whole time left, called again only where it
--- returns early with nothing ready (a signal). With no `timeout_ns`,
--- then, nothing ends the wait but the descriptor, a signal a
--- [`Child.guard`] caught included; a caller that needs one to break it
--- waits as [`cosmic.net`] does outside a task, in the core's own wait.
--- In a `<close>` handler of a task the run is ending -- killed, or
--- closed as the run fails -- it raises, as every wait but a finalizer's
--- does: such a handler must not hold the thread.
function Poll.wait(fd: integer, events: integer, timeout_ns?: integer): boolean, string
  return wait_on(fd, events, timeout_ns, "Poll.wait")
end

--- Waits until `fd` can be read without waiting -- data, the end of what
--- the peer sends, a connection to accept, or an error to read -- at most
--- `timeout_ns` nanoseconds (no limit when nil): [`Poll.wait`] for
--- [`sys.POLLIN`].
function Poll.readable(fd: integer, timeout_ns?: integer): boolean, string
  return wait_on(fd, sys.POLLIN, timeout_ns, "Poll.readable")
end

--- Waits until `fd` can be written without waiting, or has failed, at
--- most `timeout_ns` nanoseconds (no limit when nil): [`Poll.wait`] for
--- [`sys.POLLOUT`].
function Poll.writable(fd: integer, timeout_ns?: integer): boolean, string
  return wait_on(fd, sys.POLLOUT, timeout_ns, "Poll.writable")
end

--- Waits until any of `fds` is ready for its mask of `events`
--- ([`sys.POLLIN`], [`sys.POLLOUT`]), at most `timeout_ns` nanoseconds
--- (no limit when nil), as [`sys.poll`] does: the events each descriptor
--- had, by its place -- [`sys.POLLERR`] and [`sys.POLLHUP`] among them,
--- unasked -- or nil and [`Poll.TIMEOUT`] once `timeout_ns` passes
--- first, as [`Poll.readable`] fails, or nil and [`Poll.CANCELLED`] once
--- the task is cancelled. A descriptor another module is about to close
--- ([`Poll.closing`]) answers [`sys.POLLNVAL`].
function Poll.ready(fds: {integer}, events: {integer}, timeout_ns?: integer): {integer} | nil, string
  local task = current("Poll.ready", 2)
  Poll.checked_ns(timeout_ns, "poll", "timeout_ns", 2)
  if #fds == 0 or #events ~= #fds then
    error("poll: Poll.ready takes one or more descriptors, and events for each", 2)
  end
  local watched, masks, answers: {integer}, {integer}, {integer} = {}, {}, {}
  for i, fd in ipairs(fds) do
    local mask = events[i]
    checked_fd(fd, "fds[" .. i .. "]", 2)
    checked_events(mask, "events[" .. i .. "]", 2)
    watched[i], masks[i], answers[i] = fd, mask, 0
  end
  local ok, why = park(task,
    { task = task, fds = watched, masks = masks, answers = answers }, timeout_ns)
  if not ok then return nil, why end
  return answers, ""
end

--- Waits `ns` nanoseconds while the other tasks run: true and "" once
--- they have passed, false and [`Poll.CANCELLED`] once the task is
--- cancelled first.
function Poll.delay(ns: integer): boolean, string
  local task = current("Poll.delay", 2)
  if ns == nil then error("poll: ns must be an integer from 0 to " .. Poll.MOST_NS, 2) end
  Poll.checked_ns(ns, "poll", "ns", 2)
  return park(task, { task = task, expiry_ok = true }, ns)
end

--- Ends `task`, suspended, as a Task's `kill` says: its wait is marked
--- answered and its wakes taken from the ready queue, so nothing resumes
--- it, and it is settled as ended before what its closing raised is
--- raised.
local function close_task(task: State)
  task.killed = true
  if task.parked ~= nil then
    finish(task.parked)
    task.parked = nil
  end
  local ready: {Wake} = {}
  for _, wakened in ipairs(loop.ready) do
    if wakened.task ~= task then ready[#ready + 1] = wakened end
  end
  loop.ready = ready
  local closed, err: boolean, any = coroutine.close(task.co)
  task.ended = true
  loop.tasks[task.co] = nil
  loop.live = loop.live - 1
  for _, w in ipairs(task.joiners) do wake(w, false, Poll.CANCELLED) end
  if not closed then error(err, 0) end
end

function State:join(timeout_ns?: integer): boolean, string
  local task = current("Task:join", 2)
  Poll.checked_ns(timeout_ns, "poll", "timeout_ns", 2)
  if self.killed then return false, Poll.CANCELLED end
  if self.ended or self.loop ~= loop then return true, "" end
  if self == task then error("poll: a task cannot join itself", 2) end
  local w: Wait = { task = task, joined = self }
  self.joiners[#self.joiners + 1] = w
  return park(task, w, timeout_ns)
end

function State:cancel()
  if self.loop ~= loop or self.ended or self.cancelled then return end
  self.cancelled = true
  if self.parked ~= nil and self.shields == 0 then wake(self.parked, false, Poll.CANCELLED) end
end

function State:kill()
  if self.loop ~= loop or self.ended then return end
  if self == current("Task:kill", 2) then error("poll: a task cannot kill itself", 2) end
  close_task(self)
end

--- A new task running `fn`, ready to run.
local function start(fn: function()): Poll.Task
  local state: State = setmetatable({
    co = coroutine.create(fn), loop = loop, started = false, waiting = false,
    ended = false, killed = false, cancelled = false, shields = 0, joiners = {} }, state_mt)
  loop.tasks[state.co] = state
  loop.live = loop.live + 1
  loop.ready[#loop.ready + 1] = { task = state, ok = true, why = "" }
  return state
end

local shielding_mt: metatable<Shielding> = {
  __close = function(held: Shielding)
    held.task.shields = held.task.shields - 1
  end,
}

--- Calls `fn` in the calling task with its waits shielded from a
--- cancel: one that comes meanwhile answers none of them, nor the
--- waits `fn` begins after it, which each wait for what they wait for.
--- Once `fn` returns, the task's next wait answers [`Poll.CANCELLED`] at
--- once, as a cancelled task's do. It is for a cleanup that must wait --
--- a child to be ended, a peer to read its last bytes -- while the other
--- tasks run. A kill still ends the task, and a failed run still closes
--- it, where it waits in `fn`; a shield whose `fn` never returns leaves
--- only those to end it. What `fn` raises, it raises.
function Poll.shielded(fn: function())
  local task = current("Poll.shielded", 2)
  if type(fn) ~= "function" then error("poll: Poll.shielded takes a function", 2) end
  -- Made before the count moves, so a refused allocation leaves it be.
  local held: Shielding = { task = task }
  local _held <close> = setmetatable(held, shielding_mt)
  task.shields = task.shields + 1
  fn()
end

--- Starts `fn` as a task of its own, run once the calling task waits.
function Poll.spawn(fn: function()): Poll.Task
  current("Poll.spawn", 2)
  if type(fn) ~= "function" then error("poll: Poll.spawn takes a function", 2) end
  return start(fn)
end

--- Ends every task where it waits, closing its pending `<close>`
--- variables, and marks each ended, so a handle kept past the run
--- answers as one. What a `<close>` handler raises is dropped: the run
--- is already ending with an error of its own.
local function close_all()
  loop.closing = true
  local cos: {thread} = {}
  for co in pairs(loop.tasks) do cos[#cos + 1] = co end
  for _, co in ipairs(cos) do
    local task = loop.tasks[co]
    task.ended, task.killed, task.parked = true, true, nil
    if coroutine.status(co) == "suspended" then
      local _, _ = coroutine.close(co)
    end
  end
end

--- Resumes `task` with a wait's answer and settles what it did next:
--- ended, parked in a wait, or raised.
local function step(task: State, ok: boolean, why: string)
  local resumed, err: boolean, any
  if task.started then
    resumed, err = coroutine.resume(task.co, ok, why)
  else
    task.started = true
    resumed, err = coroutine.resume(task.co)
  end
  if not resumed then
    -- The stack the error was raised from is the task's, which resume
    -- leaves in place until the coroutine is closed.
    -- A message that already carries a stack keeps its own. The trace
    -- can fail (no memory for it), and the close below must still run.
    if err is string and not err:find("\nstack traceback:", 1, true) then
      local traced, text = pcall(errors.trace_of, task.co, err)
      if traced then err = text end
    end
    -- resume leaves a coroutine that raised with its `<close>` variables
    -- open: close answers the error again, which is already in hand.
    local _, _ = coroutine.close(task.co)
    error(err, 0)
  end
  if coroutine.status(task.co) == "dead" then
    task.ended = true
    loop.tasks[task.co] = nil
    loop.live = loop.live - 1
    for _, w in ipairs(task.joiners) do wake(w, true, "") end
  elseif not task.waiting then
    error("poll: a task yielded other than through cosmic.poll", 0)
  end
end

--- How long the next `poll` may wait, in the milliseconds [`sys.poll`]
--- counts, rounded up so a wait with time left never polls for none: 0
--- while a task is ready, until the nearest time wait, or -1 for no limit.
local function next_timeout(): integer
  if #loop.ready > 0 then return 0 end
  while #loop.timers > 0 and loop.timers[1].done do pop_timer() end
  if #loop.timers == 0 then return -1 end
  local left = loop.timers[1].at - Clock.monotonic_ns()
  if left <= 0 then return 0 end
  return math.min(Clock.ceil(left, MS), Clock.ceil(Poll.MOST_NS, MS))
end

--- Waits on every watched descriptor for as long as `timeout`, and
--- answers each wait whose descriptor is ready, or in error or hung up,
--- which its read or write then reports. A descriptor is polled once
--- for the union of what its waits ask; each wait is answered only the
--- events it asked for, and those three, as an entry of its own would
--- be.
local function poll_once(timeout: integer)
  if #loop.fds == 0 and timeout < 0 then
    error("poll: every task waits on another: none can go on", 0)
  end
  -- A signal a Child.guard catches only cuts this poll short, and the
  -- loop waits on: what one means -- end every wait, or stop taking
  -- work and drain it, as Net.serve does -- is the run's to say, by a
  -- task that waits on the guard (`g:wait`).
  local revents, trouble = sys.poll(loop.fds, loop.events, timeout)
  if revents == nil then error("poll: " .. trouble, 0) end
  -- Every descriptor of a wait is recorded before any wait is answered,
  -- which changes what is polled.
  local hits: {Wait} = {}
  for slot, happened in ipairs(revents) do
    if happened ~= 0 then
      for _, watch in ipairs(loop.watched[loop.fds[slot]].watches) do
        local answer = happened & (watch.mask | UNASKED)
        if answer ~= 0 then
          local w = watch.wait
          if watch.place > 0 then w.answers[watch.place] = answer end
          if not w.hit then
            w.hit = true
            hits[#hits + 1] = w
          end
        end
      end
    end
  end
  wake_hits(hits)
end

--- Answers every time wait whose time has come.
local function expire()
  local t = Clock.monotonic_ns()
  while #loop.timers > 0 and (loop.timers[1].done or loop.timers[1].at <= t) do
    local w = pop_timer()
    if not w.done then
      if w.expiry_ok then wake(w, true, "") else wake(w, false, Poll.TIMEOUT) end
    end
  end
end

local function turn()
  while loop.live > 0 do
    -- One batch a turn, then the poll and the clock, so tasks answered
    -- at once -- a cancelled one waiting in a loop -- cannot hold back
    -- those waiting on a descriptor or on time.
    local batch = loop.ready
    loop.ready = {}
    for _, wakened in ipairs(batch) do
      -- One killed by a task earlier in the batch is passed by.
      if not wakened.task.ended then step(wakened.task, wakened.ok, wakened.why) end
    end
    if loop.live == 0 then break end
    poll_once(next_timeout())
    expire()
  end
end

--- Answers every wait on `fd` as though it had `answer` (a mask, for a
--- wait on several descriptors), or what it asked where `answer` is nil.
local function answer_waits(fd: integer, answer: integer | nil)
  if loop == nil then return end
  local entry = loop.watched[fd]
  if entry == nil then return end
  local hits: {Wait} = {}
  for _, watch in ipairs(entry.watches) do
    local w = watch.wait
    if watch.place > 0 then w.answers[watch.place] = answer or watch.mask end
    if not w.hit then
      w.hit = true
      hits[#hits + 1] = w
    end
  end
  wake_hits(hits)
end

--- Answers every wait on `fd` as though it were ready, for a module
--- about to close it: each waiting task, looking again, finds it closed
--- rather than waiting on a number the next descriptor opened may take.
--- Outside a run, and for a descriptor nothing waits on, it does nothing.
function Poll.closing(fd: integer)
  answer_waits(fd, sys.POLLNVAL)
end

--- Answers every wait on `fd` as though it were ready for what it asked,
--- for a module whose tasks share the descriptor: one task has read for
--- another what that one waits for, and each waiting task looks again,
--- finding its own answer or waiting anew. Outside a run, and for a
--- descriptor nothing waits on, it does nothing.
function Poll.wake(fd: integer)
  answer_waits(fd, nil)
end

--- Whether the caller is a task of a running [`Poll.run`], whose waits
--- let the other tasks run: what a module asks that must act
--- differently there -- refuse a call that cannot run in a task, or
--- wait through the run for what a task of it holds. It answers true,
--- too, in a `<close>` handler of a task being killed, where waits
--- raise: a wait there fails at once rather than hold the thread.
function Poll.in_task(): boolean
  return loop ~= nil and not loop.closing and loop.tasks[coroutine.running()] ~= nil
end

--- Starts `main` as the first task and runs the loop until every task
--- has ended.
local function run_tasks(main: function())
  start(main)
  turn()
end

--- Runs `main` as the first task and every task it spawns, returning
--- once all have ended. It raises what a task raised, with the task's
--- stack beneath a message, having closed the rest; and raises when
--- every task left waits on another, which none could ever answer. It
--- cannot be called from within a task.
function Poll.run(main: function())
  if loop ~= nil then error("poll: Poll.run is already running", 2) end
  if type(main) ~= "function" then error("poll: Poll.run takes a function", 2) end
  loop = { tasks = {}, live = 0, ready = {}, fds = {}, events = {}, watched = {}, timers = {},
    stale = 0, seq = 0 }
  -- Nothing may allocate between setting `loop` and the pcall, or a
  -- refused allocation would raise past the teardown and leave `loop`
  -- set for every later run: so no closure is made here.
  local ok, err: boolean, any = pcall(run_tasks, main)
  if not ok then local _, _: boolean, any = pcall(close_all) end
  loop = nil
  if not ok then error(err, 0) end
end

return Poll
