--- A bounded first-in first-out queue between the tasks of one
--- [`Poll.run`] -- a producer [`Channel.Queue.send`]s, a consumer
--- [`Channel.Queue.receive`]s, and either waits (a sender for room, a
--- receiver for an item) while the others run. What a consumer cannot keep
--- up with is the queue's `overflow` policy to settle -- wait, drop the
--- oldest or the newest, or cut the queue off -- so a slow reader never
--- grows memory without bound.
---
---     Poll.run(function()
---       local queue: Channel.Queue<string> = Channel.new({ capacity = 8 })
---       Poll.spawn(function()
---         for i = 1, 3 do assert(queue:send("job " .. i)) end
---         queue:close()
---       end)
---       while true do
---         local job, why = queue:receive()
---         if job == nil then break end
---         print(job)
---       end
---     end)
---
--- A queue belongs to the run that made it, as the [`Poll.Notifier`]s it
--- waits on do. It is no `select`: a task that waits on several sources
--- builds that from [`Poll.notifier`].

local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")

local record Channel
  --- What a full queue does with the next item: "block" makes
  --- [`Channel.Queue.send`] wait for room; "drop_oldest" discards the
  --- oldest queued item to make room; "drop_newest" discards the item
  --- sent; "close" closes the queue, which cuts off a consumer too slow
  --- to follow. A drop counts in [`Channel.Queue.dropped`].
  enum Overflow
    "block"
    "drop_oldest"
    "drop_newest"
    "close"
  end

  record Options
    --- How many items the queue holds, at least 1 (256 when nil).
    capacity: integer
    --- What a full queue does ("block" when nil).
    overflow: Channel.Overflow
  end

  --- A queue of `T`, answered by [`Channel.new`]. Items leave in the
  --- order they were queued. A call that has to wait does so in a
  --- [`Poll.Notifier`] wait: it raises outside a task, and answers false
  --- or nil and [`Poll.TIMEOUT`] or [`Poll.CANCELLED`] as every wait
  --- does.
  ---
  --- Waiters are noticed longest first, but a notice is no reservation:
  --- a task that does not wait ([`try_send`], or a [`send`] or
  --- [`receive`] that finds room or an item) may take what the noticed
  --- waiter was woken for, and that waiter then waits again, behind the
  --- others. So blocked senders' items can reach the queue out of the
  --- order they began to wait; only one task's own items keep their
  --- order.
  interface Queue<T>
    --- Queues `item` (never nil, which raises) and notices the receiver
    --- that has waited longest (which a caller that does not wait may
    --- still outrun). True once it is queued or, under a
    --- "drop_oldest" or "drop_newest" policy, once the drop has settled
    --- the overflow. Under "block" a full queue makes it wait for room,
    --- at most `timeout_ns` nanoseconds (no limit when nil): false and
    --- [`Poll.TIMEOUT`] or [`Poll.CANCELLED`]. False and
    --- [`Channel.CLOSED`] once the queue is closed -- also when this
    --- very item overflowed a "close" queue, which it closes.
    send: function(self: Queue<T>, item: T, timeout_ns?: integer): boolean, string
    --- [`send`] that never waits: under "block" a full queue answers
    --- false and [`Channel.FULL`] instead.
    try_send: function(self: Queue<T>, item: T): boolean, string
    --- The oldest item, waiting for one at most `timeout_ns`
    --- nanoseconds (no limit when nil). Nil and [`Channel.CLOSED`] once
    --- the queue is closed and every item has been taken: a closed queue
    --- still gives up what it holds first. Nil and [`Poll.TIMEOUT`] or
    --- [`Poll.CANCELLED`] otherwise.
    receive: function(self: Queue<T>, timeout_ns?: integer): T | nil, string
    --- Closes the queue: every task waiting to send or receive wakes, a
    --- [`send`] after it fails, and a [`receive`] drains what is queued
    --- and then answers [`Channel.CLOSED`]. Closing again does nothing.
    --- It never waits, so a `<close>` handler may call it.
    close: function(self: Queue<T>)
    --- How many items are queued.
    len: function(self: Queue<T>): integer
    --- Whether [`close`] has been called, or an overflow closed the
    --- queue.
    closed: function(self: Queue<T>): boolean
    --- How many items overflow has discarded since the queue was made.
    dropped: function(self: Queue<T>): integer
  end

  --- What [`Channel.Queue.send`] and [`Channel.Queue.receive`] answer
  --- once the queue is closed.
  CLOSED: string
  --- What [`Channel.Queue.try_send`] answers when a "block" queue has no
  --- room.
  FULL: string

  new: function<T>(opts?: Options): Queue<T>
end

Channel.CLOSED = "closed"
Channel.FULL = "full"

local DEFAULT_CAPACITY <const> = 256

local record State<T>
  is Channel.Queue<T>
  items: {integer: T}
  first: integer
  count: integer
  capacity: integer
  overflow: Channel.Overflow
  is_closed: boolean
  drops: integer
  not_empty: Poll.Notifier
  not_full: Poll.Notifier
  send: function(self: State<T>, item: T, timeout_ns?: integer): boolean, string
  try_send: function(self: State<T>, item: T): boolean, string
  receive: function(self: State<T>, timeout_ns?: integer): T | nil, string
  close: function(self: State<T>)
  len: function(self: State<T>): integer
  closed: function(self: State<T>): boolean
  dropped: function(self: State<T>): integer
end

local function push<T>(self: State<T>, item: T)
  self.items[self.first + self.count] = item
  self.count = self.count + 1
  self.not_empty:notify_one()
end

local function pop<T>(self: State<T>): T
  local item = self.items[self.first]
  self.items[self.first] = nil
  self.first = self.first + 1
  self.count = self.count - 1
  if self.count == 0 then self.first = 1 end
  return item
end

function State.close<T>(self: State<T>)
  if self.is_closed then return end
  self.is_closed = true
  self.not_empty:notify_all()
  self.not_full:notify_all()
end

--- Queues `item` if the policy lets it without waiting: "queued" (also
--- for an item a drop policy settled), "closed", or "full" when a "block"
--- queue has no room and a sender may wait.
local function offer<T>(self: State<T>, item: T): string
  if self.is_closed then return "closed" end
  if self.count < self.capacity then
    push(self, item)
    return "queued"
  end
  local overflow = self.overflow
  if overflow == "drop_oldest" then
    pop(self)
    self.drops = self.drops + 1
    push(self, item)
    return "queued"
  elseif overflow == "drop_newest" then
    self.drops = self.drops + 1
    return "queued"
  elseif overflow == "close" then
    State.close(self)
    return "closed"
  end
  return "full"
end

local function need_item<T>(item: T)
  if item == nil then error("channel: send of nil", 3) end
end

function State.try_send<T>(self: State<T>, item: T): boolean, string
  need_item(item)
  local result = offer(self, item)
  if result == "queued" then return true, "" end
  if result == "closed" then return false, Channel.CLOSED end
  return false, Channel.FULL
end

function State.send<T>(self: State<T>, item: T, timeout_ns?: integer): boolean, string
  need_item(item)
  Poll.checked_ns(timeout_ns, "channel", "timeout_ns", 2)
  local deadline = timeout_ns ~= nil and Clock.monotonic_ns() + timeout_ns or nil
  while true do
    local result = offer(self, item)
    if result == "queued" then return true, "" end
    if result == "closed" then return false, Channel.CLOSED end
    local left: integer = nil
    if deadline ~= nil then
      left = deadline - Clock.monotonic_ns()
      if left <= 0 then return false, Poll.TIMEOUT end
    end
    local woke, reason = self.not_full:wait(left)
    if not woke then return false, reason end
  end
end

function State.receive<T>(self: State<T>, timeout_ns?: integer): T | nil, string
  Poll.checked_ns(timeout_ns, "channel", "timeout_ns", 2)
  local deadline = timeout_ns ~= nil and Clock.monotonic_ns() + timeout_ns or nil
  while self.count == 0 do
    if self.is_closed then return nil, Channel.CLOSED end
    local left: integer = nil
    if deadline ~= nil then
      left = deadline - Clock.monotonic_ns()
      if left <= 0 then return nil, Poll.TIMEOUT end
    end
    local woke, reason = self.not_empty:wait(left)
    if not woke then return nil, reason end
  end
  local item = pop(self)
  self.not_full:notify_one()
  return item, ""
end

function State.len<T>(self: State<T>): integer return self.count end
function State.closed<T>(self: State<T>): boolean return self.is_closed end
function State.dropped<T>(self: State<T>): integer return self.drops end

--- A new empty queue for the tasks of the running [`Poll.run`]; `T`
--- comes from the declaration it is bound to
--- (`local q: Channel.Queue<string> = Channel.new()`). It raises outside a
--- run (in [`Poll.notifier`]'s words), and for options it does not take.
function Channel.new<T>(opts?: Channel.Options): Channel.Queue<T>
  local capacity = DEFAULT_CAPACITY
  local overflow: Channel.Overflow = "block"
  if opts ~= nil then
    if opts.capacity ~= nil then
      if math.type(opts.capacity) ~= "integer" or opts.capacity < 1 then
        error("channel: capacity must be an integer of at least 1", 2)
      end
      capacity = opts.capacity
    end
    if opts.overflow ~= nil then
      overflow = opts.overflow
      if overflow ~= "block" and overflow ~= "drop_oldest" and overflow ~= "drop_newest" and
          overflow ~= "close" then
        error("channel: overflow must be \"block\", \"drop_oldest\", \"drop_newest\" or \"close\"", 2)
      end
    end
  end
  local queue: State<T> = {
    items = {}, first = 1, count = 0, capacity = capacity, overflow = overflow,
    is_closed = false, drops = 0,
    not_empty = Poll.notifier(), not_full = Poll.notifier(),
    send = State.send, try_send = State.try_send, receive = State.receive,
    close = State.close, len = State.len, closed = State.closed, dropped = State.dropped,
  }
  return queue
end

return Channel
