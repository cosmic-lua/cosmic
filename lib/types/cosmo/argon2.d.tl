-- type declarations for cosmo.argon2

local record Variant
  -- Opaque variant type (userdata)
end

local record Variants
  argon2_id: Variant
  argon2_i: Variant
  argon2_d: Variant
end

local record Config
  --- Memory cost in kibibytes (default: 4096)
  m_cost: number
  --- Time cost / iterations (default: 3)
  t_cost: number
  --- Parallelism factor (default: 1)
  parallelism: number
  --- Output hash length in bytes (default: 32)
  hash_len: number
  --- Variant type (default: argon2_id)
  variant: Variant
end

local record argon2
  type Variant = Variant
  type Variants = Variants
  type Config = Config

  --- Argon2 algorithm variants
  variants: Variants

  --- Hashes password.
  --- This is consistent with the README of the reference implementation:
  --- >: assert(argon2.hash_encoded("password", "somesalt", {
  --- variant = argon2.variants.argon2_i,
  --- hash_len = 24,
  --- t_cost = 2,
  --- }))
  --- `salt` is a nonce value used to hash the string.
  --- `config.m_cost` is the memory hardness in kibibytes, which defaults
  --- to 4096 (4 mibibytes). It's recommended that this be tuned upwards.
  --- `config.t_cost` is the number of iterations, which defaults to 3.
  --- `config.parallelism` is the parallelism factor, which defaults to 1.
  --- `config.hash_len` is the number of desired bytes in hash output,
  --- which defaults to 32.
  --- `config.variant` may be:
  --- - `argon2.variants.argon2_id` blend of other two methods [default]
  --- - `argon2.variants.argon2_i` maximize resistance to side-channel attacks
  --- - `argon2.variants.argon2_d` maximize resistance to gpu cracking attacks
  hash_encoded: function(pass: string, salt: string, config: Config): string
  --- Verifies password, e.g.
  --- >: argon2.verify(
  --- "p=4$c29tZXNhbHQ$RdescudvJCsgt3ub+b+dWRWJTmaaJObG",
  --- true
  verify: function(encoded: string, pass: string): boolean
end

return argon2

