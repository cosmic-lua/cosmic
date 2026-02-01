# argon2

Type declarations for the `argon2` module.

## Types

### Variant

### Variants

```teal
local record Variants
  argon2_id: Variant
  argon2_i: Variant
  argon2_d: Variant
end
```

### Config

```teal
local record Config
  --  Memory cost in kibibytes (default: 4096)
  m_cost: number
  --  Time cost / iterations (default: 3)
  t_cost: number
  --  Parallelism factor (default: 1)
  parallelism: number
  --  Output hash length in bytes (default: 32)
  hash_len: number
  --  Variant type (default: argon2_id)
  variant: Variant
end
```

### argon2 Constants

Constants defined in the argon2 module.

```teal
local record argon2 Constants
  --  Argon2 algorithm variants
  variants: Variants
end
```

## Functions

### hash_encoded

```teal
function hash_encoded(pass: string, salt: string, config: Config): string
```

 Hashes password.
 This is consistent with the README of the reference implementation:
 >: assert(argon2.hash_encoded("password", "somesalt", {
 variant = argon2.variants.argon2_i,
 hash_len = 24,
 t_cost = 2,
 }))
 `salt` is a nonce value used to hash the string.
 `config.m_cost` is the memory hardness in kibibytes, which defaults
 to 4096 (4 mibibytes). It's recommended that this be tuned upwards.
 `config.t_cost` is the number of iterations, which defaults to 3.
 `config.parallelism` is the parallelism factor, which defaults to 1.
 `config.hash_len` is the number of desired bytes in hash output,
 which defaults to 32.
 `config.variant` may be:
 - `argon2.variants.argon2_id` blend of other two methods [default]
 - `argon2.variants.argon2_i` maximize resistance to side-channel attacks
 - `argon2.variants.argon2_d` maximize resistance to gpu cracking attacks

**Parameters:**

- `pass` (string)
- `salt` (string)
- `config` (Config)

**Returns:**

- string

### verify

```teal
function verify(encoded: string, pass: string): boolean
```

 Verifies password, e.g.
 >: argon2.verify(
 "p=4$c29tZXNhbHQ$RdescudvJCsgt3ub+b+dWRWJTmaaJObG",
 true

**Parameters:**

- `encoded` (string)
- `pass` (string)

**Returns:**

- boolean
