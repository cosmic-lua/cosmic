# main_handlers

 Command handler functions for the cosmic CLI.
 Each handler implements one CLI command flag.

## Types

### DocsRunResult

 Result from running docs command.

```teal
local record DocsRunResult
  ok: boolean
  output: string
end
```

### VersionInfo

```teal
local record VersionInfo
  cosmic: string
  cosmos: string
end
```

### HandlersModule

```teal
local record HandlersModule
  generate_welcome: function(): string
  run_repl: function()
  load_script_file: function(script_path: string): function(...: any): any ..., string
  run_docs: function(query: string): DocsRunResult
  handle_version: function(): integer
  handle_compile: function(file: string, output?: string, write_if_changed?: boolean, include_dirs?: {string}): integer, string
  handle_format: function(file: string, output?: string, write_if_changed?: boolean): integer, string
  handle_check_format: function(file: string): integer
  handle_check_types: function(file: string, include_dirs?: {string}): integer
  handle_check_style: function(file: string): integer
  handle_embed: function(paths: {string}, output: string): integer
  handle_extract: function(dir: string): integer
  handle_check_examples: function(file: string): integer
  handle_examples: function(module_name: string): integer
  handle_benchmark: function(spec: string): integer
  handle_docs: function(query: string): integer
  handle_make: function(dir: string, target: string): integer
  handle_skill: function(dir: string): integer
end
```

## Functions

### generate_welcome

```teal
function generate_welcome(): string
```

 Generate welcome message for first-run experience.

**Returns:**

- string - The welcome message text

### run_repl

```teal
function run_repl()
```

 Interactive REPL using cosmopolitan's linenoise-based REPL.

### load_script_file

```teal
function load_script_file(script_path: string): function(...: any): any ..., string
```

 Load a script file (.tl or .lua): .tl through Teal (cached), .lua directly.

### run_docs

```teal
function run_docs(query: string): DocsRunResult
```

 Run docs command with smart matching.

**Parameters:**

- `query` (string) - The query string

**Returns:**

- DocsRunResult - Result with ok status and output text

### handle_version

```teal
function handle_version(): integer
```

 Handle --version flag.

### handle_compile

```teal
function handle_compile(file: string, output?: string, write_if_changed?: boolean, include_dirs?: {string}): integer, string
```

 Handle --compile flag.

### handle_format

```teal
function handle_format(file: string, output?: string, write_if_changed?: boolean): integer, string
```

 Handle --format flag.

### handle_check_format

```teal
function handle_check_format(file: string): integer
```

 Handle --check-format flag.

### handle_check_types

```teal
function handle_check_types(file: string, include_dirs?: {string}): integer
```

 Handle --check-types flag.

### handle_embed

```teal
function handle_embed(paths: {string}, output: string): integer
```

 Handle --embed flag.

### handle_extract

```teal
function handle_extract(dir: string): integer
```

 Handle --extract flag.

### handle_check_examples

```teal
function handle_check_examples(file: string): integer
```

 Handle --check-examples flag.

### handle_examples

```teal
function handle_examples(module_name: string): integer
```

 Handle --examples flag.

### handle_benchmark

```teal
function handle_benchmark(spec: string): integer
```

 Handle --benchmark flag.

### handle_docs

```teal
function handle_docs(query: string): integer
```

 Handle --docs flag.

### handle_check_style

```teal
function handle_check_style(file: string): integer
```

 Handle --check-style flag.

### handle_make

```teal
function handle_make(dir: string, target: string): integer
```

 Handle --make flag.

### handle_skill

```teal
function handle_skill(dir: string): integer
```

 Handle --skill flag.
 Creates the output directory and writes SKILL.md there.
