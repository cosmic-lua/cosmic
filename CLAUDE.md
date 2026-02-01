# CLAUDE.md - cosmic-lua

A cosmopolitan Lua distribution with Teal support and bundled libraries.

## Project Goals

See [GOALS.md](GOALS.md) for ambitious, measurable project goals with verification criteria.

## Architecture

```
cosmic/
├── 3p/              # Third-party: cosmos binary, teal compiler, type definitions
├── lib/
│   ├── cosmic/      # High-level library modules (spawn, fetch, walk, etc.)
│   ├── types/       # Type definitions for cosmo bindings
│   ├── build/       # Build infrastructure
│   └── docs/        # Documentation generation
├── bin/make         # Build script
├── Makefile         # Top-level build orchestration
└── cook.mk          # Module dependency definitions
```

## Development Workflow

### Building

```bash
make staged    # Fetch and extract dependencies
make cosmic    # Build the cosmic binary
make check     # Run Teal type checking
make test      # Run all tests
make test ONLY=spawn  # Run tests matching "spawn"
make example   # Run all examples
make benchmark # Run all benchmarks
make ci        # Full CI pipeline
```

### Adding a New Module

1. Create `lib/cosmic/<module>.tl` with implementation
2. Add type definitions to `lib/types/cosmo/<module>.d.tl` if wrapping cosmo
3. Create `lib/cosmic/<module>_test.tl` with tests
4. Add doc comments to all public functions
5. Add module to `lib/cook.mk` if it needs special handling
6. Run `make check test example` to verify

### Code Style

- Use Teal for all new code (not plain Lua)
- Follow existing naming conventions (snake_case for functions, PascalCase for types)
- Document all public APIs with `---` doc comments
- Prefer explicit error returns over exceptions
- Use `__close` for resource cleanup

## Quick Reference

### CLI

```bash
cosmic-lua script.lua          # Run a Lua script
cosmic-lua script.tl           # Run a Teal script (compiled on-the-fly)
cosmic-lua -e 'print("hi")'    # Execute inline code
cosmic-lua --check file.tl     # Type-check a Teal file
cosmic-lua --compile file.tl   # Compile Teal to Lua (stdout)
cosmic-lua --example file.tl   # Run Example_* functions
cosmic-lua --benchmark file.tl # Run Benchmark_* functions
cosmic-lua --docs query        # Search embedded documentation
cosmic-lua --help              # Show help and module listing
```

### Common Patterns

```lua
-- Fetch and parse JSON
local fetch = require("cosmic.fetch")
local cosmo = require("cosmo")
local resp = fetch.get("https://api.example.com/data")
local data = cosmo.DecodeJson(resp.body)

-- Spawn a process
local spawn = require("cosmic.spawn")
local result = spawn.run({"ls", "-la"})
print(result.stdout)

-- Walk files matching pattern
local walk = require("cosmic.walk")
for path in walk.files(".", "*.tl") do
  print(path)
end

-- SQLite database
local sqlite = require("lsqlite3")
local db = sqlite.open("data.db")
db:exec("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")

-- Command-line arguments
local getopt = require("cosmo.getopt")
local opts, args = getopt.parse(arg, "hv", {"help", "verbose"})
```
