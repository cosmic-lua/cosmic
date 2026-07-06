-- type declarations for cosmo.argon2
-- GENERATED from cosmopolitan's definitions.lua by lib/types/gentype.tl.
-- Do not edit by hand. Regenerate with: bin/make regen-types

local record Config
  --- the memory hardness in kibibytes, which defaults to 4096 (4 mibibytes). It's recommended that this be tuned upwards.
  m_cost: number
  --- the number of iterations, which defaults to `3`.
  t_cost: number
  --- the parallelism factor, which defaults to `1`.
  parallelism: number
  --- the number of desired bytes in hash output, which defaults to 32.
  hash_len: number
  --- the Argon2 variant: `"argon2id"` blend of other two methods [default], `"argon2i"` maximize resistance to side-channel attacks, or `"argon2d"` maximize resistance to gpu cracking attacks
  variant: string
end

local record argon2
  type Config = Config

  --- Hashes password.
  --- This is consistent with the README of the reference implementation:
  ---     >: assert(argon2.hash_encoded("password", "somesalt", {
  ---         variant = "argon2i",
  ---         hash_len = 24,
  ---         t_cost = 2,
  ---     }))
  --- `salt` is a nonce value used to hash the string. It is optional: when it is
  --- `nil` or omitted, 16 random bytes are generated with a CSPRNG.
  --- `config.m_cost` is the memory hardness in kibibytes, which defaults
  --- to 4096 (4 mibibytes). It's recommended that this be tuned upwards.
  --- `config.t_cost` is the number of iterations, which defaults to 3.
  --- `config.parallelism` is the parallelism factor, which defaults to 1.
  --- `config.hash_len` is the number of desired bytes in hash output,
  --- which defaults to 32.
  --- `config.variant` may be:
  --- - `"argon2id"` blend of other two methods [default]
  --- - `"argon2i"` maximize resistance to side-channel attacks
  --- - `"argon2d"` maximize resistance to gpu cracking attacks
  hash_encoded: function(pass: string, salt?: string, config?: Config): string, string | nil
  --- Verifies a password against an encoded hash, e.g.
  ---     >: argon2.verify(encoded, "password")
  ---     true
  --- Returns `true` when the password matches. A plain mismatch returns
  --- `false` (with no error). A malformed `encoded` string returns
  --- `false, err`.
  verify: function(encoded: string, pass: string): boolean, string | nil
end

return argon2
