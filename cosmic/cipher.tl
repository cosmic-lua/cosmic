--- Authenticated encryption under a shared key, and X25519 key agreement,
--- which gives two parties such a key over a channel anyone can read.
---
--- - [`Cipher.seal`] encrypts a message and appends a tag;
---   [`Cipher.open`] answers the message only when the tag proves that
---   the holder of the key sealed exactly these bytes.
--- - [`Cipher.channel`] seals and opens the messages of a session, one
---   key for each direction, and counts the nonces itself.
--- - [`Cipher.x25519_public`] is the public key of a private key, and
---   [`Cipher.x25519`] the secret that one party's private key and the
---   other's public key share.
---
---     local key = assert(Rand.entropy(Cipher.key_length))
---     local nonce = assert(Rand.entropy(Cipher.nonce_length))
---     local sealed = Cipher.seal("chacha20-poly1305", key, nonce, "attack at dawn")
---     assert(Cipher.open("chacha20-poly1305", key, nonce, sealed) == "attack at dawn")
---
--- Keys, nonces and what these functions answer are raw bytes. A key is
--- [`Cipher.key_length`] bytes that nobody can guess: `Rand.entropy(32)`
--- of [`cosmic.rand`], or a key derivation's output, never a password.
---
--- What a correct program can meet answers nil and why: a sealed message
--- that does not authenticate, a peer's key of low order. An argument of
--- the wrong length raises, and so does every other failure: memory
--- running out, or the system's entropy source failing, which the X25519
--- functions draw on.

-- The raw module behind every function here lives under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why it is off
-- the public surface.
local raw = require("cosmic.internal.cipher")

local record Cipher
  --- The algorithms, by exactly these lower-case names. `chacha20-poly1305`
  --- is ChaCha20-Poly1305 as RFC 8439 defines it. A name that is not one
  --- of these raises.
  enum Algorithm
    "chacha20-poly1305"
  end

  --- How many bytes a key is, 32: [`Cipher.seal`]'s, and an X25519
  --- private key, public key and shared secret alike.
  key_length: integer
  --- How many bytes a nonce is, 12.
  nonce_length: integer
  --- How many bytes [`Cipher.seal`] adds to a message, 16: the tag.
  tag_length: integer

  --- Which end of a counter comes first in a nonce: its lowest byte
  --- (`little`) or its highest (`big`).
  enum ByteOrder
    "little"
    "big"
  end

  --- How a [`Channel`] writes a message's number into its nonce, and
  --- where it starts counting. Both ends of a session give the same
  --- `counter_length` and `byte_order`; each field is its default when
  --- absent.
  record ChannelOptions
    --- How many bytes of the nonce the counter fills: 8, the default,
    --- after 4 zero bytes, or all 12. A counter is below 2^63, so of 12
    --- bytes the 4 highest are zero: in the `little` order they are the
    --- nonce's last 4, and the nonce differs from the 8-byte one. In the
    --- `big` order the two lengths write the same nonce.
    counter_length?: integer
    --- `little` by default.
    byte_order?: ByteOrder
    --- How many messages this end has already sent under `output_key`,
    --- 0 by default: for resuming a session whose keys and counts were
    --- kept. A channel does not answer its counts: the caller counts the
    --- messages it seals. A count lower than the true one reuses a
    --- nonce, with the cost [`Cipher.seal`] describes.
    sent?: integer
    --- How many messages this end has already opened under `input_key`,
    --- 0 by default: for resuming, as `sent` is. The caller counts the
    --- messages that opened.
    received?: integer
  end

  --- One end of a session, from [`Cipher.channel`]. It numbers the
  --- messages of each direction from 0 and never shows a nonce: the
  --- peer counts the same way.
  record Channel
    --- `plaintext` sealed as this end's next message, as [`Cipher.seal`]
    --- seals it, bound to `aad` when given. Each call uses the next
    --- nonce, so the peer opens the messages in the order they were
    --- sealed. Raises once `math.maxinteger` (2^63 - 1) messages have
    --- been sent, rather than use a nonce twice.
    seal: function(self: Channel, plaintext: string, aad?: string): string

    --- The plaintext of `sealed`, the peer's next message, and "". nil
    --- and why when it does not authenticate, as [`Cipher.open`]
    --- answers: a message that was changed, sealed with another `aad`,
    --- replayed, or that arrives before one sealed earlier. A message
    --- that fails does not count, so the genuine next one still opens.
    --- nil and why also once `math.maxinteger` messages have been
    --- opened.
    open: function(self: Channel, sealed: string, aad?: string): string?, string
  end
end

Cipher.key_length = 32
Cipher.nonce_length = 12
Cipher.tag_length = 16

--- `plaintext` encrypted under `key` and `nonce`: the ciphertext, as
--- long as the plaintext, followed by the tag, [`Cipher.tag_length`]
--- bytes that authenticate the ciphertext and `aad` together. `aad` is
--- data sent in the clear that the message is bound to (a header, a
--- sequence number): it is not in what `seal` answers, and
--- [`Cipher.open`] needs the same bytes. Absent, it is empty.
---
--- A nonce is used once per key. Sealing two messages under the same
--- key and nonce shows the difference of their plaintexts and lets an
--- attacker forge messages under that key. The nonce is no secret: send
--- it beside the message. A counter that never repeats serves. So
--- does `Rand.entropy(12)` for about 2^32 messages under one key, which
--- keeps the chance that two nonces are the same near 2^-33.
---
--- Raises when `key` is not [`Cipher.key_length`] bytes or `nonce` not
--- [`Cipher.nonce_length`].
function Cipher.seal(algorithm: Cipher.Algorithm, key: string, nonce: string, plaintext: string,
                     aad?: string): string
  return raw.seal(algorithm, key, nonce, plaintext, aad)
end

--- The plaintext of `sealed`, which [`Cipher.seal`] answered for the
--- same algorithm, key, nonce and `aad`, and "". nil and why when
--- `sealed` is shorter than a tag or its tag does not authenticate it:
--- a bit of the ciphertext, the tag, the `aad`, the nonce or the key
--- differs. Nothing of the message is released then. Raises as `seal`
--- does, and on any other failure.
function Cipher.open(algorithm: Cipher.Algorithm, key: string, nonce: string, sealed: string,
                     aad?: string): string?, string
  return raw.open(algorithm, key, nonce, sealed, aad)
end

--- Checks one of [`Cipher.channel`]'s counts, raising in its caller's
--- caller.
local function count_of(name: string, count: integer?): integer
  local n = count or 0
  if n < 0 then error("cipher: channel's " .. name .. " must be 0 or more", 3) end
  return n
end

--- One end of a session under two keys: `output_key` seals what this
--- end sends and `input_key` opens what it receives, so the peer passes
--- the same two keys the other way round. The algorithm is
--- ChaCha20-Poly1305. A message's nonce is how many messages went
--- before it in its direction, which is why each direction has a key of
--- its own: under one key both ends' first messages would share a
--- nonce. Derive the two from one secret with [`Hash.hkdf`], under two
--- `info` strings.
---
--- A channel is for messages that arrive whole and in order (a
--- stream's frames): one that is lost stops every later one from
--- opening. Raises when a key is not [`Cipher.key_length`] bytes, when
--- `counter_length` is not 8 or 12, and on a negative count.
---
---     local alice = Cipher.channel(to_bob, to_alice)
---     local bob = Cipher.channel(to_alice, to_bob)
---     assert(bob:open(alice:seal("hello")) == "hello")
function Cipher.channel(output_key: string, input_key: string, options?: Cipher.ChannelOptions): Cipher.Channel
  local o: Cipher.ChannelOptions = options or {}
  if #output_key ~= Cipher.key_length or #input_key ~= Cipher.key_length then
    error("cipher: a channel's key is 32 bytes", 2)
  end
  local length = o.counter_length or 8
  if length ~= 8 and length ~= Cipher.nonce_length then
    error("cipher: channel's counter_length must be 8 or 12", 2)
  end
  local format = if o.byte_order == "big" then ">I8" else "<I8" end
  local zeros_first = o.byte_order == "big" or length == 8
  local sent = count_of("sent", o.sent)
  local received = count_of("received", o.received)

  local function nonce(count: integer): string
    local counter = string.pack(format, count)
    if zeros_first then return "\0\0\0\0" .. counter end
    return counter .. "\0\0\0\0"
  end

  return {
    seal = function(_self: Cipher.Channel, plaintext: string, aad?: string): string
      if sent == math.maxinteger then
        error("cipher: the channel has sealed its last message", 2)
      end
      local sealed = raw.seal("chacha20-poly1305", output_key, nonce(sent), plaintext, aad)
      sent = sent + 1
      return sealed
    end,
    open = function(_self: Cipher.Channel, sealed: string, aad?: string): string?, string
      if received == math.maxinteger then
        return nil, "cipher: the channel has opened its last message"
      end
      local plaintext, why = raw.open("chacha20-poly1305", input_key, nonce(received), sealed, aad)
      if plaintext == nil then return nil, why end
      received = received + 1
      return plaintext, ""
    end,
  }
end

--- The X25519 public key (RFC 7748) of a private key, 32 bytes each:
--- what a party sends the other. A private key is 32 bytes nobody can
--- guess, `Rand.entropy(32)` of [`cosmic.rand`]; it is clamped as the
--- RFC says, so any 32 bytes are one. Raises on another length, and on
--- any other failure.
function Cipher.x25519_public(private: string): string
  return raw.x25519_public(private)
end

--- The 32-byte secret that `private` and the peer's public key share,
--- and "": the peer computes the same bytes from its private key and
--- this party's public key, and nobody who saw only the public keys
--- can. nil and why when `peer_public` is a point of low order, which
--- makes the secret all zero bytes whatever the private key: a peer
--- that sends one is choosing the secret, not agreeing on it. Raises
--- when either key is not 32 bytes, and on any other failure.
---
--- The secret is not a key yet. Pass it through a key derivation
--- ([`Hash.hkdf`]), together with both public keys, and use what that
--- answers as [`Cipher.seal`]'s key. Public keys are not authenticated here: a
--- party that must know who the peer is checks the peer's public key
--- against one it already trusts.
function Cipher.x25519(private: string, peer_public: string): string?, string
  return raw.x25519(private, peer_public)
end

return Cipher
