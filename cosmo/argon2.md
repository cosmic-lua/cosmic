# argon2

Type declarations for the `argon2` module.

## Types

### Variant

 An opaque handle identifying an Argon2 hashing variant. The available
 variants live in the `argon2.variants` table.

### Variants

```teal
local record Variants
  --  blend of other two methods [default]
  argon2_id: Variant
  --  maximize resistance to side-channel attacks
  argon2_i: Variant
  --  maximize resistance to gpu cracking attacks
  argon2_d: Variant
end
```

### Config

```teal
local record Config
  --  the memory hardness in kibibytes, which defaults to 4096 (4 mibibytes). It's recommended that this be tuned upwards.
  m_cost: number
  --  the number of iterations, which defaults to `3`.
  t_cost: number
  --  the parallelism factor, which defaults to `1`.
  parallelism: number
  --  the number of desired bytes in hash output, which defaults to 32.
  hash_len: number
  --  may be `argon2.variants.argon2_id` blend of other two methods [default], `argon2.variants.argon2_i` maximize resistance to side-channel attacks, or `argon2.variants.argon2_d` maximize resistance to gpu cracking attacks
  variant: Variant
end
```

### argon2 Constants

Constants defined in the argon2 module.

```teal
local record argon2 Constants
  --  Argon2 hashing variants. The fields are opaque read-only userdata
  --  values that can be fed to `config.variant` or `argon2.variant`.
  variants: Variants
end
```

## Functions

### hash_encoded

```teal
function hash_encoded(pass: string, salt: string, config: Config): string | nil, string
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

- string | nil
- string

### verify

```teal
function verify(encoded: string, pass: string): boolean | nil, string
```

 Verifies password, e.g.
     >: argon2.verify(
         "p=4$c29tZXNhbHQ$RdescudvJCsgt3ub+b+dWRWJTmaaJObG",
     true

**Parameters:**

- `encoded` (string)
- `pass` (string)

**Returns:**

- boolean | nil
- string

### m_cost

```teal
function m_cost(m_cost?: number): number
```

 Gets or sets the default memory hardness in kibibytes used by
 `argon2.hash_encoded` when its config omits `m_cost`. Called with no
 argument (or `nil`), it returns the current default (initially 4096).

**Parameters:**

- `m_cost` (number)

**Returns:**

- number

### t_cost

```teal
function t_cost(t_cost?: number): number
```

 Gets or sets the default number of iterations used by
 `argon2.hash_encoded` when its config omits `t_cost`. Called with no
 argument (or `nil`), it returns the current default (initially 3).

**Parameters:**

- `t_cost` (number)

**Returns:**

- number

### parallelism

```teal
function parallelism(parallelism?: number): number
```

 Gets or sets the default parallelism factor used by
 `argon2.hash_encoded` when its config omits `parallelism`. Called with
 no argument (or `nil`), it returns the current default (initially 1).

**Parameters:**

- `parallelism` (number)

**Returns:**

- number

### hash_len

```teal
function hash_len(hash_len?: number): number
```

 Gets or sets the default hash output length in bytes used by
 `argon2.hash_encoded` when its config omits `hash_len`. Called with no
 argument (or `nil`), it returns the current default (initially 32).

**Parameters:**

- `hash_len` (number)

**Returns:**

- number

### variant

```teal
function variant(variant: Variant): Variant
```

 Sets the default variant used by `argon2.hash_encoded` when its config
 omits `variant`, e.g. `argon2.variant(argon2.variants.argon2_id)`.
 Unlike the other configuration functions, the argument is required.
 The default is `argon2.variants.argon2_id`.

**Parameters:**

- `variant` (Variant)

**Returns:**

- Variant
