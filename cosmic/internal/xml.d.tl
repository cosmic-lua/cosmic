-- XML at the Lua boundary, as the core (core/xml.c, over expat) provides
-- it. cosmic/xml.tl documents the contract. A fallible function answers
-- `value, ""` on success and `nil, error` on failure.
--- @kind binding

local record xml
  -- What an event is; cosmic/xml.tl's Kind describes each.
  enum Kind
    "start"
    "end"
    "text"
    "comment"
    "instruction"
  end

  -- One event, as cosmic/xml.tl's Event describes it.
  record Event
    kind: Kind
    name?: string
    attributes?: {string: string}
    text?: string
  end

  record Parser
    userdata

    -- Events `chunk` completes, or fewer, and ones an earlier chunk
    -- completed. nil and why when the text is not well-formed XML, or
    -- memory runs out; the parser is finished then, and after a raise
    -- inside the call. Raises on a finished parser and on one in a call.
    feed: function(Parser, chunk: string): {Event}?, string
    -- The input has ended: every event not yet answered, as `feed`
    -- answers them. The parser is finished afterward.
    finish: function(Parser): {Event}?, string
    __close: function(Parser, any)
  end

  -- A parser; with `namespaces`, one that answers names in Clark's
  -- notation; with `eager`, one that reads a token a chunk left open
  -- again at every chunk; one that refuses a run of text longer than
  -- `max_text` bytes (64 MiB when absent); with `local_names`, one that
  -- reads namespaces as `namespaces` does and answers a name without its
  -- namespace. nil and why when memory runs out. Raises when `max_text`
  -- is less than 1.
  parser: function(namespaces?: boolean, eager?: boolean, max_text?: integer,
                   local_names?: boolean): Parser?, string
end

return xml
