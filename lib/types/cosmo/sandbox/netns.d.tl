-- type declarations for cosmo.sandbox.netns
--
-- Raw cosmo.sandbox.netns surface. cosmic.quicksand.netns wraps this
-- with typed return values and cosmic's value,string error shape.

local record netns
  --- Build a struct ifreq wire blob for SIOC*IFFLAGS ioctls.
  build_ifreq: function(name: string, flags: integer): string

  --- Parse the 16-bit flags field out of an ifreq returned by ioctl.
  parse_ifreq_flags: function(ifr: string): integer

  --- Open an AF_INET dgram control socket for the SIOC* ioctls.
  --- Caller owns and must close the fd.
  control_socket: function(): integer, any

  --- Read the current IFF_* flags on `name` in the current net ns.
  get_flags: function(name: string): integer, any

  --- Set the IFF_* flags on `name` in the current net ns.
  set_flags: function(name: string, flags: integer): boolean, any

  --- Bring `name` up in the current net ns (idempotent).
  bring_up: function(name: string): boolean, any

  --- Bring `name` down in the current net ns (idempotent).
  bring_down: function(name: string): boolean, any

  --- Open /proc/<pid>/ns/net as a file descriptor. Omit pid (or pass
  --- nil/"self") to open the current process's net ns.
  open: function(pid: integer): integer, any
end

return netns
