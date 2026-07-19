# syslog

 System logging.
 Wraps unix.syslog() for writing to the system log.

## Types

### SyslogModule

```teal
local record SyslogModule
  write: function(priority: integer, message: string)
  emerg: function(message: string)
  alert: function(message: string)
  crit: function(message: string)
  err: function(message: string)
  warning: function(message: string)
  notice: function(message: string)
  info: function(message: string)
  debug: function(message: string)
  LOG_EMERG: integer
  LOG_ALERT: integer
  LOG_CRIT: integer
  LOG_ERR: integer
  LOG_WARNING: integer
  LOG_NOTICE: integer
  LOG_INFO: integer
  LOG_DEBUG: integer
end
```

## Functions

### write

```teal
function write(priority: integer, message: string)
```

 Write a message to the system log.

**Parameters:**

- `priority` (integer) - Log priority (LOG_EMERG through LOG_DEBUG)
- `message` (string) - The message to log

### emerg

```teal
function emerg(message: string)
```

 Write an emergency message to the system log.

**Parameters:**

- `message` (string) - The message to log

### alert

```teal
function alert(message: string)
```

 Write an alert message to the system log.

**Parameters:**

- `message` (string) - The message to log

### crit

```teal
function crit(message: string)
```

 Write a critical message to the system log.

**Parameters:**

- `message` (string) - The message to log

### err

```teal
function err(message: string)
```

 Write an error message to the system log.

**Parameters:**

- `message` (string) - The message to log

### warning

```teal
function warning(message: string)
```

 Write a warning message to the system log.

**Parameters:**

- `message` (string) - The message to log

### notice

```teal
function notice(message: string)
```

 Write a notice message to the system log.

**Parameters:**

- `message` (string) - The message to log

### info

```teal
function info(message: string)
```

 Write an info message to the system log.

**Parameters:**

- `message` (string) - The message to log
