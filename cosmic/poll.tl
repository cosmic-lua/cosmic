--- Tasks that wait on descriptors and time together: many functions
--- running in one thread, each running until it waits, while the others
--- run in turn -- the loop a server serves many connections on.
---
---     Poll.run(function()
---       local worker = Poll.spawn(function()
---         assert(Poll.readable(fd, 5000))
---         print(sys.read(fd, 4096))
---       end)
---       assert(worker:join())
---     end)
---
--- [`Poll.run`] runs its function as the first task, and returns once every
--- task has ended. A task waits by calling `readable`, `writable`,
--- `delay` or a Task's `join`, each of which answers true and "" once
--- what it waits for happens, or false and [`Poll.TIMEOUT`] once its
--- `timeout_ms` passes first, or false and [`Poll.CANCELLED`] once the task
--- is cancelled; a Task's `kill` ends one outright, for a task that
--- goes on after its waits fail. Nothing else here waits: a call that
--- blocks the thread (a blocking read, [`Http.get`], a SQLite query)
--- holds every task until it returns.
---
--- An error a task raises ends [`Poll.run`] at once: every other task is
--- closed where it waits, its `<close>` variables closed, and `run`
--- raises the error. A task that must go on after a failure catches it
--- itself.

local sys = require("cosmic.sys")

local record Poll
  --- A function running under [`Poll.run`] beside the others, answered by
  --- [`Poll.spawn`].
  record Task
    --- Waits for the task to end, at most `timeout_ms` milliseconds (no
    --- limit when nil): true and "" once it has returned, false and
    --- [`Poll.TIMEOUT`] or [`Poll.CANCELLED`] otherwise -- CANCELLED, too, for
    --- a task killed, or one a failed run closed where it waited.
    join: function(Task, timeout_ms?: integer): boolean, string
    --- Ends the task at its next wait: the wait it is in, if any, and
    --- every one after, answers false and [`Poll.CANCELLED`] at once. A
    --- task that has ended is left alone.
    cancel: function(Task)
    --- Ends the task now, where it waits or before it starts, without
    --- resuming it: its pending `<close>` variables are closed, none of
    --- its waits answers it again, and each task joining it answers
    --- false and [`Poll.CANCELLED`]. A task that has ended is left
    --- alone. A task cannot kill itself; nor can a `<close>` handler of
    --- a task being killed wait, spawn or kill. What such a handler
    --- raises, `kill` raises, the task ended all the same -- an error in
    --- the killing task, which ends the run unless that task catches it.
    --- Only a task that waits can be killed: one that computes without
    --- waiting holds the run, and every other task, until it waits.
    kill: function(Task)
  end

  --- What a wait answers once its `timeout_ms` passes first.
  TIMEOUT: string
  --- What a wait answers once its task is cancelled.
  CANCELLED: string
end

Poll.TIMEOUT = "timed out"
Poll.CANCELLED = "cancelled"

--- The longest wait [`sys.poll`] takes, and so the longest timeout here.
local MOST_MS <const> = 0x7fffffff

--- One wait a task is parked in, and what ends it: a descriptor ready, a
--- time reached, a task joined. `done` is set once one of them has
--- answered it, so the others that still hold it pass it by.
local record Wait
  task: State
  fd: integer
  events: integer
  at: integer
  seq: integer
  --- What the wait answers once `at` is reached: a delay's success, or
  --- any other wait's TIMEOUT.
  expiry_ok: boolean
  done: boolean
end

--- What a run keeps of a task, beside the handle `spawn` answers.
local record State
  handle: Poll.Task
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
  parked: Wait
  joiners: {Wait}
end

--- A task to resume, with what its wait answers.
local record Wake
  task: State
  ok: boolean
  why: string
end

--- A run's state while [`Poll.run`] runs; nil otherwise.
local record Loop
  tasks: {thread: State}
  live: integer
  ready: {Wake}
  --- Descriptor waits, in the order they began.
  watched: {Wait}
  --- Time waits, a binary heap on `at` then `seq`.
  timers: {Wait}
  seq: integer
  --- Set while the run closes its tasks, when nothing may start or wait.
  closing: boolean
end

local loop: Loop = nil

local function now_ms(): integer
  local reading, trouble = sys.clock_gettime(sys.CLOCK_MONOTONIC)
  if reading == nil then error("clock_gettime(CLOCK_MONOTONIC): " .. trouble) end
  return reading // 1000000
end

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

local function heap_pop(heap: {Wait}): Wait
  local top = heap[1]
  local last = table.remove(heap)
  if #heap > 0 then
    heap[1] = last
    local i = 1
    while true do
      local l, r, least = 2 * i, 2 * i + 1, i
      if l <= #heap and earlier(heap[l], heap[least]) then least = l end
      if r <= #heap and earlier(heap[r], heap[least]) then least = r end
      if least == i then break end
      heap[i], heap[least] = heap[least], heap[i]
      i = least
    end
  end
  return top
end

--- Answers `w`, once: the run resumes its task with `ok` and `why`.
local function wake(w: Wait, ok: boolean, why: string)
  if w.done then return end
  w.done = true
  w.task.parked = nil
  loop.ready[#loop.ready + 1] = { task = w.task, ok = ok, why = why }
end

--- The task the calling coroutine is, raising at `level` where there is
--- none: a wait outside [`Poll.run`], in a coroutine a task made of its
--- own, or while the run closes its tasks.
local function current(what: string, level: integer): State
  if loop == nil then error(what .. " outside Poll.run", level + 1) end
  if loop.closing then error(what .. " while Poll.run closes its tasks", level + 1) end
  local task = loop.tasks[coroutine.running()]
  if task == nil then error(what .. " outside a task's own coroutine", level + 1) end
  if task.killed then error(what .. " while its task is killed", level + 1) end
  return task
end

local function checked_ms(value: integer | nil, name: string, level: integer)
  if value ~= nil and (math.type(value) ~= "integer" or value < 0 or value > MOST_MS) then
    error(name .. " must be an integer from 0 to " .. MOST_MS, level + 1)
  end
end

--- Parks `task` in `w`, bounded by `timeout_ms`, and answers what ends
--- it. A cancelled task still yields, answered at once, so a task that
--- waits in a loop lets the others run.
local function park(task: State, w: Wait, timeout_ms: integer | nil): boolean, string
  task.parked = w
  if task.cancelled then
    wake(w, false, Poll.CANCELLED)
  else
    if w.fd ~= nil then loop.watched[#loop.watched + 1] = w end
    if timeout_ms ~= nil then
      loop.seq = loop.seq + 1
      w.at, w.seq = now_ms() + timeout_ms, loop.seq
      -- TODO: drop done waits from the heap once they outnumber the live
      -- ones: one leaves only on reaching the top, so a server whose long
      -- timeouts are answered early holds one per wait until each expires.
      heap_push(loop.timers, w)
    end
  end
  task.waiting = true
  local ok, why = coroutine.yield(w)
  task.waiting = false
  if not w.done then error("a task was resumed other than by Poll.run", 2) end
  if ok == true then return true, "" end
  if ok == false and why is string then return false, why end
  error("a task was resumed other than by Poll.run", 2)
end

local function wait_fd(fd: integer, events: integer, timeout_ms: integer | nil, what: string): boolean, string
  local task = current(what, 3)
  checked_ms(timeout_ms, "timeout_ms", 3)
  if math.type(fd) ~= "integer" or fd < 0 or fd > MOST_MS then
    error("fd must be a descriptor", 3)
  end
  return park(task, { task = task, fd = fd, events = events }, timeout_ms)
end

--- Waits until `fd` can be read without waiting -- data, the end of what
--- the peer sends, a connection to accept, or an error to read -- at most
--- `timeout_ms` milliseconds (no limit when nil).
function Poll.readable(fd: integer, timeout_ms?: integer): boolean, string
  return wait_fd(fd, sys.POLLIN, timeout_ms, "Poll.readable")
end

--- Waits until `fd` can be written without waiting, or has failed, at
--- most `timeout_ms` milliseconds (no limit when nil).
function Poll.writable(fd: integer, timeout_ms?: integer): boolean, string
  return wait_fd(fd, sys.POLLOUT, timeout_ms, "Poll.writable")
end

--- Waits `ms` milliseconds while the other tasks run: true and "" once
--- they have passed, false and [`Poll.CANCELLED`] once the task is
--- cancelled first.
function Poll.delay(ms: integer): boolean, string
  local task = current("Poll.delay", 2)
  if ms == nil then error("ms must be an integer from 0 to " .. MOST_MS, 2) end
  checked_ms(ms, "ms", 2)
  return park(task, { task = task, expiry_ok = true }, ms)
end

--- Ends `task`, suspended, as a Task's `kill` says: its wait is marked
--- answered and its wakes taken from the ready queue, so nothing resumes
--- it, and it is settled as ended before what its closing raised is
--- raised.
local function close_task(task: State)
  task.killed = true
  if task.parked ~= nil then
    task.parked.done = true
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

--- A new task running `fn`, ready to run.
local function start(fn: function()): Poll.Task
  local state: State = { co = coroutine.create(fn), loop = loop, joiners = {} }
  state.handle = {
    join = function(_self: Poll.Task, timeout_ms?: integer): boolean, string
      local task = current("Task:join", 2)
      checked_ms(timeout_ms, "timeout_ms", 2)
      if state.killed then return false, Poll.CANCELLED end
      if state.ended or state.loop ~= loop then return true, "" end
      if state == task then error("a task cannot join itself", 2) end
      local w: Wait = { task = task }
      state.joiners[#state.joiners + 1] = w
      -- TODO: drop a joiner's wait once a timeout answers it: a task
      -- joined over and over with a timeout keeps every one until it ends.
      return park(task, w, timeout_ms)
    end,
    cancel = function(_self: Poll.Task)
      if state.loop ~= loop or state.ended or state.cancelled then return end
      state.cancelled = true
      if state.parked ~= nil then wake(state.parked, false, Poll.CANCELLED) end
    end,
    kill = function(_self: Poll.Task)
      if state.loop ~= loop or state.ended then return end
      if state == current("Task:kill", 2) then error("a task cannot kill itself", 2) end
      close_task(state)
    end,
  }
  loop.tasks[state.co] = state
  loop.live = loop.live + 1
  loop.ready[#loop.ready + 1] = { task = state, ok = true, why = "" }
  return state.handle
end

--- Starts `fn` as a task of its own, run once the calling task waits.
function Poll.spawn(fn: function()): Poll.Task
  current("Poll.spawn", 2)
  if type(fn) ~= "function" then error("Poll.spawn takes a function", 2) end
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
  -- TODO: carry the task's traceback with its error, taken from its
  -- coroutine before it is closed, once cosmic.errors can trace another
  -- coroutine: only the message crosses resume today.
  if not resumed then
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
    error("a task yielded other than through cosmic.poll", 0)
  end
end

--- How long the next `poll` may wait: 0 while a task is ready, until the
--- nearest time wait, or -1 for no limit.
local function next_timeout(): integer
  if #loop.ready > 0 then return 0 end
  while #loop.timers > 0 and loop.timers[1].done do heap_pop(loop.timers) end
  if #loop.timers == 0 then return -1 end
  local left = loop.timers[1].at - now_ms()
  if left < 0 then return 0 end
  return math.min(left, MOST_MS)
end

--- Waits on every watched descriptor for as long as `timeout`, and
--- answers each wait whose descriptor is ready, or in error or hung up,
--- which its read or write then reports. Each wait is an entry of its
--- own, though several share a descriptor: `poll` answers each entry
--- only the events it asked for, and those three.
local function poll_once(timeout: integer)
  local fds: {integer} = {}
  local events: {integer} = {}
  local kept: {Wait} = {}
  -- TODO: keep the descriptor set between polls, changed as waits begin
  -- and end, rather than built again from every wait each time round.
  for _, w in ipairs(loop.watched) do
    if not w.done then
      kept[#kept + 1] = w
      fds[#kept], events[#kept] = w.fd, w.events
    end
  end
  loop.watched = kept
  if #fds == 0 and timeout < 0 then
    error("every task waits on another: none can go on", 0)
  end
  -- A signal a Child.guard catches only cuts this poll short, and the
  -- loop waits on: what one means -- end every wait, or stop taking
  -- work and drain it, as Net.serve does -- is the run's to say, by a
  -- task that waits on the guard (`g:wait`).
  local revents, trouble = sys.poll(fds, events, timeout)
  if revents == nil then error("poll: " .. trouble, 0) end
  for i, w in ipairs(kept) do
    if revents[i] ~= 0 then wake(w, true, "") end
  end
end

--- Answers every time wait whose time has come.
local function expire()
  local t = now_ms()
  while #loop.timers > 0 and (loop.timers[1].done or loop.timers[1].at <= t) do
    local w = heap_pop(loop.timers)
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

--- Answers every wait on `fd` as though it were ready, for a module
--- about to close it: each waiting task, looking again, finds it closed
--- rather than waiting on a number the next descriptor opened may take.
--- Outside a run, and for a descriptor nothing waits on, it does nothing.
function Poll.closing(fd: integer)
  if loop == nil then return end
  for _, w in ipairs(loop.watched) do
    if w.fd == fd then wake(w, true, "") end
  end
end

--- Whether the caller is a task of a running [`Poll.run`], whose waits
--- let the other tasks run: what a module that waits asks, to wait
--- through `readable` and `writable` there and on its own elsewhere.
function Poll.in_task(): boolean
  if loop == nil or loop.closing then return false end
  local task = loop.tasks[coroutine.running()]
  return task ~= nil and not task.killed
end

--- Starts `main` as the first task and runs the loop until every task
--- has ended.
local function run_tasks(main: function())
  start(main)
  turn()
end

--- Runs `main` as the first task and every task it spawns, returning
--- once all have ended. It raises what a task raised, having closed the
--- rest; and raises when every task left waits on another, which none
--- could ever answer. It cannot be called from within a task.
function Poll.run(main: function())
  if loop ~= nil then error("Poll.run is already running", 2) end
  if type(main) ~= "function" then error("Poll.run takes a function", 2) end
  loop = { tasks = {}, live = 0, ready = {}, watched = {}, timers = {}, seq = 0 }
  -- Nothing may allocate between setting `loop` and the pcall, or a
  -- refused allocation would raise past the teardown and leave `loop`
  -- set for every later run: so no closure is made here.
  local ok, err: boolean, any = pcall(run_tasks, main)
  if not ok then local _, _: boolean, any = pcall(close_all) end
  loop = nil
  if not ok then error(err, 0) end
end

return Poll
