-- type declarations for cosmo.sandbox (umbrella module)
--
-- cosmic.quicksand wraps this with typed Capabilities record + error
-- shape. Callers should prefer cosmic.quicksand over these.

local record sandbox
  _VERSION: string

  --- Probe the host for fine-grained feature availability. Cached
  --- after the first call. Returns a plain table with boolean fields:
  --- linux, user_ns, mount_ns, net_ns, uts_ns, pid_ns, pivot_root,
  --- cap_net_admin, landlock, pledge, unveil. pledge and unveil are
  --- probed via a no-op call, so they report true on Linux+seccomp
  --- and OpenBSD, and on Linux+Landlock-backed unveil.
  capabilities: function(): any

  --- True when the primitives in this module can do real work (Linux
  --- with namespace bindings linked in).
  is_supported: function(): boolean
end

return sandbox
