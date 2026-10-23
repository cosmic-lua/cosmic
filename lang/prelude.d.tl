-- The definitions that are core to the language, valid before the standard library loads, as the new checker reads them. The
-- fork's own copy is the prelude in checker/tl.tl, which it reads until the switch deletes it.
--
-- `any`, `thread` and `userdata` are no declarations: the first two are primitive types, and a `userdata` record is
-- declared by the marker of that name in its body.
do
  global record metatable<T>
    enum Mode
      "k" "v" "kv"
    end

    __call: function(T, ...: any): any...
    __mode: Mode
    __name: string
    __tostring: function(T): string
    __pairs: function<K, V>(T): function(): (K, V)

    -- FIXME: function | table | anything with an __index metamethod
    __index: any
    __newindex: any

    __gc: function(T)
    __close: function(T)

    __add: function<A, B, C>(A, B): C
    __sub: function<A, B, C>(A, B): C
    __mul: function<A, B, C>(A, B): C
    __div: function<A, B, C>(A, B): C
    __idiv: function<A, B, C>(A, B): C
    __mod: function<A, B, C>(A, B): C
    __pow: function<A, B, C>(A, B): C
    __band: function<A, B, C>(A, B): C
    __bor: function<A, B, C>(A, B): C
    __bxor: function<A, B, C>(A, B): C
    __shl: function<A, B, C>(A, B): C
    __shr: function<A, B, C>(A, B): C
    __concat: function<A, B, C>(A, B): C

    __len: function<A>(T): A
    __unm: function<A>(T): A
    __bnot: function<A>(T): A

    __eq: function<A, B>(A, B): boolean
    __lt: function<A, B>(A, B): boolean
    __le: function<A, B>(A, B): boolean
  end
end
