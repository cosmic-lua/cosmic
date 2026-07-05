# embed_startup_bench

 Startup of an embed.run()-produced executable.

 embed.run() bundles a user app into a copy of the cosmic binary; the
 produced executable boots into the embedded main.lua, which loads the
 app's other embedded .lua modules. Whatever compression those modules
 carry is paid back as inflate() calls on every launch of the app — the
 same per-boot cost backlog 024 removed from cosmic's own payload, but
 for the executables embed produces. This scenario builds one such
 executable once (the ~megabyte base-binary copy is fixed overhead we
 keep out of the timed op) and measures its cold start.
