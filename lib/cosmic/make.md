# make

 Generate Makefiles for Teal projects.
 Scans a directory for .tl files, classifies them, and emits a
 self-contained Makefile with rules for compile, type-check,
 format-check, test, and report.

## Types

### Config

 Configuration for Makefile generation.

```teal
local record Config
  source_dir: string
  build_dir: string
  cosmic_bin: string
end
```

### Project

 Classified project files.

```teal
local record Project
  sources: {string}
  tests: {string}
  examples: {string}
end
```

### MakeModule

```teal
local record MakeModule
  scan: function(dir: string): Project
  generate: function(project: Project, config?: Config): string
  run: function(dir?: string, target?: string): boolean, string
end
```

## Functions

### scan

```teal
function scan(dir: string): Project
```

 Scan a directory for .tl files and classify them.
 Files ending in _test.tl are tests, _example.tl are examples,
 all others are sources.

**Parameters:**

- `dir` (string) - Directory to scan

**Returns:**

- Project - Classified project files

### generate

```teal
function generate(project: Project, config?: Config): string
```

 Generate a Makefile string from a classified project.

**Parameters:**

- `project` (Project) - The classified project files
- `config` (Config) - Optional configuration (uses defaults if nil)

**Returns:**

- string - The generated Makefile content

### run

```teal
function run(dir?: string, target?: string): boolean, string
```

 Scan a directory, generate a Makefile, and optionally pipe to make.

**Parameters:**

- `dir` (string) - Directory to scan (nil: print to stdout)
- `target` (string) - Target to run (nil: run default target)

**Returns:**

- boolean, - string Success and command or error message
