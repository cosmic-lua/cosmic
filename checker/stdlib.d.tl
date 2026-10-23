do
   -- The new checker reads lang/stdlib.d.tl, which declares some of these differently: a result that may be nil is
   -- declared so there, where the fork's own check of the tree lets the old one pass.

   local enum FileStringMode
      "a" "l" "L" "*a" "*l" "*L"
   end

   local enum FileNumberMode
      "n" "*n"
   end

   local enum FileMode
      "a" "l" "L" "*a" "*l" "*L" "n" "*n"
   end

   global record coroutine
      type Function = function(any...): any...

      -- The new checker reads these as lang/stdlib.d.tl declares them, over a typed `Coroutine<Y, R, S>`.
      close: function(thread): boolean, string
      create: function(Function): thread
      isyieldable: function(): boolean
      resume: function(thread, any...): boolean, any...
      running: function(): thread, boolean
      status: function(thread): string
      wrap: function(Function): function(any...): any...
      yield: function(any...): any...
   end

   global record debug
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
         ftransfer: integer -- TODO: what should compat be for these? (5.4+)
         ntransfer: integer
      end

      enum HookEvent
         "call" "tail call" "return" "line" "count"
      end

      type HookFunction = function(HookEvent, integer)

      type AnyFunction = function(any...):any...

      debug: function()
      gethook: function(? thread): HookFunction | nil, integer

      getinfo: function(thread, AnyFunction, ? string): GetInfoTable
      getinfo: function(thread, integer, ? string): GetInfoTable | nil
      getinfo: function(        AnyFunction, ? string): GetInfoTable
      getinfo: function(        integer, ? string): GetInfoTable | nil

      getlocal: function(thread, AnyFunction, integer): string | nil
      getlocal: function(thread, integer, integer): string | nil, any
      getlocal: function(AnyFunction, integer): string | nil
      getlocal: function(integer, integer): string | nil, any

      getmetatable: function<T>(T): metatable<T> | nil
      getregistry: function(): {any:any}
      getupvalue: function(AnyFunction, integer): string | nil, any
      getuservalue: function(userdata, ? integer): any, boolean

      sethook: function(thread, HookFunction, string, ? integer)
      sethook: function(HookFunction, string, ? integer)

      setlocal: function(thread, integer, integer, any): string | nil
      setlocal: function(integer, integer, any): string | nil

      setmetatable: function<T>(T, metatable<T>): T
      setupvalue: function(AnyFunction, integer, any): string | nil
      setuservalue: function<U>(U, any, integer): U --[[U is userdata]]

      traceback: function(thread, ? string, ? integer): string
      traceback: function(? string, ? integer): string
      traceback: function(any): any

      -- TODO: answer nil for an upvalue that does not exist, once the translator can write `userdata?`: the new grammar reads
      -- `userdata` as the marker of a record, and a union with it is one more form `translated` pins.
      upvalueid: function(AnyFunction, integer): userdata
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

      close: function(? FILE)
      input: function(? FILE | string): FILE
      flush: function()

      lines: function(? string): (function(): (string))
      lines: function(? string, FileNumberMode...): (function(): (number...))
      lines: function(? string, (number | FileStringMode)...): (function(): (string...))
      lines: function(? string, (number | FileMode)...): (function(): ((string | number)...))
      lines: function(? string, (number | string)...): (function(): (string...))

      open: function(string, ? OpenMode): FILE | nil, string | nil, integer | nil
      output: function(? FILE | string): FILE
      popen: function(string, ? OpenMode): FILE | nil, string | nil, integer | nil

      read: function(): string | nil
      read: function(FileNumberMode...): number...
      read: function((number | FileStringMode)...): string...
      read: function((number | FileMode)...): ((string | number)...)
      read: function((number | string)...): (string...)

      stderr: FILE
      stdin: FILE
      stdout: FILE
      tmpfile: function(): FILE | nil, string | nil, integer | nil
      type: function(any): FileType | nil
      write: function((string | number)...): FILE | nil, string | nil, integer | nil
   end

   global record FILE
      is userdata
      where io.type(self)

      enum SeekWhence
         "set" "cur" "end"
      end

      enum SetVBufMode
         "no" "full" "line"
      end

      close: function(FILE): boolean | nil, string | nil, integer | nil
      flush: function(FILE): boolean | nil, string | nil, integer | nil

      lines: function(FILE): (function(): (string))
      lines: function(FILE, FileNumberMode...): (function(): (number...))
      lines: function(FILE, (number | FileStringMode)...): (function(): (string...))
      lines: function(FILE, (number | FileMode)...): (function(): ((string | number)...))
      lines: function(FILE, (number | string)...): (function(): (string...))

      read: function(FILE): string | nil
      read: function(FILE, FileNumberMode...): number...
      read: function(FILE, (number | FileStringMode)...): string...
      read: function(FILE, (number | FileMode)...): ((string | number)...)
      read: function(FILE, (number | string)...): (string...)

      seek: function(FILE, ? SeekWhence, ? integer): integer | nil, string | nil, integer | nil
      setvbuf: function(FILE, SetVBufMode, ? integer): boolean | nil, string | nil, integer | nil

      write: function(FILE, (string | number)...): FILE | nil, string | nil, integer | nil

      metamethod __close: function(FILE)
   end

   global record math
      type Numeric = number | integer

      abs: function<N is Numeric>(N): N
      acos: function(number): number
      asin: function(number): number
      atan: function(number, ? number): number
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
      log: function(number, ? number): number
      log10: function(number): number

      max: function(integer...): integer
      max: function((number | integer)...): number
      max: function<T>(T...): T
      max: function(any...): any

      maxinteger: integer --[[needs_compat]]

      min: function(integer...): integer
      min: function((number | integer)...): number
      min: function<T>(T...): T
      min: function(any...): any

      mininteger: integer --[[needs_compat]]

      modf: function(number): integer, number
      pi: number
      pow: function(number, number): number
      rad: function(number): number

      random: function(integer, ? integer): integer
      random: function(): number

      randomseed: function(? integer, ? integer): integer, integer
      sin: function(number): number
      sinh: function(number): number
      sqrt: function(number): number
      tan: function(number): number
      tanh: function(number): number
      tointeger: function(any): integer
      type: function(any): string | nil
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

      date: function(DateMode, ? number): DateTable
      date: function(? string, ? number): string

      difftime: function(integer, integer): number
      -- All three values every time: the status is `true` or nil, then "exit" or "signal", then the code.
      execute: function(string): boolean | nil, string, integer
      exit: function(? (integer | boolean), ? boolean)
      getenv: function(string): string | nil
      remove: function(string): boolean | nil, string | nil, integer | nil
      rename: function(string, string): boolean | nil, string | nil, integer | nil
      setlocale: function(string, ? string): string | nil
      time: function(? DateTable): integer
      tmpname: function(): string
   end

   global record package
      config: string
      cpath: string
      loaded: {string:any}
      loadlib: function(string, string): (function | nil, string | nil, string | nil)
      loaders: { (function(string): (function(? string, ? any): (any), any)) }
      path: string
      preload: {string : function(? string, ? any): (any) }
      searchers: { (function(string): (function(? string, ? any): (any), any)) }
      searchpath: function(string, string, ? string, ? string): string | nil, string | nil
   end

   global record string
      byte: function(string, ? integer): integer
      byte: function(string, integer, ? integer): integer...

      char: function(integer...): string
      dump: function(function(any...): (any), ? boolean): string
      -- The new checker types the captures of `find`, `match` and `gmatch` and the arguments of a `gsub` callback from a literal
      -- pattern (lang/check.tl, `Calls.refine`): a position capture `()` is an integer, and these declarations are the
      -- answer for a pattern that is no literal, where every capture is a string.
      find: function(string, string, ? integer, ? boolean): integer, integer, string... --[[special_function]]
      format: function(string, any...): string --[[special_function]]
      gmatch: function(string, string, ? integer): (function(): string...) --[[special_function]]

      gsub: function(string, string, string, ? integer): string, integer --[[special_function]]
      gsub: function(string, string, {string:string|integer|number}, ? integer): string, integer --[[special_function]]
      gsub: function(string, string, {integer:string|integer|number}, ? integer): string, integer --[[special_function]]
      gsub: function(string, string, function(): (string | number | nil), ? integer): string, integer
      gsub: function(string, string, function(string): (string | number | nil), ? integer): string, integer
      gsub: function(string, string, function(string, string): (string | number | nil), ? integer): string, integer
      gsub: function(string, string, function(string, string, string): (string | number | nil), ? integer): string, integer --[[special_function]]

      len: function(string): integer
      lower: function(string): string
      match: function(string, string, ? integer): string... --[[special_function]]
      pack: function(string, any...): string --[[special_function]]
      packsize: function(string): integer
      rep: function(string, integer, ? string): string
      reverse: function(string): string
      sub: function(string, integer, ? integer): string
      unpack: function(string, string, ? integer): any... --[[special_function]]
      upper: function(string): string
   end

   global record table
      type SortFunction = function<A>(A, A): boolean

      record PackTable<A>
         is {A}

         n: integer
      end

      concat: function({(string | number)}, ? string, ? integer, ? integer): string

      insert: function<A>({A}, integer, A)
      insert: function<A>({A}, A)

      move: function<A>({A}, integer, integer, integer, ? {A}): {A}

      pack: function<T>(T...): PackTable<T> --[[needs_compat]]
      pack: function(any...): {any:any} --[[needs_compat]]

      remove: function<A>({A}, ? integer): A
      sort: function<A>({A}, ? SortFunction<A>)

      unpack: function<A>({A}, ? number, ? number): A... --[[needs_compat]]
      unpack: function<A1, A2>({A1, A2}): A1, A2 --[[needs_compat]]
      unpack: function<A1, A2, A3>({A1, A2, A3}): A1, A2, A3 --[[needs_compat]]
      unpack: function<A1, A2, A3, A4>({A1, A2, A3, A4}): A1, A2, A3, A4 --[[needs_compat]]
      unpack: function<A1, A2, A3, A4, A5>({A1, A2, A3, A4, A5}): A1, A2, A3, A4, A5 --[[needs_compat]]
   end

   global record utf8
      char: function(number...): string
      charpattern: string
      codepoint: function(string, ? number, ? number, ? boolean): integer...
      codes: function(string, ? boolean): (function(string, ? integer): (integer, integer), string, integer)
      len: function(string, ? number, ? number, ? boolean): integer | nil, integer
      offset: function(string, number, ? number): integer | nil
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

      type LoadFunction = function(): string | nil

      enum LoadMode
         "b" "t" "bt"
      end

      type XpcallMsghFunction = function(any): any...

      arg: {string}
      -- assert's declared argument strips the nil, so
      -- `local db = assert(open(p))` yields A rather than handing
      -- `A | nil` straight back.
      assert: function<A, B>(A | nil, ? B, ...: any): (A, B, any...) --[[special_function]]

      collectgarbage: function(? CollectGarbageCommand): number
      collectgarbage: function(CollectGarbageStep, ? integer): boolean
      collectgarbage: function(CollectGarbageMode, ? integer, ? integer, ? integer): string
      collectgarbage: function(CollectGarbageSetValue, integer): number
      collectgarbage: function(CollectGarbageIsRunning): boolean
      collectgarbage: function(string, ? number): (boolean | number | string)

      dofile: function(? string): any...

      error: function(? any, ? integer): never
      getmetatable: function<T>(T): metatable<T>
      ipairs: function<A>({A}): (function({A}, integer): (integer, A), {A}, integer) --[[special_function]]

      load: function((string | LoadFunction), ? string, ? LoadMode, ? {any:any}): (function, string)
      load: function((string | LoadFunction), ? string, ? string,   ? {any:any}): (function, string)

      loadfile: function(? string, ? LoadMode, ? {any:any}): (function | nil, string | nil)
      loadfile: function(? string, ? string,   ? {any:any}): (function | nil, string | nil)

      next: function<K, V>({K:V}, ? K): (K | nil, V | nil)
      next: function<A>({A}, ? integer): (integer | nil, A | nil)

      pairs: function<K, V>({K:V}): (function({K:V}, ? K):(K, V), {K:V}, K) --[[special_function]]
      pcall: function(function(any...):(any...), any...): boolean, any... --[[special_function]]
      print: function(any...)
      rawequal: function(any, any): boolean

      rawget: function<K, V>({K:V}, K): V | nil --[[special_function]]
      rawget: function({any:any}, any): any
      rawget: function(any, any): any

      rawlen: function<A>({A}): integer

      -- TODO: a record whose fields all share a type reads as that map, so `rawset(r, "undeclared", v)` still writes a key it does not declare; refuse it once a record no longer reads as a map (closed records).
      rawset: function<K, V>({K:V}, K, V): {K:V}

      require: function(string): any --[[special_function]]

      select: function<T>(integer, T...): T...
      select: function(integer, any...): any...
      select: function(string, any...): integer

      setmetatable: function<T>(T, metatable<T>): T

      tonumber: function(any): number
      tonumber: function(any, integer): integer

      tostring: function(any): string
      type: function(any): string
      warn: function(string, string...)
      xpcall: function(function(any...):(any...), XpcallMsghFunction, any...): boolean, any... --[[special_function]]
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

