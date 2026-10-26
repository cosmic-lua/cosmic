-- The Lua standard library's declarations, as the new checker reads them: the trust boundary of the type layer, the typing
-- the checker takes without proof.
-- Auditing or changing a declaration is an edit of this file.
--
-- A function that answers nil where Lua does says so (`string.find`, `tonumber`, `math.tointeger`), one that changes a
-- collection it is given takes it `mut`, and one that the fork types by a special case in its checker (`assert`,
-- `math.abs`, `math.max`) is declared by overloads. `pcall`, `xpcall` and the `coroutine` library are typed over
-- `Coroutine<Y, R, S>`, which the language has no other form for.
--
-- TODO: declare [`Fs.Scratch`], [`Signal.Guard`] and [`Child.Handle`] as classes in cosmic/fs.tl, cosmic/signal.tl and
-- cosmic/child.tl (each declares `__close` as a record field and builds its metatable by hand today), so that a `<close>`
-- local is a class, which the checker requires, and the TODOs in build/patch.tl, build/zig.tl, build/zig_fetch.tl and ci/ that wait on
-- ci/cosmic-driver.pin naming a release that declares them cannot be undone until a release does.
do
  -- What a coroutine's body is given to yield through, since `coroutine.yield` is dynamically scoped and no type says
  -- which coroutine a bare `yield` feeds: `Y` is what it yields and `S` what it is sent.
  global record Yielder<Y, S>
    userdata

    yield: function(Yielder<Y, S>, Y): S
  end

  -- A coroutine: `Y` is what it yields, `R` what it answers when its body returns and `S` what it is sent.
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

  -- TODO: provide the typed `coroutine` library in the runtime, once the runtime cut keeps only the globals a `.d.tl`
  -- declares (doc/plans/strict-teal.md, "the runtime cut"): these declarations describe a body that is given a handle
  -- and a `Coroutine` that is not a thread, and the runtime has Lua's own `coroutine`, which [`cosmic.poll`] calls.
  global record coroutine
    close: function<Y, R, S>(Coroutine<Y, R, S>): (true) | (false, any)

    -- One overload for each form a body takes (a handle and a value, a handle, neither) and for each number of values it
    -- answers (none, one).
    create: function<Y, S>(function(Yielder<Y, S>, S)): Coroutine<Y, nil, S>
    create: function<Y, R, S>(function(Yielder<Y, S>, S): R): Coroutine<Y, R, S>
    create: function<Y>(function(Yielder<Y, nil>)): Coroutine<Y, nil, nil>
    create: function<Y, R>(function(Yielder<Y, nil>): R): Coroutine<Y, R, nil>
    create: function(function()): Coroutine<never, nil, nil>
    create: function<R>(function(): R): Coroutine<never, R, nil>

    isyieldable: function(): boolean

    resume: function<Y, R>(Coroutine<Y, R, nil>): (true, Y | R) | (false, any)
    resume: function<Y, R, S>(Coroutine<Y, R, S>, S): (true, Y | R) | (false, any)

    enum Status
      "suspended"
      "running"
      "normal"
      "dead"
    end

    status: function<Y, R, S>(Coroutine<Y, R, S>): Status

    wrap: function<Y, S>(function(Yielder<Y, S>, S)): function(S): Y?
    wrap: function<Y, R, S>(function(Yielder<Y, S>, S): R): function(S): Y | R
    wrap: function<Y>(function(Yielder<Y, nil>)): function(): Y?
    wrap: function<Y, R>(function(Yielder<Y, nil>): R): function(): Y | R
    wrap: function(function()): function()
    wrap: function<R>(function(): R): function(): R
  end

  global record debug
    -- The opaque value of a function's upvalue or a userdata's user value: no type of the language names a userdata, so
    -- the functions of `debug` that take or answer one say this.
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
    gethook: function<Y, R, S>(arg1?: Coroutine<Y, R, S>): HookFunction?, integer

    getinfo: function<Y, R, S>(Coroutine<Y, R, S>, AnyFunction, arg3?: string): GetInfoTable
    getinfo: function<Y, R, S>(Coroutine<Y, R, S>, integer, arg3?: string): GetInfoTable?
    getinfo: function(AnyFunction, arg2?: string): GetInfoTable
    getinfo: function(integer, arg2?: string): GetInfoTable?

    getlocal: function<Y, R, S>(Coroutine<Y, R, S>, AnyFunction, integer): string?
    getlocal: function<Y, R, S>(Coroutine<Y, R, S>, integer, integer): string?, any
    getlocal: function(AnyFunction, integer): string?
    getlocal: function(integer, integer): string?, any

    getmetatable: function<T>(T): metatable<T>?
    getregistry: function(): any
    getupvalue: function(AnyFunction, integer): string?, any
    getuservalue: function(Userdata, arg2?: integer): any, boolean

    sethook: function<Y, R, S>(Coroutine<Y, R, S>, HookFunction, string, arg4?: integer)
    sethook: function(HookFunction, string, arg3?: integer)

    setlocal: function<Y, R, S>(Coroutine<Y, R, S>, integer, integer, any): string?
    setlocal: function(integer, integer, any): string?

    setmetatable: function<T>(T, metatable<T>): T
    setupvalue: function(AnyFunction, integer, any): string?
    setuservalue: function(Userdata, any, integer): Userdata

    traceback: function<Y, R, S>(Coroutine<Y, R, S>, arg2?: string, arg3?: integer): string
    traceback: function(arg1?: string, arg2?: integer): string
    traceback: function(any): any

    upvalueid: function(AnyFunction, integer): Userdata?
    upvaluejoin: function(AnyFunction, integer, AnyFunction, integer)
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

    close: function(arg1?: FILE)
    input: function(arg1?: FILE | string): FILE
    flush: function()

    lines: function(arg1?: string): (function(): (string))
    lines: function(arg1?: string, ...: FileNumberMode): (function(): (number...))
    lines: function(arg1?: string, ...: (number | FileStringMode)): (function(): (string...))
    lines: function(arg1?: string, ...: (number | FileMode)): (function(): ((string | number)...))
    lines: function(arg1?: string, ...: (number | string)): (function(): (string...))

    open: function(string, arg2?: OpenMode): FILE?, string?, integer?
    output: function(arg1?: FILE | string): FILE
    popen: function(string, arg2?: OpenMode): FILE?, string?, integer?

    read: function(): string?
    read: function(...: FileNumberMode): number...
    read: function(...: (number | FileStringMode)): string...
    read: function(...: (number | FileMode)): ((string | number)...)
    read: function(...: (number | string)): (string...)

    stderr: FILE
    stdin: FILE
    stdout: FILE
    tmpfile: function(): FILE?, string?, integer?
    type: function(any): FileType?
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

    close: function(FILE): boolean?, string?, integer?
    flush: function(FILE): boolean?, string?, integer?

    lines: function(FILE): (function(): (string))
    lines: function(FILE, ...: FileNumberMode): (function(): (number...))
    lines: function(FILE, ...: (number | FileStringMode)): (function(): (string...))
    lines: function(FILE, ...: (number | FileMode)): (function(): ((string | number)...))
    lines: function(FILE, ...: (number | string)): (function(): (string...))

    read: function(FILE): string?
    read: function(FILE, ...: FileNumberMode): number...
    read: function(FILE, ...: (number | FileStringMode)): string...
    read: function(FILE, ...: (number | FileMode)): ((string | number)...)
    read: function(FILE, ...: (number | string)): (string...)

    seek: function(FILE, arg2?: SeekWhence, arg3?: integer): integer?, string?, integer?
    setvbuf: function(FILE, SetVBufMode, arg3?: integer): boolean?, string?, integer?

    write: function(FILE, ...: (string | number)): FILE?, string?, integer?

    __close: function(FILE)
  end

  global record math
    type Numeric = number | integer

    abs: function(integer): integer
    abs: function(number): number
    acos: function(number): number
    asin: function(number): number
    atan: function(number, arg2?: number): number
    atan2: function(number, number): number
    ceil: function(number): integer
    cos: function(number): number
    cosh: function(number): number
    deg: function(number): number
    exp: function(number): number
    floor: function(number): integer

    fmod: function(integer, integer): integer
    fmod: function(number, number): number

    frexp: function(number): number, integer
    huge: number
    ldexp: function(number, integer): number
    log: function(number, arg2?: number): number
    log10: function(number): number

    max: function(integer, ...: integer): integer
    max: function(number, ...: number): number

    maxinteger: integer

    min: function(integer, ...: integer): integer
    min: function(number, ...: number): number

    mininteger: integer

    modf: function(number): integer, number
    pi: number
    pow: function(number, number): number
    rad: function(number): number

    random: function(integer, arg2?: integer): integer
    random: function(): number

    randomseed: function(arg1?: integer, arg2?: integer): integer, integer
    sin: function(number): number
    sinh: function(number): number
    sqrt: function(number): number
    tan: function(number): number
    tanh: function(number): number
    tointeger: function(any): integer?
    type: function(any): string?
    ult: function(number, number): boolean
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

    date: function(DateMode, arg2?: number): DateTable
    date: function(arg1?: string, arg2?: number): string

    difftime: function(integer, integer): number
    -- All three values every time: the status is `true` or nil, then "exit" or "signal", then the code.
    execute: function(string): boolean?, string, integer
    exit: function(arg1?: (integer | boolean), arg2?: boolean)
    getenv: function(string): string?
    remove: function(string): boolean?, string?, integer?
    rename: function(string, string): boolean?, string?, integer?
    setlocale: function(string, arg2?: string): string?
    time: function(arg1?: DateTable): integer
    tmpname: function(): string
  end

  global record package
    config: string
    cpath: string
    loaded: {string:any}
    loadlib: function(string, string): ((function(...: any): any...)?, string?, string?)
    loaders: { (function(string): (function(arg1?: string, arg2?: any): (any), any)) }
    path: string
    preload: {string : function(arg1?: string, arg2?: any): (any) }
    searchers: { (function(string): (function(arg1?: string, arg2?: any): (any), any)) }
    searchpath: function(string, string, arg3?: string, arg4?: string): string?, string?
  end

  global record string
    byte: function(string, arg2?: integer): integer?
    byte: function(string, integer, arg3?: integer): integer...

    char: function(...: integer): string
    dump: function(function(...: any): (any), arg2?: boolean): string
    -- The new checker types the captures of `find`, `match` and `gmatch` and the arguments of a `gsub` callback from a literal
    -- pattern (lang/check.tl, [`Calls.refine`]): a position capture `()` is an integer, and these declarations are the
    -- answer for a pattern that is no literal, where every capture is a string.
    find: function(string, string, arg3?: integer, arg4?: boolean): integer?, integer?, string...
    format: function(string, ...: any): string
    gmatch: function(string, string, arg3?: integer): (function(): string...)

    gsub: function(string, string, string, arg4?: integer): string, integer
    gsub: function(string, string, {string:string|integer|number}, arg4?: integer): string, integer
    gsub: function(string, string, {integer:string|integer|number}, arg4?: integer): string, integer
    gsub: function(string, string, function(): ((string | number)?), arg4?: integer): string, integer
    gsub: function(string, string, function(string): ((string | number)?), arg4?: integer): string, integer
    gsub: function(string, string, function(string, string): ((string | number)?), arg4?: integer): string, integer
    gsub: function(string, string, function(string, string, string): ((string | number)?), arg4?: integer): string, integer

    len: function(string): integer
    lower: function(string): string
    match: function(string, string, arg3?: integer): string...
    pack: function(string, ...: any): string
    packsize: function(string): integer
    rep: function(string, integer, arg3?: string): string
    reverse: function(string): string
    sub: function(string, integer, arg3?: integer): string
    unpack: function(string, string, arg3?: integer): any...
    upper: function(string): string
  end

  global record table
    type SortFunction = function<A>(A, A): boolean

    record PackTable<A>
      is {A}

      n: integer
    end

    concat: function({(string | number)}, arg2?: string, arg3?: integer, arg4?: integer): string

    insert: function<A>(mut {A}, integer, A)
    insert: function<A>(mut {A}, A)

    move: function<A>(mut {A}, integer, integer, integer): mut {A}
    move: function<A>({A}, integer, integer, integer, mut {A}): mut {A}

    pack: function<T>(...: T): PackTable<T>
    pack: function(...: any): PackTable<any>

    remove: function<A>(mut {A}, arg2?: integer): A?
    sort: function(mut {integer}, arg2?: function(integer, integer): boolean)
    sort: function(mut {number}, arg2?: function(number, number): boolean)
    sort: function(mut {string}, arg2?: function(string, string): boolean)
    sort: function<A>(mut {A}, function(A, A): boolean)

    unpack: function<A>({A}, arg2?: number, arg3?: number): A...
  end

  global record utf8
    char: function(...: number): string
    charpattern: string
    codepoint: function(string, arg2?: number, arg3?: number, arg4?: boolean): integer...
    codes: function(string, arg2?: boolean): (function(string, arg2?: integer): (integer, integer), string, integer)
    len: function(string, arg2?: number, arg3?: number, arg4?: boolean): integer?, integer?
    offset: function(string, number, arg3?: number): integer?
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

    arg: {string}
    -- assert's declared argument strips the nil, so
    -- `local db = assert(open(p))` yields A rather than handing
    -- `A | nil` straight back.
    assert: function<A>(A?): A
    assert: function<A, B>(A?, B, ...: any): (A, B, any...)

    collectgarbage: function(arg1?: CollectGarbageCommand): number
    collectgarbage: function(CollectGarbageStep, arg2?: integer): boolean
    collectgarbage: function(CollectGarbageMode, arg2?: integer, arg3?: integer, arg4?: integer): string
    collectgarbage: function(CollectGarbageSetValue, integer): number
    collectgarbage: function(CollectGarbageIsRunning): boolean
    collectgarbage: function(string, arg2?: number): (boolean | number | string)

    dofile: function(arg1?: string): any...

    error: function(arg1?: any, arg2?: integer): never
    getmetatable: function<T>(T): metatable<T>?
    ipairs: function<A>({A}): (function({A}, integer): (integer, A), {A}, integer)

    -- A chunk given no environment reads a table of its own: the base functions that reach nothing else, and copies of
    -- `coroutine`, `math`, `string`, `table` and `utf8` (a chunk that assigns into one changes its copy, and a string's
    -- metatable it reads is a copy too). It holds neither `require` nor `package`, `_G` or `_ENV`, so the chunk cannot load
    -- a module the build does not see. A program that needs more passes the environment, the globals for all of them.
    --
    -- The environment of the chunk is a table: an empty literal takes the type `{string: any}`, and the overloads over `V` are
    -- for a table of one value type (`{string: integer}`).
    --
    -- TODO: take an environment that is `mut {string: any}` alone, and drop the overloads over `V`, once every caller that
    -- passes one declares it so: the chunk assigns the globals it defines into it, so a table of one value type is unsound
    -- there.
    load: function((string | LoadFunction), arg2?: string, arg3?: LoadMode, arg4?: {string:any}): ((function(...: any): any...)?, string?)
    load: function((string | LoadFunction), arg2?: string, arg3?: string, arg4?: {string:any}): ((function(...: any): any...)?, string?)
    load: function<V>((string | LoadFunction), arg2?: string, arg3?: LoadMode, arg4?: {string:V}): ((function(...: any): any...)?, string?)
    load: function<V>((string | LoadFunction), arg2?: string, arg3?: string, arg4?: {string:V}): ((function(...: any): any...)?, string?)

    loadfile: function(arg1?: string, arg2?: LoadMode, arg3?: {string:any}): ((function(...: any): any...)?, string?)
    loadfile: function(arg1?: string, arg2?: string, arg3?: {string:any}): ((function(...: any): any...)?, string?)
    loadfile: function<V>(arg1?: string, arg2?: LoadMode, arg3?: {string:V}): ((function(...: any): any...)?, string?)
    loadfile: function<V>(arg1?: string, arg2?: string, arg3?: {string:V}): ((function(...: any): any...)?, string?)

    next: function<K, V>({K:V}, arg2?: K): (K?, V?)
    next: function<A>({A}, arg2?: integer): (integer?, A?)

    pairs: function<K, V>({K:V}): (function({K:V}, arg2?: K):(K, V), {K:V}, K)
    -- One overload for each number of values passed on (0 to 6 for `pcall`, 0 to 3 for `xpcall`) and answered (0 to 3): the
    -- result is `(true, R...) | (false, any)`, and for `xpcall` `(false, H | string)`, what the message handler answers or
    -- the string Lua answers when the handler itself raises.
    --
    -- TODO: accept a function that answers `T...` as an argument of `pcall` and `xpcall`, once the grammar spells a list
    -- with a tail among alternatives (`plist` in doc/plans/new-checker-grammar.md, "types"): `(true, R...) | (false, any)`
    -- cannot be written until then, and a call that passes one is `overload_none`.
    pcall: function((function())): (true) | (false, any)
    pcall: function<R1>((function(): R1)): (true, R1) | (false, any)
    pcall: function<R1, R2>((function(): (R1, R2))): (true, R1, R2) | (false, any)
    pcall: function<R1, R2, R3>((function(): (R1, R2, R3))): (true, R1, R2, R3) | (false, any)
    pcall: function<A1>((function(A1)), A1): (true) | (false, any)
    pcall: function<A1, R1>((function(A1): R1), A1): (true, R1) | (false, any)
    pcall: function<A1, R1, R2>((function(A1): (R1, R2)), A1): (true, R1, R2) | (false, any)
    pcall: function<A1, R1, R2, R3>((function(A1): (R1, R2, R3)), A1): (true, R1, R2, R3) | (false, any)
    pcall: function<A1, A2>((function(A1, A2)), A1, A2): (true) | (false, any)
    pcall: function<A1, A2, R1>((function(A1, A2): R1), A1, A2): (true, R1) | (false, any)
    pcall: function<A1, A2, R1, R2>((function(A1, A2): (R1, R2)), A1, A2): (true, R1, R2) | (false, any)
    pcall: function<A1, A2, R1, R2, R3>((function(A1, A2): (R1, R2, R3)), A1, A2): (true, R1, R2, R3) | (false, any)
    pcall: function<A1, A2, A3>((function(A1, A2, A3)), A1, A2, A3): (true) | (false, any)
    pcall: function<A1, A2, A3, R1>((function(A1, A2, A3): R1), A1, A2, A3): (true, R1) | (false, any)
    pcall: function<A1, A2, A3, R1, R2>((function(A1, A2, A3): (R1, R2)), A1, A2, A3): (true, R1, R2) | (false, any)
    pcall: function<A1, A2, A3, R1, R2, R3>((function(A1, A2, A3): (R1, R2, R3)), A1, A2, A3): (true, R1, R2, R3) | (false, any)
    pcall: function<A1, A2, A3, A4>((function(A1, A2, A3, A4)), A1, A2, A3, A4): (true) | (false, any)
    pcall: function<A1, A2, A3, A4, R1>((function(A1, A2, A3, A4): R1), A1, A2, A3, A4): (true, R1) | (false, any)
    pcall: function<A1, A2, A3, A4, R1, R2>((function(A1, A2, A3, A4): (R1, R2)), A1, A2, A3, A4): (true, R1, R2) | (false, any)
    pcall: function<A1, A2, A3, A4, R1, R2, R3>((function(A1, A2, A3, A4): (R1, R2, R3)), A1, A2, A3, A4): (true, R1, R2, R3) | (false, any)
    pcall: function<A1, A2, A3, A4, A5>((function(A1, A2, A3, A4, A5)), A1, A2, A3, A4, A5): (true) | (false, any)
    pcall: function<A1, A2, A3, A4, A5, R1>((function(A1, A2, A3, A4, A5): R1), A1, A2, A3, A4, A5): (true, R1) | (false, any)
    pcall: function<A1, A2, A3, A4, A5, R1, R2>((function(A1, A2, A3, A4, A5): (R1, R2)), A1, A2, A3, A4, A5): (true, R1, R2) | (false, any)
    pcall: function<A1, A2, A3, A4, A5, R1, R2, R3>((function(A1, A2, A3, A4, A5): (R1, R2, R3)), A1, A2, A3, A4, A5): (true, R1, R2, R3) | (false, any)
    pcall: function<A1, A2, A3, A4, A5, A6>((function(A1, A2, A3, A4, A5, A6)), A1, A2, A3, A4, A5, A6): (true) | (false, any)
    pcall: function<A1, A2, A3, A4, A5, A6, R1>((function(A1, A2, A3, A4, A5, A6): R1), A1, A2, A3, A4, A5, A6): (true, R1) | (false, any)
    pcall: function<A1, A2, A3, A4, A5, A6, R1, R2>((function(A1, A2, A3, A4, A5, A6): (R1, R2)), A1, A2, A3, A4, A5, A6): (true, R1, R2) | (false, any)
    pcall: function<A1, A2, A3, A4, A5, A6, R1, R2, R3>((function(A1, A2, A3, A4, A5, A6): (R1, R2, R3)), A1, A2, A3, A4, A5, A6): (true, R1, R2, R3) | (false, any)
    print: function(...: any)
    rawequal: function(any, any): boolean

    rawget: function<K, V>({K:V}, K): V?
    rawget: function(any, any): any

    rawlen: function<A>({A}): integer

    -- TODO: a record whose fields all share a type reads as that map, so `rawset(r, "undeclared", v)` still writes a key it does not declare; refuse it once a record no longer reads as a map (closed records).
    rawset: function<K, V>(mut {K:V}, K, V): mut {K:V}

    require: function(string): any

    select: function<T>(integer, ...: T): T...
    select: function(integer, ...: any): any...
    select: function(string, ...: any): integer

    setmetatable: function<T>(T, metatable<T>): T

    tonumber: function(any): number?
    tonumber: function(any, integer): integer?

    tostring: function(any): string
    type: function(any): string
    warn: function(string, ...: string)
    xpcall: function<H>((function()), (function(any): H)): (true) | (false, H | string)
    xpcall: function<R1, H>((function(): R1), (function(any): H)): (true, R1) | (false, H | string)
    xpcall: function<R1, R2, H>((function(): (R1, R2)), (function(any): H)): (true, R1, R2) | (false, H | string)
    xpcall: function<R1, R2, R3, H>((function(): (R1, R2, R3)), (function(any): H)): (true, R1, R2, R3) | (false, H | string)
    xpcall: function<A1, H>((function(A1)), (function(any): H), A1): (true) | (false, H | string)
    xpcall: function<A1, R1, H>((function(A1): R1), (function(any): H), A1): (true, R1) | (false, H | string)
    xpcall: function<A1, R1, R2, H>((function(A1): (R1, R2)), (function(any): H), A1): (true, R1, R2) | (false, H | string)
    xpcall: function<A1, R1, R2, R3, H>((function(A1): (R1, R2, R3)), (function(any): H), A1): (true, R1, R2, R3) | (false, H | string)
    xpcall: function<A1, A2, H>((function(A1, A2)), (function(any): H), A1, A2): (true) | (false, H | string)
    xpcall: function<A1, A2, R1, H>((function(A1, A2): R1), (function(any): H), A1, A2): (true, R1) | (false, H | string)
    xpcall: function<A1, A2, R1, R2, H>((function(A1, A2): (R1, R2)), (function(any): H), A1, A2): (true, R1, R2) | (false, H | string)
    xpcall: function<A1, A2, R1, R2, R3, H>((function(A1, A2): (R1, R2, R3)), (function(any): H), A1, A2): (true, R1, R2, R3) | (false, H | string)
    xpcall: function<A1, A2, A3, H>((function(A1, A2, A3)), (function(any): H), A1, A2, A3): (true) | (false, H | string)
    xpcall: function<A1, A2, A3, R1, H>((function(A1, A2, A3): R1), (function(any): H), A1, A2, A3): (true, R1) | (false, H | string)
    xpcall: function<A1, A2, A3, R1, R2, H>((function(A1, A2, A3): (R1, R2)), (function(any): H), A1, A2, A3): (true, R1, R2) | (false, H | string)
    xpcall: function<A1, A2, A3, R1, R2, R3, H>((function(A1, A2, A3): (R1, R2, R3)), (function(any): H), A1, A2, A3): (true, R1, R2, R3) | (false, H | string)
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
