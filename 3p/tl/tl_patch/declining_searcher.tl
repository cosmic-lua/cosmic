-- The declining-searcher half of the carried tl patch: teaches the
-- checker that a `package.searchers` entry, called, may return a bare
-- `string` instead of a loader function -- the real, working Lua/tl
-- idiom a searcher uses to DECLINE a name (`require` then reports its
-- own "module not found" rather than the whole chain erroring out).
-- The pinned tl 0.24.8 builtin types every searcher's call result as
-- exactly `(function(?string, ?any): any, any)`, with no `string`
-- alternative, so a caller that narrows the first return with `is
-- string` (`cosmic/searcher_test.tl`) cannot type-check without a cast.
--
-- `declining-searcher-package-searchers` widens the first element of
-- that return tuple to `(function(?string, ?any): any) | string`. This
-- is a pure widening: the loader-function arm is untouched, so nothing
-- that used to type-check as a loader stops doing so; the only change
-- is that a `string` value is now ALSO accepted there, matching what a
-- declining searcher actually returns at runtime.
--
-- The mechanism is _make/patch.tl: each entry is an exact `find`
-- string replaced by an exact `replace` string in one unpacked file,
-- and entry names share one namespace across every file in this
-- directory, applied in sorted-name order.
--
-- Carried, not forked: each anchor must match the pinned source exactly
-- once, so a tl pin bump that moves this code fails the fetch loudly
-- until the patch is re-audited (or dropped, once upstream lands it).
--
-- Probing an entry: reverse it with `_make.patch`'s `reverse`, which loads
-- the de-patched copy into `package.loaded`, the table `require` reads
-- before any searcher. A modified copy placed on `package.path` is ignored
-- instead: the binary's own `/zip` searcher outranks the file searcher, so
-- such a probe measures the shipped checker and reports a confident wrong
-- answer with nothing logged. A third form is inert for a third reason:
-- `cosmic --check types` on a file that preloads `tl` never runs that
-- file, so the shipped checker answers at exit 0 with nothing logged --
-- `cosmic --docs guide.checking` lays the three forms side by side.
return {
  ["declining-searcher-package-searchers"] = {
    file = "tl.lua",
    note = "a declining searcher returns a bare string, not a loader; the builtin type had no arm for it",
    find = [=====[      searchers: { (function(string): (function(? string, ? any): (any), any)) }
]=====],
    replace = [=====[      searchers: { (function(string): (function(? string, ? any): (any) | string, any)) }
]=====],
  },
  ["declining-searcher-package-searchers-tl-tl"] = {
    file = "tl.tl",
    note = "a declining searcher returns a bare string, not a loader; the builtin type had no arm for it (Teal ground truth)",
    find = [=====[      searchers: { (function(string): (function(? string, ? any): (any), any)) }
]=====],
    replace = [=====[      searchers: { (function(string): (function(? string, ? any): (any) | string, any)) }
]=====],
  },
}
