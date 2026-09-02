# Write a CLI script

steps for a small tool that reads a file, transforms it, and prints the
result, for a reader who knows Teal and the `cosmic.*` modules.

the shape is: arguments, read, decode, transform, encode, print. every
stage can fail. every failure prints a message and exits nonzero.

## the bare script

1. guard the argument. `arg[1]` is `string | nil` at runtime, and the
   checker does not guard it for you. print a usage line and exit when
   it is missing.
2. read the input with `fs.read`. a failure is `nil, message`.
3. decode with `json.decode_array`. it returns `{any} | nil`, so no cast
   is needed. a top-level value that is not an array is a failure.
   `is {any}` narrows the value in the positive branch.
4. transform the value.
5. encode with `json.encode`. capture its error return. do not pass the
   call straight to `print`.
6. print the result. return an `integer` from `main`, because `os.exit`
   rejects `number`.

```teal
local fs = require("cosmic.fs")
local json = require("cosmic.json")

local function die(msg: string)
  io.stderr:write("error: " .. msg .. "\n")
  os.exit(1)
end

local function main(): integer
  local path = arg[1]
  if path == nil then
    die("usage: tool.tl <input.json>")
  end
  local data, read_err = fs.read(path)
  if not data then
    die("cannot read '" .. path .. "': " .. read_err)
  end
  local items, decode_err = json.decode_array(data)
  if items is {any} then
    -- transform: count the items
    local result = {count = #items}

    local encoded, encode_err = json.encode(result)
    if encode_err then
      die("encode failed: " .. encode_err)
    end
    print(encoded)
    return 0
  end
  die("invalid JSON: " .. decode_err)
  return 1
end

os.exit(main())
```

`json.decode_object` is the sibling for a top-level object. `json.decode`
returns `any` for the case where the shape is not known.

## with `cosmic.main`

`cosmic.main` passes the arguments in, writes your error return to
stderr, and exits with your code. a failed stage is an early return with
the code and the message, and `die` goes away.

1. hand `cosmic.main` a function of `(args, env)`.
2. guard `args[1]` with an early return. the scalar narrows below the
   guard for plain uses.
3. return `1, message` from every failed stage.
4. write the result to `env.stdout` and return `0`.

```teal
local cosmic = require("cosmic")
local fs = require("cosmic.fs")
local json = require("cosmic.json")

cosmic.main(function(args: {string}, env: cosmic.Env): number, string
    local path = args[1]
    if not path then
      return 1, "usage: tool.tl <input.json>"
    end
    local data, read_err = fs.read(path)
    if not data then
      return 1, "cannot read '" .. path .. "': " .. read_err
    end
    local items, decode_err = json.decode_array(data)
    if items is {any} then
      local encoded, encode_err = json.encode({count = #items})
      if encode_err then
        return 1, "encode failed: " .. encode_err
      end
      env.stdout:write(encoded .. "\n")
      return 0
    end
    return 1, "invalid JSON: " .. decode_err
  end)
```

`cosmic.main` does not check `proc.is_main()`. a file that is both a
module and a script asks in its own chunk, then calls `cosmic.main`
inside the guard.

`cosmic --docs cosmic.json`, `cosmic --docs cosmic.fs` and
`cosmic --docs cosmic` have the signatures. `cosmic --docs howto.narrow-nil`
has the narrowing steps.
