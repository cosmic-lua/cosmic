-- The enum-* half of the carried tl patch: teaches the checker that a
-- narrower enum is a subtype of a wider one when the narrower's whole
-- word set is contained in the wider's -- `CompressFormat`'s
-- `{"zlib","gzip","raw"}` inside `DecompressFormat`'s
-- `{"zlib","gzip","raw","auto"}` is the production case
-- (`_fuzz/compress_fuzz_test.tl:76`). `enum-subset-is-subtype` adds the
-- one branch this needs; the census is docs/design/casts.md.
--
-- This is a pure widening: a nominal-vs-nominal comparison that used
-- to fail on two enums now succeeds when one's words are a subset of
-- the other's, and nothing that used to pass can stop passing -- the
-- new branch only returns `true` in an additional case, never `false`
-- in place of a prior `true`.
--
-- Deliberately NOT included: "every enum is a subtype of `string`".
-- That rule already exists in the pinned tl 0.24.8
-- (`subtype_relations["enum"]["string"] = compare_true`), reached
-- through `subtype_nominal` for any enum-backed nominal -- confirmed
-- by hand, no patch needed:
--
--     local enum HostOs "linux" "macos" end
--     local function host_os(): HostOs return "linux" end
--     local s: string = host_os()
--     -- Type check passed
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
  ["enum-subset-is-subtype"] = {
    file = "tl.lua",
    note = "cosmic board 3IYMLpshg4PguqSIpuzN5Lq8dS9: a subset enum is a subtype of a superset enum -- confirmed missing by hand (CompressFormat into DecompressFormat rejected) and confirmed distinct from the existing enum-is-a-string rule (already passes with no patch)",
    find = [=====[            local ra = self:resolve_nominal(a)
            local rb = self:resolve_nominal(b)


            local union_a = ra.typename == "union"]=====],
    replace = [=====[            local ra = self:resolve_nominal(a)
            local rb = self:resolve_nominal(b)

            -- cosmic carried patch (board 3IYMLpshg4PguqSIpuzN5Lq8dS9): a
            -- narrower enum is a subtype of a wider one when every word
            -- of the narrower's set is also a word of the wider's --
            -- are_same_nominals above only accepts the SAME nominal, so
            -- two differently-named enums fall through to this branch
            -- even when one's word set is entirely contained in the
            -- other's. `enumset` is the `{string:boolean}` word set
            -- already used the same way at line ~9811 and ~9896.
            if ra.typename == "enum" and rb.typename == "enum" then
               local subset = true
               for k in pairs(ra.enumset) do
                  if not rb.enumset[k] then
                     subset = false
                     break
                  end
               end
               if subset then
                  return true
               end
            end

            local union_a = ra.typename == "union"]=====],
  },
}
