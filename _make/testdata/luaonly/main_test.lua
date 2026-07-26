-- A `.lua` test in a Lua-only project. The marker suffixes are
-- extension-agnostic, so this must RUN under `--make test` and must
-- NOT be embedded in the artifact -- it classified as a module and did
-- both wrongly.
print("luaonly test ran")
