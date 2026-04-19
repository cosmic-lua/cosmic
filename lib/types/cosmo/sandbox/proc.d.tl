-- type declarations for cosmo.sandbox.proc
--
-- Raw cosmo.sandbox.proc surface. cosmic.quicksand.proc wraps this with
-- Teal records and cosmic's value,string error shape.

local record Barrier
  signal: function(self: Barrier)
  wait: function(self: Barrier)
  drop_read: function(self: Barrier)
  drop_write: function(self: Barrier)
end

local record proc
  DEFAULT_SIGNALS: {string}

  --- Set PR_SET_NO_NEW_PRIVS on the current process. Once set, execve
  --- no longer grants setuid/file-cap privileges and seccomp filters
  --- become installable without CAP_SYS_ADMIN.
  no_new_privs: function(): boolean, any

  --- Drop to (uid, gid) and clear capabilities. If uid is nil, no-op.
  --- If uid == 0, stay root but still clear caps.
  drop_privs: function(uid: integer, gid: integer): boolean, any

  --- Write the current process's /proc/self/{setgroups,uid_map,gid_map}
  --- to map the outer (uid, gid) to themselves inside a newly-created
  --- user namespace. Must be called from the child after unshare(CLONE_NEWUSER)
  --- and before any operation that requires credentials in the new
  --- namespace. Passing nil for uid / gid keeps the caller's real id.
  setup_userns_maps: function(uid?: integer, gid?: integer): boolean, any

  --- Pipe-backed one-shot fork-sync barrier.
  barrier: function(): Barrier, any

  --- PID-1 supervisor loop. Forwards signals to main_pid, reaps all
  --- children, propagates main_pid's exit status. opts is a plain
  --- table: { sidecars, signals, on_sidecar_exit }.
  become_init: function(main_pid: integer, opts: any): integer
end

return proc
