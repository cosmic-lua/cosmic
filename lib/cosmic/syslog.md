# syslog

 System logging.
 Wraps unix.syslog() for writing to the system log.

## Types

### SyslogModule

```teal
local record SyslogModule
  write: function(priority: number, message: string)
  emerg: function(message: string)
  alert: function(message: string)
  crit: function(message: string)
  err: function(message: string)
  warning: function(message: string)
  notice: function(message: string)
  info: function(message: string)
  debug: function(message: string)
  LOG_EMERG: number
  LOG_ALERT: number
  LOG_CRIT: number
  LOG_ERR: number
  LOG_WARNING: number
  LOG_NOTICE: number
  LOG_INFO: number
  LOG_DEBUG: number
end
```

## Functions

### write

```teal
function write(priority: number, message: string)
```

 Write a message to the system log.

**Parameters:**

- `priority` (number) - Log priority (LOG_EMERG through LOG_DEBUG)
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

### debug

```teal
function debug(message: string)
```

 Write a debug message to the system log.

**Parameters:**

- `message` (string) - The message to log
