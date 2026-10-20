--- A Content-Security-Policy as data: a [`Csp.Policy`] of directives and
--- their sources, the policy [`cosmic.web.headers.middleware`]'s `csp` takes, and the
--- header value it formats to.
---
---     local policy = Csp.htmx_default()
---     print(Csp.format(policy))

local record Csp
  --- A policy: the directives and their sources.
  record Policy
    --- Directive name to its sources. A directive with {} is written bare
    --- ("upgrade-insecure-requests"). The source "{nonce}" is replaced by
    --- "'nonce-<value>'" for each request. A name that is no directive name,
    --- or a source holding a space, ";", "," or a control byte, raises when
    --- the policy is formatted: it could end the directive and start another.
    directives: {string:{string}}
  end
end

local DIRECTIVE <const> = "^[a-z][a-z0-9-]*$"

--- A policy that lets an htmx app load its own scripts, styles, images, fonts
--- and connections and nothing else: no inline script or style, no plugins,
--- no `<base>`, forms only to this origin, never framed. Put `{nonce}` in
--- `script-src` to allow the layout's inline scripts.
--- @return Csp.Policy The policy
function Csp.htmx_default(): Csp.Policy
  return { directives = {
    ["default-src"] = { "'self'" },
    ["script-src"] = { "'self'" },
    ["style-src"] = { "'self'" },
    ["img-src"] = { "'self'", "data:" },
    ["font-src"] = { "'self'" },
    ["connect-src"] = { "'self'" },
    ["object-src"] = { "'none'" },
    ["base-uri"] = { "'none'" },
    ["form-action"] = { "'self'" },
    ["frame-ancestors"] = { "'none'" },
  } }
end

--- The policy as a header value: directives in name order, each name then
--- its sources, joined by "; ". Raises for a name or source that could
--- end its directive, and for a "{nonce}" source with no `nonce`.
--- @param p Csp.Policy The policy
--- @param nonce string | nil The request's nonce, base64url
--- @return string The header value
function Csp.format(p: Csp.Policy, nonce?: string): string
  local names: {string} = {}
  for name in pairs(p.directives) do
    if type(name) ~= "string" or not name:find(DIRECTIVE) then
      error(("csp: %q is not a directive name"):format(tostring(name)), 2)
    end
    names[#names + 1] = name
  end
  table.sort(names)
  local out: {string} = {}
  for _, name in ipairs(names) do
    local parts: {string} = { name }
    for _, source in ipairs(p.directives[name]) do
      if source == "{nonce}" then
        if nonce == nil or nonce == "" then
          error("csp: the policy has a {nonce} source and no nonce was given", 2)
        end
        source = "'nonce-" .. nonce .. "'"
      elseif type(source) ~= "string" or source == "" or source:find("[%c%s;,]") then
        error(("csp: %s: %q is not a source"):format(name, tostring(source)), 2)
      end
      parts[#parts + 1] = source
    end
    out[#out + 1] = table.concat(parts, " ")
  end
  return table.concat(out, "; ")
end

return Csp
