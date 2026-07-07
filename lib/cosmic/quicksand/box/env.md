# env

 Pure env-policy helpers for cosmic.quicksand.Box.

 Given an env policy (`keep` list, `set` map) and the parent
 environment, return the env dict the boxed workload should see.

 Semantics:
   keep   list of variable names to inherit from the parent
          environment. Variables not in keep are dropped.
   set    map of names to values that override / add to keep.

 Both fields are optional:
   nil keep  → inherit nothing (empty starting set)
   nil set   → no overrides

 Nothing here touches real process env — callers apply the result via
 their own setenv loop after fork, before execve.

## Types

### BoxEnvModule

```teal
local record BoxEnvModule
  apply: function(opts: EnvOpts, parent: {string: string}): {string: string}
  render: function(env: {string: string}): {string}
end
```

## Functions

### apply

```teal
function apply(opts: EnvOpts, parent: {string: string}): {string: string}
```

### render

```teal
function render(env: {string: string}): {string}
```

 Render an env dict as an array of "NAME=VALUE" strings, sorted by
 name for stable output. Useful for execvpe-style APIs and for
 deterministic diffing in tests.
