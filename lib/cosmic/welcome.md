# welcome

## Types

### Appender

```teal
local record Appender
  add: function(self: Appender, name: string, content: string): boolean | nil, string | nil
  close: function(self: Appender)
end
```
