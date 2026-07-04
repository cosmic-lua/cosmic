# stats

 Basic statistics over benchmark samples.
 All functions return 0 for an empty input list.

## Types

### stats

```teal
local record stats
  sorted: function(values: {number}): {number}
  min: function(values: {number}): number
  max: function(values: {number}): number
  mean: function(values: {number}): number
  median: function(values: {number}): number
  stddev: function(values: {number}): number
  spread_pct: function(values: {number}): number
end
```
