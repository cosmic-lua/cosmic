--- @kind language
-- The Lua standard library's declarations, as the new checker reads them: the trust boundary of the type layer, the typing
-- the checker takes without proof.
-- Auditing or changing a declaration is an edit of this file.
--
-- A function that returns nil where Lua does says so (`string.find`, `tonumber`, `math.tointeger`), one that changes a
-- collection it is given takes it `mut`, and one that the fork types by a special case in its checker (`assert`,
-- `math.abs`) is declared by overloads, and `math.max` and `math.min` over a `Numeric` type parameter. `pcall`, `xpcall` and the `coroutine` library are typed over
-- `Coroutine<Y, R, S>`, which the language has no other form for.
do
  -- What a coroutine's body is given to yield through, since `coroutine.yield` is dynamically scoped and no type says
  -- which coroutine a bare `yield` feeds: `Y` is what it yields and `S` what it is sent.
  global record Yielder<Y, S>
    userdata

    yield: function(yielder: Yielder<Y, S>, value: Y): S
  end

  -- A coroutine: `Y` is what it yields, `R` what `resume` returns when its body returns and `S` what it is sent.
  global record Coroutine<Y, R, S>
    userdata
  end

  local enum FileStringMode
    "a" "l" "L" "*a" "*l" "*L"
  end

  local enum FileNumberMode
    "n" "*n"
  end

  local enum FileMode
    "a" "l" "L" "*a" "*l" "*L" "n" "*n"
  end

  -- TODO: provide the typed `coroutine` library in the runtime, once the runtime keeps only the globals a `.d.tl`
  -- declares: these declarations describe a body that is given a handle
  -- and a `Coroutine` that is not a thread, and the runtime has Lua's own `coroutine`, which [`cosmic.poll`] calls.
  global record coroutine
    close: function<Y, R, S>(co: Coroutine<Y, R, S>): (true) | (false, any)

    -- One overload for each form a body takes (a handle and a value, a handle, neither) and for each number of values it
    -- returns (none, one).
    create: function<Y, S>(f: function(Yielder<Y, S>, S)): Coroutine<Y, nil, S>
    create: function<Y, R, S>(f: function(Yielder<Y, S>, S): R): Coroutine<Y, R, S>
    create: function<Y>(f: function(Yielder<Y, nil>)): Coroutine<Y, nil, nil>
    create: function<Y, R>(f: function(Yielder<Y, nil>): R): Coroutine<Y, R, nil>
    create: function(f: function()): Coroutine<never, nil, nil>
    create: function<R>(f: function(): R): Coroutine<never, R, nil>

    isyieldable: function(): boolean

    resume: function<Y, R>(co: Coroutine<Y, R, nil>): (true, Y | R) | (false, any)
    resume: function<Y, R, S>(co: Coroutine<Y, R, S>, value: S): (true, Y | R) | (false, any)

    enum Status
      "suspended"
      "running"
      "normal"
      "dead"
    end

    status: function<Y, R, S>(co: Coroutine<Y, R, S>): Status

    wrap: function<Y, S>(f: function(Yielder<Y, S>, S)): function(S): Y?
    wrap: function<Y, R, S>(f: function(Yielder<Y, S>, S): R): function(S): Y | R
    wrap: function<Y>(f: function(Yielder<Y, nil>)): function(): Y?
    wrap: function<Y, R>(f: function(Yielder<Y, nil>): R): function(): Y | R
    wrap: function(f: function()): function()
    wrap: function<R>(f: function(): R): function(): R
  end

  global record debug
    -- The opaque value of a function's upvalue or a userdata's user value: no type of the language names a userdata, so
    -- the functions of `debug` that take or return one say this.
    record Userdata
      userdata
    end

    record GetInfoTable
      name: string
      namewhat: string
      source: string
      short_src: string
      linedefined: integer
      lastlinedefined: integer
      what: string
      currentline: integer
      istailcall: boolean
      nups: integer
      nparams: integer
      isvararg: boolean
      func: any
      activelines: {integer:boolean}
      ftransfer: integer
      ntransfer: integer
    end

    enum HookEvent
      "call" "tail call" "return" "line" "count"
    end

    type HookFunction = function(HookEvent, integer)

    type AnyFunction = function(...: any):any...

    debug: function()
    gethook: function<Y, R, S>(thread?: Coroutine<Y, R, S>): HookFunction?, integer

    getinfo: function<Y, R, S>(thread: Coroutine<Y, R, S>, f: AnyFunction, what?: string): GetInfoTable
    getinfo: function<Y, R, S>(thread: Coroutine<Y, R, S>, level: integer, what?: string): GetInfoTable?
    getinfo: function(f: AnyFunction, what?: string): GetInfoTable
    getinfo: function(level: integer, what?: string): GetInfoTable?

    getlocal: function<Y, R, S>(thread: Coroutine<Y, R, S>, f: AnyFunction, index: integer): string?
    getlocal: function<Y, R, S>(thread: Coroutine<Y, R, S>, level: integer, index: integer): string?, any
    getlocal: function(f: AnyFunction, index: integer): string?
    getlocal: function(level: integer, index: integer): string?, any

    getmetatable: function<T>(value: T): metatable<T>?
    getregistry: function(): any
    getupvalue: function(f: AnyFunction, up: integer): string?, any
    getuservalue: function(u: Userdata, n?: integer): any, boolean

    sethook: function<Y, R, S>(thread: Coroutine<Y, R, S>, hook: HookFunction, mask: string, count?: integer)
    sethook: function(hook: HookFunction, mask: string, count?: integer)

    setlocal: function<Y, R, S>(thread: Coroutine<Y, R, S>, level: integer, index: integer, value: any): string?
    setlocal: function(level: integer, index: integer, value: any): string?

    setmetatable: function<T>(value: T, mt: metatable<T>): T
    setupvalue: function(f: AnyFunction, up: integer, value: any): string?
    setuservalue: function(udata: Userdata, value: any, n: integer): Userdata

    traceback: function<Y, R, S>(thread: Coroutine<Y, R, S>, message?: string, level?: integer): string
    traceback: function(message?: string, level?: integer): string
    traceback: function(message: any): any

    upvalueid: function(f: AnyFunction, n: integer): Userdata?
    upvaluejoin: function(f1: AnyFunction, n1: integer, f2: AnyFunction, n2: integer)
  end

  global record io
    enum OpenMode
       "r"   "w"   "a"   "r+"   "w+"   "a+"
       "rb"  "wb"  "ab"  "r+b"  "w+b"  "a+b"
      "*r"  "*w"  "*a"  "*r+"  "*w+"  "*a+"
      "*rb" "*wb" "*ab" "*r+b" "*w+b" "*a+b"
    end

    enum FileType
      "file"
      "closed file"
    end

    close: function(file?: FILE)
    input: function(file?: FILE | string): FILE
    flush: function()

    lines: function(filename?: string): (function(): (string))
    lines: function(filename?: string, ...: FileNumberMode): (function(): (number...))
    lines: function(filename?: string, ...: (integer | FileStringMode)): (function(): (string...))
    lines: function(filename?: string, ...: (integer | FileMode)): (function(): ((string | number)...))
    lines: function(filename?: string, ...: (integer | string)): (function(): (string...))

    open: function(filename: string, mode?: OpenMode): FILE?, string?, integer?
    output: function(file?: FILE | string): FILE
    popen: function(prog: string, mode?: OpenMode): FILE?, string?, integer?

    read: function(): string?
    read: function(...: FileNumberMode): number...
    read: function(...: (integer | FileStringMode)): string...
    read: function(...: (integer | FileMode)): ((string | number)...)
    read: function(...: (integer | string)): (string...)

    stderr: FILE
    stdin: FILE
    stdout: FILE
    tmpfile: function(): FILE?, string?, integer?
    type: function(obj: any): FileType?
    write: function(...: (string | number)): FILE?, string?, integer?
  end

  global record FILE
    userdata

    enum SeekWhence
      "set" "cur" "end"
    end

    enum SetVBufMode
      "no" "full" "line"
    end

    close: function(file: FILE): boolean?, string?, integer?
    flush: function(file: FILE): boolean?, string?, integer?

    lines: function(file: FILE): (function(): (string))
    lines: function(file: FILE, ...: FileNumberMode): (function(): (number...))
    lines: function(file: FILE, ...: (integer | FileStringMode)): (function(): (string...))
    lines: function(file: FILE, ...: (integer | FileMode)): (function(): ((string | number)...))
    lines: function(file: FILE, ...: (integer | string)): (function(): (string...))

    read: function(file: FILE): string?
    read: function(file: FILE, ...: FileNumberMode): number...
    read: function(file: FILE, ...: (integer | FileStringMode)): string...
    read: function(file: FILE, ...: (integer | FileMode)): ((string | number)...)
    read: function(file: FILE, ...: (integer | string)): (string...)

    seek: function(file: FILE, whence?: SeekWhence, offset?: integer): integer?, string?, integer?
    setvbuf: function(file: FILE, mode: SetVBufMode, size?: integer): boolean?, string?, integer?

    write: function(file: FILE, ...: (string | number)): FILE?, string?, integer?

    __close: function(file: FILE)
  end

  global record math
    abs: function(x: integer): integer
    abs: function(x: number): number
    acos: function(x: number): number
    asin: function(x: number): number
    atan: function(y: number, x?: number): number
    atan2: function(y: number, x: number): number
    ceil: function(x: number): integer
    cos: function(x: number): number
    cosh: function(x: number): number
    deg: function(x: number): number
    exp: function(x: number): number
    floor: function(x: number): integer

    fmod: function(x: integer, y: integer): integer
    fmod: function(x: number, y: number): number

    frexp: function(x: number): number, integer
    huge: number
    ldexp: function(m: number, e: integer): number
    log: function(x: number, base?: number): number
    log10: function(x: number): number

    max: function<N is Numeric>(x: N, ...: N): N

    maxinteger: integer

    min: function<N is Numeric>(x: N, ...: N): N

    mininteger: integer

    -- An integer is its own integral part; a float's is a float (`math.modf(3.7)` is `3.0, 0.7`).
    modf: function(x: integer): integer, number
    modf: function(x: number): number, number
    pi: number
    pow: function(x: number, y: number): number
    rad: function(x: number): number

    random: function(m: integer, n?: integer): integer
    random: function(): number

    randomseed: function(x?: integer, y?: integer): integer, integer
    sin: function(x: number): number
    sinh: function(x: number): number
    sqrt: function(x: number): number
    tan: function(x: number): number
    tanh: function(x: number): number
    tointeger: function(x: any): integer?
    -- What kind of number `x` is, nil where it is no number.
    enum NumberType
      "integer" "float"
    end

    type: function(x: any): NumberType?
    ult: function(m: integer, n: integer): boolean
  end

  global record os
    record DateTable
      year: integer
      month: integer
      day: integer
      hour: integer
      min: integer
      sec: integer
      wday: integer
      yday: integer
      isdst: boolean
    end

    enum DateMode
      "!*t" "*t"
    end

    clock: function(): number

    date: function(format: DateMode, time?: integer): DateTable
    date: function(format?: string, time?: integer): string

    difftime: function(t2: integer, t1: integer): number
    -- All three values every time: the status is `true` or nil, then "exit" or "signal", then the code.
    execute: function(command: string): boolean?, string, integer
    exit: function(code?: (integer | boolean), close?: boolean)
    getenv: function(varname: string): string?
    remove: function(filename: string): boolean?, string?, integer?
    rename: function(oldname: string, newname: string): boolean?, string?, integer?
    setlocale: function(locale: string, category?: string): string?
    time: function(t?: DateTable): integer
    tmpname: function(): string
  end

  global record package
    config: string
    cpath: string
    loaded: {string:any}
    loadlib: function(libname: string, funcname: string): ((function(...: any): any...)?, string?, string?)
    loaders: { (function(string): (function(modname?: string, extra?: any): (any), any)) }
    path: string
    preload: {string : function(modname?: string, extra?: any): (any) }
    mut searchers: { (function(string): (function(modname?: string, extra?: any): (any), any)) }
    searchpath: function(name: string, path: string, sep?: string, rep?: string): string?, string?

    -- A program outside the tree may not read `package` ([`build.project_refusals`]): it would be handed the raw table of a
    -- C binding by `package.searchers[n]("cosmic.net")`, which unchecked calls then reach. The tree check `package_readers`
    -- holds the tree to the files that read it.
  end

  global record string
    byte: function(s: string, i?: integer): integer?
    byte: function(s: string, i: integer, j?: integer): integer...

    char: function(...: integer): string
    dump: function(f: function(...: any): (any), strip?: boolean): string
    -- The new checker types the captures of `find`, `match` and `gmatch` and the arguments of a `gsub` callback from a literal
    -- pattern (lang/check.tl, [`Calls.refine`]): a position capture `()` is an integer, and these declarations hold
    -- for a pattern that is no literal, where every capture is a string.
    find: function(s: string, pattern: string, init?: integer, plain?: boolean): integer?, integer?, string...
    format: function(formatstring: string, ...: any): string
    gmatch: function(s: string, pattern: string, init?: integer): (function(): string...)

    gsub: function(s: string, pattern: string, repl: string, n?: integer): string, integer
    gsub: function(s: string, pattern: string, repl: {string:string|integer|number}, n?: integer): string, integer
    gsub: function(s: string, pattern: string, repl: {integer:string|integer|number}, n?: integer): string, integer
    gsub: function(s: string, pattern: string, repl: function(): ((string | number)?), n?: integer): string, integer
    gsub: function(s: string, pattern: string, repl: function(string): ((string | number)?), n?: integer): string, integer
    gsub: function(s: string, pattern: string, repl: function(string, string): ((string | number)?), n?: integer): string, integer
    gsub: function(s: string, pattern: string, repl: function(string, string, string): ((string | number)?), n?: integer): string, integer

    len: function(s: string): integer
    lower: function(s: string): string
    match: function(s: string, pattern: string, init?: integer): string...
    pack: function(fmt: string, ...: any): string
    packsize: function(fmt: string): integer
    rep: function(s: string, n: integer, sep?: string): string
    reverse: function(s: string): string
    sub: function(s: string, i: integer, j?: integer): string
    unpack: function(fmt: string, s: string, pos?: integer): any...
    upper: function(s: string): string
  end

  global record table
    type SortFunction = function<A>(A, A): boolean

    record PackTable<A>
      is {A}

      n: integer
    end

    concat: function(list: {(string | number)}, sep?: string, i?: integer, j?: integer): string

    insert: function<A>(list: mut {A}, pos: integer, value: A)
    insert: function<A>(list: mut {A}, value: A)

    move: function<A>(a1: mut {A}, f: integer, e: integer, t: integer): mut {A}
    move: function<A>(a1: {A}, f: integer, e: integer, t: integer, a2: mut {A}): mut {A}

    pack: function<T>(...: T): PackTable<T>
    pack: function(...: any): PackTable<any>

    remove: function<A>(list: mut {A}, pos?: integer): A?
    sort: function<A is Ordered>(list: mut {A}, comp?: function(A, A): boolean)
    sort: function<A>(list: mut {A}, comp: function(A, A): boolean)

    unpack: function<A>(list: {A}, i?: integer, j?: integer): A...
  end

  global record utf8
    char: function(...: integer): string
    charpattern: string
    codepoint: function(s: string, i?: integer, j?: integer, lax?: boolean): integer...
    codes: function(s: string, lax?: boolean): (function(s: string, i?: integer): (integer, integer), string, integer)
    len: function(s: string, i?: integer, j?: integer, lax?: boolean): integer?, integer?
    offset: function(s: string, n: integer, i?: integer): integer?
  end

  local record StandardLibrary
    enum CollectGarbageCommand
      "collect"
      "count"
      "stop"
      "restart"
    end

    enum CollectGarbageSetValue
      "setpause"
      "setstepmul"
    end

    enum CollectGarbageStep
      "step"
    end

    enum CollectGarbageMode
      "incremental"
      "generational"
    end

    enum CollectGarbageIsRunning
      "isrunning"
    end

    type LoadFunction = function(): string?

    enum LoadMode
      "b" "t" "bt"
    end

    type XpcallMsghFunction = function(any): any...

    -- What `type` returns: the name of a value's basic type, so a comparison with another name (`type(x) == "int"`) is
    -- refused (`enum_member`). An integer and a float are both "number": `math.type` tells them apart.
    enum Type
      "nil" "boolean" "number" "string" "table" "function" "thread" "userdata"
    end

    arg: {string}
    -- assert's declared argument strips the nil, so
    -- `local db = assert(open(p))` yields A rather than handing
    -- `A | nil` straight back.
    assert: function<A>(v: A?): A
    assert: function<A, B>(v: A?, message: B, ...: any): (A, B, any...)

    collectgarbage: function(opt?: CollectGarbageCommand): number
    collectgarbage: function(opt: CollectGarbageStep, arg?: integer): boolean
    collectgarbage: function(opt: CollectGarbageMode, pause?: integer, stepmul?: integer, stepsize?: integer): string
    collectgarbage: function(opt: CollectGarbageSetValue, value: integer): number
    collectgarbage: function(opt: CollectGarbageIsRunning): boolean
    collectgarbage: function(opt: string, arg?: number): (boolean | number | string)

    dofile: function(filename?: string): any...

    error: function(message?: any, level?: integer): never
    getmetatable: function<T>(object: T): metatable<T>?
    ipairs: function<A>(t: {A}): (function({A}, integer): (integer, A), {A}, integer)

    -- A chunk given no environment is loaded as text and reads a table of its own: the base functions that reach nothing
    -- else and share no state with the host (not `collectgarbage` or `warn`), and copies of `coroutine`, `math`, `string`,
    -- `table` and `utf8` without `string.dump`, `math.random` and `math.randomseed`. A chunk that assigns into a library
    -- changes its copy; `getmetatable("x")` returns a copy of the string metatable. A method call on a string,
    -- `("x"):rep(2)`, goes through the real metatable to the host's own library, which the chunk cannot change (so
    -- `("x").dump` reaches the host's `string.dump`, which is harmless: the chunk can load text alone). `print` writes
    -- to the host's standard output. The chunk
    -- holds neither `require` nor `package`, `_G` or `_ENV`, so it cannot load a module the build does not see, and the
    -- `load` it reaches takes text alone. A program that needs more passes the environment, the globals for all of them.
    --
    -- A chunk given an environment may be bytecode (mode "b" or "bt", as `string.dump` writes it), and bytecode is
    -- trusted code. Lua checks no bytecode, so a crafted chunk breaks the VM's memory safety: it reads and writes
    -- memory it was given no reference to and reaches anything the process can, whatever environment it is given. Load
    -- bytecode only from this program's own `string.dump` or a build of yours, never from a file, a peer or a store
    -- another program writes; load anything else with mode "t". `loadfile` and `dofile` are removed, so a file's bytes
    -- reach a chunk only through this `load`, under the same modes. A TODO in core/surface.c, at `load_with`, is to refuse
    -- bytecode here too.
    --
    -- The environment of the chunk is a table: an empty literal takes the type `{string: any}`, and the overloads over `V` are
    -- for a table of one value type (`{string: integer}`).
    --
    -- TODO: take an environment that is `mut {string: any}` alone, and drop the overloads over `V`, once every caller that
    -- passes one declares it so: the chunk assigns the globals it defines into it, so a table of one value type is unsound
    -- there.
    load: function(chunk: (string | LoadFunction), chunkname?: string, mode?: LoadMode, env?: {string:any}): ((function(...: any): any...)?, string?)
    load: function(chunk: (string | LoadFunction), chunkname?: string, mode?: string, env?: {string:any}): ((function(...: any): any...)?, string?)
    load: function<V>(chunk: (string | LoadFunction), chunkname?: string, mode?: LoadMode, env?: {string:V}): ((function(...: any): any...)?, string?)
    load: function<V>(chunk: (string | LoadFunction), chunkname?: string, mode?: string, env?: {string:V}): ((function(...: any): any...)?, string?)

    loadfile: function(filename?: string, mode?: LoadMode, env?: {string:any}): ((function(...: any): any...)?, string?)
    loadfile: function(filename?: string, mode?: string, env?: {string:any}): ((function(...: any): any...)?, string?)
    loadfile: function<V>(filename?: string, mode?: LoadMode, env?: {string:V}): ((function(...: any): any...)?, string?)
    loadfile: function<V>(filename?: string, mode?: string, env?: {string:V}): ((function(...: any): any...)?, string?)

    next: function<K is Key, V>(t: {K:V}, index?: K): (K?, V?)
    next: function<A>(t: {A}, index?: integer): (integer?, A?)

    pairs: function<K is Key, V>(t: {K:V}): (function(t: {K:V}, index?: K):(K, V), {K:V}, K)
    -- One overload for each number of values passed on (0 to 6 for `pcall`, 0 to 3 for `xpcall`) and returned (0 to 3): the
    -- result is `(true, R...) | (false, any)`, and for `xpcall` `(false, H | string)`, what the message handler returns or
    -- the string Lua gives when the handler itself raises.
    --
    -- TODO: accept a function that returns `T...` as an argument of `pcall` and `xpcall`, once the grammar spells a list
    -- with a tail among alternatives (`plist`): `(true, R...) | (false, any)`
    -- cannot be written until then, and a call that passes one is `overload_none`.
    pcall: function(f: (function())): (true) | (false, any)
    pcall: function<R1>(f: (function(): R1)): (true, R1) | (false, any)
    pcall: function<R1, R2>(f: (function(): (R1, R2))): (true, R1, R2) | (false, any)
    pcall: function<R1, R2, R3>(f: (function(): (R1, R2, R3))): (true, R1, R2, R3) | (false, any)
    pcall: function<A1>(f: (function(A1)), arg1: A1): (true) | (false, any)
    pcall: function<A1, R1>(f: (function(A1): R1), arg1: A1): (true, R1) | (false, any)
    pcall: function<A1, R1, R2>(f: (function(A1): (R1, R2)), arg1: A1): (true, R1, R2) | (false, any)
    pcall: function<A1, R1, R2, R3>(f: (function(A1): (R1, R2, R3)), arg1: A1): (true, R1, R2, R3) | (false, any)
    pcall: function<A1, A2>(f: (function(A1, A2)), arg1: A1, arg2: A2): (true) | (false, any)
    pcall: function<A1, A2, R1>(f: (function(A1, A2): R1), arg1: A1, arg2: A2): (true, R1) | (false, any)
    pcall: function<A1, A2, R1, R2>(f: (function(A1, A2): (R1, R2)), arg1: A1, arg2: A2): (true, R1, R2) | (false, any)
    pcall: function<A1, A2, R1, R2, R3>(f: (function(A1, A2): (R1, R2, R3)), arg1: A1, arg2: A2): (true, R1, R2, R3) | (false, any)
    pcall: function<A1, A2, A3>(f: (function(A1, A2, A3)), arg1: A1, arg2: A2, arg3: A3): (true) | (false, any)
    pcall: function<A1, A2, A3, R1>(f: (function(A1, A2, A3): R1), arg1: A1, arg2: A2, arg3: A3): (true, R1) | (false, any)
    pcall: function<A1, A2, A3, R1, R2>(f: (function(A1, A2, A3): (R1, R2)), arg1: A1, arg2: A2, arg3: A3): (true, R1, R2) | (false, any)
    pcall: function<A1, A2, A3, R1, R2, R3>(f: (function(A1, A2, A3): (R1, R2, R3)), arg1: A1, arg2: A2, arg3: A3): (true, R1, R2, R3) | (false, any)
    pcall: function<A1, A2, A3, A4>(f: (function(A1, A2, A3, A4)), arg1: A1, arg2: A2, arg3: A3, arg4: A4): (true) | (false, any)
    pcall: function<A1, A2, A3, A4, R1>(f: (function(A1, A2, A3, A4): R1), arg1: A1, arg2: A2, arg3: A3, arg4: A4): (true, R1) | (false, any)
    pcall: function<A1, A2, A3, A4, R1, R2>(f: (function(A1, A2, A3, A4): (R1, R2)), arg1: A1, arg2: A2, arg3: A3, arg4: A4): (true, R1, R2) | (false, any)
    pcall: function<A1, A2, A3, A4, R1, R2, R3>(f: (function(A1, A2, A3, A4): (R1, R2, R3)), arg1: A1, arg2: A2, arg3: A3, arg4: A4): (true, R1, R2, R3) | (false, any)
    pcall: function<A1, A2, A3, A4, A5>(f: (function(A1, A2, A3, A4, A5)), arg1: A1, arg2: A2, arg3: A3, arg4: A4, arg5: A5): (true) | (false, any)
    pcall: function<A1, A2, A3, A4, A5, R1>(f: (function(A1, A2, A3, A4, A5): R1), arg1: A1, arg2: A2, arg3: A3, arg4: A4, arg5: A5): (true, R1) | (false, any)
    pcall: function<A1, A2, A3, A4, A5, R1, R2>(f: (function(A1, A2, A3, A4, A5): (R1, R2)), arg1: A1, arg2: A2, arg3: A3, arg4: A4, arg5: A5): (true, R1, R2) | (false, any)
    pcall: function<A1, A2, A3, A4, A5, R1, R2, R3>(f: (function(A1, A2, A3, A4, A5): (R1, R2, R3)), arg1: A1, arg2: A2, arg3: A3, arg4: A4, arg5: A5): (true, R1, R2, R3) | (false, any)
    pcall: function<A1, A2, A3, A4, A5, A6>(f: (function(A1, A2, A3, A4, A5, A6)), arg1: A1, arg2: A2, arg3: A3, arg4: A4, arg5: A5, arg6: A6): (true) | (false, any)
    pcall: function<A1, A2, A3, A4, A5, A6, R1>(f: (function(A1, A2, A3, A4, A5, A6): R1), arg1: A1, arg2: A2, arg3: A3, arg4: A4, arg5: A5, arg6: A6): (true, R1) | (false, any)
    pcall: function<A1, A2, A3, A4, A5, A6, R1, R2>(f: (function(A1, A2, A3, A4, A5, A6): (R1, R2)), arg1: A1, arg2: A2, arg3: A3, arg4: A4, arg5: A5, arg6: A6): (true, R1, R2) | (false, any)
    pcall: function<A1, A2, A3, A4, A5, A6, R1, R2, R3>(f: (function(A1, A2, A3, A4, A5, A6): (R1, R2, R3)), arg1: A1, arg2: A2, arg3: A3, arg4: A4, arg5: A5, arg6: A6): (true, R1, R2, R3) | (false, any)
    print: function(...: any)
    rawequal: function(v1: any, v2: any): boolean

    rawget: function<K is Key, V>(t: {K:V}, index: K): V?
    rawget: function(t: any, index: any): any

    rawlen: function<A>(v: {A}): integer

    -- TODO: a record whose fields all share a type reads as that map, so `rawset(r, "undeclared", v)` still writes a key it does not declare; refuse it once a record no longer reads as a map (closed records).
    rawset: function<K is Key, V>(t: mut {K:V}, index: K, value: V): mut {K:V}

    require: function(modname: string): any

    select: function<T>(n: integer, ...: T): T...
    select: function(n: integer, ...: any): any...
    select: function(n: string, ...: any): integer

    setmetatable: function<T>(t: T, mt: metatable<T>): T

    tonumber: function(e: any): number?
    tonumber: function(e: any, base: integer): integer?

    tostring: function(v: any): string
    type: function(v: any): Type
    warn: function(msg: string, ...: string)
    xpcall: function<H>(f: (function()), msgh: (function(any): H)): (true) | (false, H | string)
    xpcall: function<R1, H>(f: (function(): R1), msgh: (function(any): H)): (true, R1) | (false, H | string)
    xpcall: function<R1, R2, H>(f: (function(): (R1, R2)), msgh: (function(any): H)): (true, R1, R2) | (false, H | string)
    xpcall: function<R1, R2, R3, H>(f: (function(): (R1, R2, R3)), msgh: (function(any): H)): (true, R1, R2, R3) | (false, H | string)
    xpcall: function<A1, H>(f: (function(A1)), msgh: (function(any): H), arg1: A1): (true) | (false, H | string)
    xpcall: function<A1, R1, H>(f: (function(A1): R1), msgh: (function(any): H), arg1: A1): (true, R1) | (false, H | string)
    xpcall: function<A1, R1, R2, H>(f: (function(A1): (R1, R2)), msgh: (function(any): H), arg1: A1): (true, R1, R2) | (false, H | string)
    xpcall: function<A1, R1, R2, R3, H>(f: (function(A1): (R1, R2, R3)), msgh: (function(any): H), arg1: A1): (true, R1, R2, R3) | (false, H | string)
    xpcall: function<A1, A2, H>(f: (function(A1, A2)), msgh: (function(any): H), arg1: A1, arg2: A2): (true) | (false, H | string)
    xpcall: function<A1, A2, R1, H>(f: (function(A1, A2): R1), msgh: (function(any): H), arg1: A1, arg2: A2): (true, R1) | (false, H | string)
    xpcall: function<A1, A2, R1, R2, H>(f: (function(A1, A2): (R1, R2)), msgh: (function(any): H), arg1: A1, arg2: A2): (true, R1, R2) | (false, H | string)
    xpcall: function<A1, A2, R1, R2, R3, H>(f: (function(A1, A2): (R1, R2, R3)), msgh: (function(any): H), arg1: A1, arg2: A2): (true, R1, R2, R3) | (false, H | string)
    xpcall: function<A1, A2, A3, H>(f: (function(A1, A2, A3)), msgh: (function(any): H), arg1: A1, arg2: A2, arg3: A3): (true) | (false, H | string)
    xpcall: function<A1, A2, A3, R1, H>(f: (function(A1, A2, A3): R1), msgh: (function(any): H), arg1: A1, arg2: A2, arg3: A3): (true, R1) | (false, H | string)
    xpcall: function<A1, A2, A3, R1, R2, H>(f: (function(A1, A2, A3): (R1, R2)), msgh: (function(any): H), arg1: A1, arg2: A2, arg3: A3): (true, R1, R2) | (false, H | string)
    xpcall: function<A1, A2, A3, R1, R2, R3, H>(f: (function(A1, A2, A3): (R1, R2, R3)), msgh: (function(any): H), arg1: A1, arg2: A2, arg3: A3): (true, R1, R2, R3) | (false, H | string)
    _VERSION: string
  end

  global arg <const> = StandardLibrary.arg
  global assert <const> = StandardLibrary.assert
  global collectgarbage <const> = StandardLibrary.collectgarbage
  global dofile <const> = StandardLibrary.dofile
  global error <const> = StandardLibrary.error
  global getmetatable <const> = StandardLibrary.getmetatable
  global load <const> = StandardLibrary.load
  global loadfile <const> = StandardLibrary.loadfile
  global next <const> = StandardLibrary.next
  global pairs <const> = StandardLibrary.pairs
  global pcall <const> = StandardLibrary.pcall
  global print <const> = StandardLibrary.print
  global rawequal <const> = StandardLibrary.rawequal
  global rawget <const> = StandardLibrary.rawget
  global rawlen <const> = StandardLibrary.rawlen
  global rawset <const> = StandardLibrary.rawset
  global require <const> = StandardLibrary.require
  global select <const> = StandardLibrary.select
  global setmetatable <const> = StandardLibrary.setmetatable
  global tostring <const> = StandardLibrary.tostring
  global tonumber <const> = StandardLibrary.tonumber
  global ipairs <const> = StandardLibrary.ipairs
  global type <const> = StandardLibrary.type
  global xpcall <const> = StandardLibrary.xpcall
  global _VERSION <const> = StandardLibrary._VERSION
end
