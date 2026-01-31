# require

 Enhanced require with helpful error messages.
 Intercepts module-not-found errors and suggests similar modules.

## Types

### RequireModule

```teal
local record RequireModule
  install: function()
  uninstall: function()
  module_exists: function(name: string): boolean
  format_error: function(name: string): string
end
```

## Functions

### module_exists

```teal
function module_exists(name: string): boolean
```

 Check if a module exists without loading it.

**Parameters:**

- `name` (string) - Module name to check

**Returns:**

- boolean - True if module can be loaded

### format_error

```teal
function format_error(name: string): string
```

 Format a helpful error message for module not found.

**Parameters:**

- `name` (string) - The requested module name

**Returns:**

- string - Enhanced error message with suggestions

### install

```teal
function install()
```

 Install enhanced require globally.
 Call this early in startup to enable helpful error messages.

### uninstall

```teal
function uninstall()
```

 Restore original require.
 Useful for testing or disabling enhanced errors.
