# stream

 The stream contract: the byte-stream interfaces every producer and
 consumer in the standard library composes over (api-review-2, #589).

 Reader is the one EOF convention: read() returns a non-empty chunk,
 or bare nil (no error) at end of stream, or nil plus an error message
 on failure. Reads after EOF keep returning bare nil. The optional
 size argument is an upper bound, not a demand — implementations may
 return fewer bytes — and must be positive when given.

 Writer accepts a string and returns the number of bytes written
 (which may be short) or nil plus an error message.

 Conforming types: fd.Handle (Reader and Writer), fetch.Reader
 (Reader), child.Handle (Reader, over the child's stdout). Sockets
 keep their native recv/send names but follow the same conventions
 (recv returns nil on peer close); wrap a socket's descriptor with
 fd.wrap(sock.fd) to use it where a Reader or Writer is expected.

 EINTR posture, recorded (api-review-2, #589): conforming reads and
 writes do NOT retry automatically when a signal interrupts them —
 the call surfaces nil plus an EINTR-tagged error, detected with
 errno.name_of(err) == "EINTR", and callers that install signal
 handlers retry themselves. poll retries internally. Making retry
 automatic across the wrappers is the post-stable signal-safety
 wave, tracked in #595.

## Types

### stream

 The stream contract: the byte-stream interfaces every producer and
 consumer in the standard library composes over (api-review-2, #589).
 Reader is the one EOF convention: read() returns a non-empty chunk,
 or bare nil (no error) at end of stream, or nil plus an error message
 on failure. Reads after EOF keep returning bare nil. The optional
 size argument is an upper bound, not a demand — implementations may
 return fewer bytes — and must be positive when given.
 Writer accepts a string and returns the number of bytes written
 (which may be short) or nil plus an error message.
 Conforming types: fd.Handle (Reader and Writer), fetch.Reader
 (Reader), child.Handle (Reader, over the child's stdout). Sockets
 keep their native recv/send names but follow the same conventions
 (recv returns nil on peer close); wrap a socket's descriptor with
 fd.wrap(sock.fd) to use it where a Reader or Writer is expected.
 EINTR posture, recorded (api-review-2, #589): conforming reads and
 writes do NOT retry automatically when a signal interrupts them —
 the call surfaces nil plus an EINTR-tagged error, detected with
 errno.name_of(err) == "EINTR", and callers that install signal
 handlers retry themselves. poll retries internally. Making retry
 automatic across the wrappers is the post-stable signal-safety
 wave, tracked in #595.
