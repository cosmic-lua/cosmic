# child_bench

 Subprocess execution scenarios: raw fork/exec/wait overhead via
 cosmic.child, isolated from the "boot a Lua runtime" cost that the
 startup_* scenarios (startup_bench.tl) measure by spawning cosmic
 itself. This spawns /bin/true, about as cheap an exec target as
 exists, so what's left is spawn()'s own pipe setup, fork, and wait.
