--- The stream contract: the byte-stream interfaces every producer and
--- consumer in the standard library composes over (api-review-2, #589).
---
--- Reader is the one EOF convention: read() returns a non-empty chunk,
--- or bare nil (no error) at end of stream, or nil plus an error message
--- on failure. Reads after EOF keep returning bare nil. The optional
--- size argument is an upper bound, not a demand — implementations may
--- return fewer bytes — and must be positive when given.
---
--- Writer accepts a string and returns the number of bytes written
--- (which may be short) or nil plus an error message.
---
--- Conforming types: fd.Handle (Reader and Writer), fetch.Reader
--- (Reader), child.Handle (Reader, over the child's stdout). Sockets
--- keep their native recv/send names but follow the same conventions
--- (recv returns nil on peer close); wrap a socket's descriptor with
--- fd.wrap(sock.fd) to use it where a Reader or Writer is expected.
---
--- EINTR posture (the signal-safety wave, #595; pre-stable decision in
--- #589): blocking calls on the ergonomic wrappers retry automatically
--- when a signal interrupts them — EINTR never surfaces from
--- fd.Handle read/write, socket send/recv/accept, child wait/read,
--- poll, or shm futex waits. Pending Lua signal handlers still run:
--- delivery is deferred to the VM, so each handler fires between an
--- interrupted call and its retry. To break out of a blocking call,
--- give it a deadline (socket set_timeout, poll's timeout, shm wait's
--- absolute deadline) or close the descriptor from the handler.
--- The deliberate exceptions, where the interruption IS the result:
--- time.sleep (returns the remainder plus an EINTR error),
--- signal.sigsuspend, socket connect (POSIX keeps connecting in the
--- background after EINTR, so a blind retry would misreport), and the
--- raw cosmic.proc/cosmo.unix passthroughs, which surface errnos
--- verbatim.
local record stream
  --- A source of bytes. read(n?) returns the next chunk (at most n
  --- bytes when n is given), bare nil at end of stream, or nil plus an
  --- error message on failure.
  interface Reader
    read: function(self: Reader, n?: number): string | nil, string
  end

  --- A sink for bytes. write(data) returns the number of bytes
  --- written (possibly short), or nil plus an error message.
  interface Writer
    write: function(self: Writer, data: string): number | nil, string
  end
end

return stream
