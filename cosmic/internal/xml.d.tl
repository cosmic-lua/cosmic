-- XML at the Lua boundary, as the core (core/xml.c, over expat) provides
-- it. cosmic/xml.tl documents the contract. A fallible function answers
-- `value, ""` on success and `nil, error` on failure.

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
  -- notation. nil and why when memory runs out.
  parser: function(namespaces?: boolean): Parser?, string
end

return xml
