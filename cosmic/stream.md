# stream

 The stream contract: byte-stream Reader/Writer interfaces.
 Every producer and consumer in the standard library composes over
 them.

 Reader is the one EOF convention: read() returns a non-empty chunk,
 or bare nil (no error) at end of stream, or nil plus an error message
 on failure. Reads after EOF keep returning bare nil. The optional
 size argument is an upper bound, not a demand — implementations may
 return fewer bytes — and must be positive when given.

 Writer accepts a string and returns the number of bytes written
 (which may be short) or nil plus an error message.

 Conforming types: fd.Handle (Reader and Writer), net.Socket
 (Reader and Writer — read/write alias recv/send), fetch.Reader
 (Reader), child.Handle (Reader, over the child's stdout).

 EINTR posture (the signal-safety wave; a pre-stable decision):
 blocking calls on the ergonomic wrappers retry automatically
 when a signal interrupts them — EINTR never surfaces from
 fd.Handle read/write, socket send/recv/accept, child wait/read,
 poll, or shm futex waits. Pending Lua signal handlers still run:
 delivery is deferred to the VM, so each handler fires between an
 interrupted call and its retry. To break out of a blocking call,
 give it a deadline (socket set_timeout, poll's timeout, shm wait's
 absolute deadline) or close the descriptor from the handler.
 The deliberate exceptions, where the interruption IS the result:
 time.sleep_ms (returns the remainder plus an EINTR error),
 signal.sigsuspend, socket connect (POSIX keeps connecting in the
 background after EINTR, so a blind retry would misreport), and the
 raw cosmic.proc/cosmo.unix passthroughs, which surface errnos
 verbatim.

## Types

### stream

 The stream contract: byte-stream Reader/Writer interfaces.
 Every producer and consumer in the standard library composes over
 them.
 Reader is the one EOF convention: read() returns a non-empty chunk,
 or bare nil (no error) at end of stream, or nil plus an error message
 on failure. Reads after EOF keep returning bare nil. The optional
 size argument is an upper bound, not a demand — implementations may
 return fewer bytes — and must be positive when given.
 Writer accepts a string and returns the number of bytes written
 (which may be short) or nil plus an error message.
 Conforming types: fd.Handle (Reader and Writer), net.Socket
 (Reader and Writer — read/write alias recv/send), fetch.Reader
 (Reader), child.Handle (Reader, over the child's stdout).
 EINTR posture (the signal-safety wave; a pre-stable decision):
 blocking calls on the ergonomic wrappers retry automatically
 when a signal interrupts them — EINTR never surfaces from
 fd.Handle read/write, socket send/recv/accept, child wait/read,
 poll, or shm futex waits. Pending Lua signal handlers still run:
 delivery is deferred to the VM, so each handler fires between an
 interrupted call and its retry. To break out of a blocking call,
 give it a deadline (socket set_timeout, poll's timeout, shm wait's
 absolute deadline) or close the descriptor from the handler.
 The deliberate exceptions, where the interruption IS the result:
 time.sleep_ms (returns the remainder plus an EINTR error),
 signal.sigsuspend, socket connect (POSIX keeps connecting in the
 background after EINTR, so a blind retry would misreport), and the
 raw cosmic.proc/cosmo.unix passthroughs, which surface errnos
 verbatim.

```teal
local record stream
  read: function(self: Reader, n?: number): string | nil, string
end
```

## Functions

### write_all

```teal
function write_all(w: stream.Writer, data: string): boolean, string
```

 Write all of data, retrying short writes until done. The two
 things every Writer caller wants — this and read_all — used to be
 five independent hand-rolled loops across the stdlib.
 Bytes written before a failure stay written.

**Parameters:**

- `w` (Writer) - The sink
- `data` (string) - The bytes to write

**Returns:**

- boolean - True when everything was written
- string? - Error message on failure

### read_all

```teal
function read_all(r: stream.Reader, max_bytes?: integer): string | nil, string
```

 Read to end of stream and return everything as one string.
   error (untrusted input must not balloon memory silently)

**Parameters:**

- `r` (Reader) - The source
- `max_bytes` (integer?) - Cap on the result size; exceeding it is an

**Returns:**

- string - | nil The bytes read, or nil on error
- string? - Error message on failure

### copy

```teal
function copy(dst: stream.Writer, src: stream.Reader,
    buffer_size_bytes?: integer): integer | nil, string
```

 Pump src into dst until src ends. Returns the byte count copied.
   reader's own)

**Parameters:**

- `dst` (Writer) - The sink
- `src` (Reader) - The source
- `buffer_size_bytes` (integer?) - Read bound per chunk (default: the

**Returns:**

- integer - | nil Bytes copied, or nil on error
- string? - Error message on failure

### new_reader

```teal
function new_reader(data: string): stream.Reader
```

 Wrap bytes already in hand as a Reader, so in-memory data (a file
 read whole, a decompressed buffer, a test fixture) feeds any stream
 consumer — stream.lines, sse.parse, stream.copy — without a
 hand-rolled adapter. read(n?) returns successive chunks (at most n
 bytes when n is given, the whole remainder otherwise), then bare
 nil at end of stream, per the Reader contract; n must be positive
 when given.

**Parameters:**

- `data` (string) - The bytes to serve

**Returns:**

- Reader - A reader over the bytes

### new_buffer

```teal
function new_buffer(): stream.Buffer
```

 Collect writes in memory: the Writer half of new_reader. write()
 appends and reports the chunk fully written; contents() returns
 everything written so far. Point stream.copy (or any Writer taker)
 at one to materialize a pipeline's output as a string.

**Returns:**

- Buffer - The in-memory writer

### lines

```teal
function lines(r: stream.Reader): stream.LineIter
```

 Iterate complete lines from a Reader, buffering partial lines
 across chunks. On clean EOF a final unterminated line is yielded
 once, then nil. On a read error the buffered partial line is
 truncated data and is discarded — the iterator yields nil plus the
 error once, then plain nil forever. (Promoted from fetch.Reader's
 lines(); cosmic.sse consumes the same iterator.) A reader carrying
 the DelimReader capability skips the Lua buffering entirely.

**Parameters:**

- `r` (Reader) - The source

**Returns:**

- function - Iterator yielding lines without the trailing newline
