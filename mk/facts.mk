# mk/facts.mk — remaking o/project.mk, the generated facts.
#
# The Makefile `-include`s o/project.mk, so make remakes it before doing
# anything else and re-execs once it changes. Everything about this rule
# is about that first pass, when the file does not exist yet:
#
#   - the generator is a TREE script (o/_make/facts.lua), not a verb on
#     the pinned bootstrap. The bootstrap predates _make entirely,
#     so the modules have to come from this checkout; the bootstrap is
#     just the interpreter, exactly as it is for every other recipe.
#   - which means facts.lua must compile FIRST, and it does: the compile
#     rule's srcdeps_* are undefined on that pass and expand empty, so
#     the rule is the one it has always been.
#   - it writes only when the bytes change (facts.tl checks), so a build
#     whose imports did not move does not restart.
#
# The dependency is every .tl in the tree, because an import edge can
# appear or vanish in any of them. That is a big prerequisite list for a
# small file; it is also exactly what `--make` rescans on every run.

facts_tool := $(o)/_make/facts.lua
facts_srcs := $(all_tl) $(all_tests) $(all_example_srcs)

# Not sandboxed and not env-clamped: the scan walks the whole tree
# (every directory, to classify what is in it) and the recipe needs the
# tree LUA_PATH to resolve _make out of o/. 3i retires this file
# along with the rest of the bridge.
$(o)/project.mk: .SANDBOXED := 0
$(o)/project.mk: export LUA_PATH = $(tree_lua_path)
$(o)/project.mk: $(facts_tool) $(facts_srcs) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) $(facts_tool) $@

.PHONY: facts
## Regenerate o/project.mk (the import closures the compile rule uses)
facts: $(o)/project.mk
