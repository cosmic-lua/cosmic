# argon2

Type declarations for the `argon2` module.

## Types

### Config

```teal
local record Config
  --  the memory hardness in kibibytes, which defaults to 4096 (4 mibibytes). It's recommended that this be tuned upwards.
  m_cost: integer
  --  the number of iterations, which defaults to `3`.
  t_cost: integer
  --  the parallelism factor, which defaults to `1`.
  parallelism: integer
  --  the number of desired bytes in hash output, which defaults to 32.
  hash_len: integer
  --  the Argon2 variant: `"argon2id"` blend of other two methods [default], `"argon2i"` maximize resistance to side-channel attacks, or `"argon2d"` maximize resistance to gpu cracking attacks
  variant: Variant
end
```

## Functions

### hash_encoded

```teal
function hash_encoded(pass: string, salt?: string, config?: Config): string | nil, string | nil
```

 Hashes password.
 This is consistent with the README of the reference implementation:
     >: assert(argon2.hash_encoded("password", "somesalt", {
         variant = "argon2i",
         hash_len = 24,
         t_cost = 2,
     }))
 `salt` is a nonce value used to hash the string. It is optional: when it is
 `nil` or omitted, 16 random bytes are generated with a CSPRNG.
 `config.m_cost` is the memory hardness in kibibytes, which defaults
 to 4096 (4 mibibytes). It's recommended that this be tuned upwards.
 `config.t_cost` is the number of iterations, which defaults to 3.
 `config.parallelism` is the parallelism factor, which defaults to 1.
 `config.hash_len` is the number of desired bytes in hash output,
 which defaults to 32.
 `config.variant` may be:
 - `"argon2id"` blend of other two methods [default]
 - `"argon2i"` maximize resistance to side-channel attacks
 - `"argon2d"` maximize resistance to gpu cracking attacks

**Parameters:**

- `pass` (string)
- `salt` (string)
- `config` (Config)

**Returns:**

- string | nil
- string | nil

### verify

```teal
function verify(encoded: string, pass: string): boolean, string | nil
```

 Verifies a password against an encoded hash, e.g.
     >: argon2.verify(encoded, "password")
     true
 Returns `true` when the password matches. A plain mismatch returns
 `false` (with no error). A malformed `encoded` string returns
 `false, err`.

**Parameters:**

- `encoded` (string)
- `pass` (string)

**Returns:**

- boolean
- string | nil
