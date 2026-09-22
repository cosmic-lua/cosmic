--- The production POSIX launcher template for portable artifacts.
---
--- This is a Teal module, rather than a loose build-time asset, because a
--- shipped Cosmic reads `build.artifact` and its dependencies from its Store
--- projection. Only the generated target arms are substituted into it.

local record launcher
end

local template = [=[#!/bin/sh
# Cosmic portable artifact format v1.
#
# The directory containing the managed cache leaf is the trust boundary: it
# must be controlled by this user. The launcher lstat-checks the leaf and its
# entries, but does not claim to make a hostile HOME or cache parent safe.

portable_die() {
  printf 'cosmic portable: %s\n' "$*" >&2
  exit 126
}

# Select two unused descriptors before opening anything or mutating the cache.
# Each literal candidate is probed in both directions in child shells: a
# readability-only probe misses writable descriptors, while the pair also
# catches inherited sockets. Only the controlled numeric left-hand side of a
# redirection is evaluated below; path strings stay quoted variable references.
cosmic_artifact_fd=
cosmic_core_fd=
for portable_candidate in 3 4 5 6 7 8 9; do
  if ! (: <&"$portable_candidate") 2>/dev/null &&
     ! (: >&"$portable_candidate") 2>/dev/null; then
    if [ -z "$cosmic_artifact_fd" ]; then
      cosmic_artifact_fd=$portable_candidate
    else
      cosmic_core_fd=$portable_candidate
      break
    fi
  fi
done
[ -n "$cosmic_core_fd" ] ||
  portable_die 'fewer than two private descriptors are available in 3 through 9'

case $0 in
  /*) cosmic_artifact=$0 ;;
  *) cosmic_artifact=$PWD/$0 ;;
esac

case "$(uname -s):$(uname -m)" in
@TARGETS@
  *) portable_die 'unsupported target' ;;
esac
@SELECT_HOOK@

# Keep this open across extraction and exec. Step 5 adopts this descriptor;
# extraction deliberately reads it rather than reopening the pathname.
eval 'exec '"$cosmic_artifact_fd"'<"$cosmic_artifact"' ||
  portable_die 'cannot open the portable artifact'
@ADOPT_HOOK@

if [ "${COSMIC_PORTABLE_CACHE+x}" = x ]; then
  cosmic_cache=${COSMIC_PORTABLE_CACHE-}
  case $cosmic_cache in
    /*) ;;
    *) portable_die 'COSMIC_PORTABLE_CACHE must be an absolute path' ;;
  esac
else
  case ${XDG_CACHE_HOME-} in
    /*) cosmic_cache=$XDG_CACHE_HOME/cosmic/cores ;;
    *)
      case ${HOME-} in
        /*) cosmic_home=$HOME ;;
        *) portable_die 'no absolute HOME is available for the portable cache' ;;
      esac
      case $cosmic_os in
        Darwin) cosmic_cache=$cosmic_home/Library/Caches/cosmic/cores ;;
        *) cosmic_cache=$cosmic_home/.cache/cosmic/cores ;;
      esac
      ;;
  esac
fi

# A trailing slash makes lstat-style commands follow a symlink-to-directory.
# Remove only trailing separators, retaining the root path itself; earlier
# components remain inside the documented trusted-parent boundary.
while [ "$cosmic_cache" != / ] && [ "${cosmic_cache%/}" != "$cosmic_cache" ]; do
  cosmic_cache=${cosmic_cache%/}
done

cosmic_original_umask=$(umask) || portable_die 'cannot read caller umask'
umask 077
if [ -L "$cosmic_cache" ]; then
  portable_die "cache leaf is a symbolic link: $cosmic_cache"
fi
if [ ! -e "$cosmic_cache" ]; then
  mkdir -p "$cosmic_cache" || portable_die "cannot create cache leaf: $cosmic_cache"
fi

portable_lstat() {
  case $cosmic_os in
    Linux) LC_ALL=C stat -c '%F|%u|%a|%s' -- "$1" ;;
    Darwin) LC_ALL=C stat -f '%HT|%u|%Lp|%z' "$1" ;;
    *) return 1 ;;
  esac
}

portable_kind=
portable_owner=
portable_mode=
portable_size=
portable_stat() {
  portable_fields=$(portable_lstat "$1") || return 1
  portable_kind=${portable_fields%%|*}
  portable_fields=${portable_fields#*|}
  portable_owner=${portable_fields%%|*}
  portable_fields=${portable_fields#*|}
  portable_mode=${portable_fields%%|*}
  portable_size=${portable_fields#*|}
  return 0
}

portable_uid=$(id -u) || portable_die 'cannot determine cache owner'
portable_stat "$cosmic_cache" || portable_die "cannot inspect cache leaf: $cosmic_cache"
case $portable_kind in
  directory|'Directory') ;;
  *) portable_die "cache leaf is not a directory: $cosmic_cache" ;;
esac
[ "$portable_owner" = "$portable_uid" ] ||
  portable_die "cache leaf has a different owner: $cosmic_cache"
case $portable_mode in
  700) cosmic_cache_writable=1 ;;
  500) cosmic_cache_writable=0 ;;
  *) portable_die "cache leaf mode must be 0700 or 0500: $cosmic_cache" ;;
esac

portable_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    portable_sum=$(sha256sum < "$1") || return 1
  elif command -v shasum >/dev/null 2>&1; then
    portable_sum=$(shasum -a 256 < "$1") || return 1
  else
    return 1
  fi
  printf '%s\n' "${portable_sum%% *}"
}

cosmic_key=core-$cosmic_target_id-$cosmic_configuration_id-$cosmic_length-$cosmic_sha256
cosmic_core=$cosmic_cache/$cosmic_key
cosmic_repair_lock=$cosmic_cache/.repair-$cosmic_key
cosmic_stage=
cosmic_owns_repair_lock=0

portable_cleanup() {
  if [ -n "$cosmic_stage" ]; then rm -f "$cosmic_stage"; fi
  if [ "$cosmic_owns_repair_lock" = 1 ]; then rm -f "$cosmic_repair_lock"; fi
}
trap 'portable_cleanup' EXIT
trap 'exit 126' HUP INT TERM

portable_entry_state=
portable_entry_reason=
portable_inspect_entry() {
  if [ -L "$cosmic_core" ]; then
    portable_entry_state=invalid
    portable_entry_reason='is a symbolic link'
    return 0
  fi
  if [ ! -e "$cosmic_core" ]; then
    portable_entry_state=missing
    portable_entry_reason='is absent'
    return 0
  fi
  if ! portable_stat "$cosmic_core"; then
    portable_entry_state=invalid
    portable_entry_reason='cannot be inspected'
    return 0
  fi
  case $portable_kind in
    'regular file'|'Regular File') ;;
    *)
      portable_entry_state=invalid
      portable_entry_reason='is not a regular file'
      return 0
      ;;
  esac
  if [ "$portable_owner" != "$portable_uid" ]; then
    portable_entry_state=invalid
    portable_entry_reason='has a different owner'
    return 0
  fi
  if [ "$portable_mode" != 500 ]; then
    portable_entry_state=invalid
    portable_entry_reason='mode is not 0500'
    return 0
  fi
  if [ "$portable_size" != "$cosmic_length" ]; then
    portable_entry_state=invalid
    portable_entry_reason='length differs'
    return 0
  fi
  portable_actual=$(portable_sha256 "$cosmic_core") || portable_actual=
  if [ "$portable_actual" != "$cosmic_sha256" ]; then
    portable_entry_state=invalid
    portable_entry_reason='digest differs'
    return 0
  fi
  portable_entry_state=valid
  portable_entry_reason=
  return 0
}

# Both forms prevent a symlink destination from being followed. GNU -T also
# disables its destination-directory interpretation. BSD -h supplies the
# no-dereference behavior; an existing real directory is removed or rejected
# by the lstat repair path before this is called.
portable_link() {
  case $cosmic_os in
    Linux) ln -T "$1" "$2" || return 1 ;;
    Darwin) ln -h "$1" "$2" || return 1 ;;
    *) return 1 ;;
  esac
  # BSD ln can interpret an existing real directory as the destination even
  # with -h. Refuse that result and remove only the link this call just made.
  if ! portable_stat "$2"; then return 1; fi
  case $portable_kind in
    'regular file'|'Regular File') return 0 ;;
    *)
      portable_nested=$2/${1##*/}
      rm -f "$portable_nested" 2>/dev/null || :
      return 1
      ;;
  esac
}

portable_release_repair_lock() {
  rm -f "$cosmic_repair_lock" || portable_die 'cannot release cache repair lock'
  cosmic_owns_repair_lock=0
}

portable_acquire_repair_lock() {
  cosmic_stage=$(mktemp "$cosmic_cache/.repair-owner.XXXXXXXX") ||
    portable_die 'cannot create cache repair owner'
  printf '%s\n' "$$" > "$cosmic_stage" || portable_die 'cannot write cache repair owner'
  if ! portable_link "$cosmic_stage" "$cosmic_repair_lock" 2>/dev/null; then
    rm -f "$cosmic_stage"
    cosmic_stage=
    # Never remove a lock observed here: doing so can race a new owner. Normal
    # signal interruption removes the owner's lock through the trap; SIGKILL
    # may leave this private, plainly named file for its owner to remove.
    portable_die "cache repair is already locked: $cosmic_repair_lock"
  fi
  rm -f "$cosmic_stage"
  cosmic_stage=
  cosmic_owns_repair_lock=1
}

portable_remove_invalid_entry() {
  portable_stat "$cosmic_core" || portable_die 'cannot reinspect invalid cache entry'
  case $portable_kind in
    directory|'Directory')
      rmdir "$cosmic_core" || portable_die 'invalid cache entry directory is not empty'
      ;;
    *) rm -f "$cosmic_core" || portable_die 'cannot remove invalid cache entry' ;;
  esac
}

portable_inspect_entry
cosmic_core_verified=0
if [ "$portable_entry_state" = invalid ]; then
  [ "$cosmic_cache_writable" = 1 ] ||
    portable_die "cache entry $portable_entry_reason and cache is read-only"
  printf 'cosmic portable: cache entry %s; repairing\n' "$portable_entry_reason" >&2
  portable_acquire_repair_lock
@REPAIR_HOOK@
  # The lock covers only the lstat/unlink transition. Extraction and hard-link
  # publication remain lock-free, and no repairer can unlink a published winner.
  portable_inspect_entry
  if [ "$portable_entry_state" = invalid ]; then
    portable_remove_invalid_entry
  fi
  portable_release_repair_lock
fi

if [ "$portable_entry_state" = valid ]; then
  cosmic_core_verified=1
fi
if [ "$cosmic_core_verified" != 1 ]; then
  portable_inspect_entry
fi
if [ "$portable_entry_state" != valid ]; then
  [ "$cosmic_cache_writable" = 1 ] ||
    portable_die 'selected core is absent and cache is read-only'
  cosmic_stage=$(mktemp "$cosmic_cache/.core.XXXXXXXX") ||
    portable_die 'cannot create core staging entry'
  cosmic_blocks=$(( (cosmic_length + 16383) / 16384 ))
  # `head` trims the final aligned block. POSIX sh has no pipefail, so pipeline
  # success cannot prove dd supplied the requested input: the exact size check
  # detects truncation, while SHA-256 separately detects equal-length corruption.
  dd bs=16384 skip="$cosmic_block" count="$cosmic_blocks" \
    <&"$cosmic_artifact_fd" 2>/dev/null |
    head -c "$cosmic_length" > "$cosmic_stage"
  portable_bytes=$(wc -c < "$cosmic_stage") || portable_die 'cannot size extracted core'
  [ "$portable_bytes" -eq "$cosmic_length" ] || portable_die 'extracted core is truncated'
  portable_actual=$(portable_sha256 "$cosmic_stage") || portable_actual=
  [ "$portable_actual" = "$cosmic_sha256" ] ||
    portable_die 'extracted core digest differs'
  chmod 500 "$cosmic_stage" || portable_die 'cannot finish extracted core mode'
@PUBLISH_HOOK@
  if portable_link "$cosmic_stage" "$cosmic_core" 2>/dev/null; then
    cosmic_core_verified=1
  else
    portable_inspect_entry
    [ "$portable_entry_state" = valid ] || portable_die 'cannot publish or validate core winner'
    cosmic_core_verified=1
  fi
  rm -f "$cosmic_stage"
  cosmic_stage=
fi

# A warm winner is hashed once above. A cold publisher has already hashed its
# stage and linked that same inode; a losing publisher hashes the winner once.
[ "$cosmic_core_verified" = 1 ] || portable_die 'selected core was not verified'
eval 'exec '"$cosmic_core_fd"'<"$cosmic_core"' ||
  portable_die 'cannot open verified core descriptor'

# This is the complete bounded private launcher/startup environment contract.
COSMIC_PORTABLE_ARTIFACT_FD=$cosmic_artifact_fd
COSMIC_PORTABLE_CORE_FD=$cosmic_core_fd
COSMIC_PORTABLE_TARGET_ID=$cosmic_target_id
COSMIC_PORTABLE_CONFIGURATION_ID=$cosmic_configuration_id
COSMIC_PORTABLE_CORE_OFFSET=$cosmic_offset
COSMIC_PORTABLE_CORE_LENGTH=$cosmic_length
COSMIC_PORTABLE_CORE_SHA256=$cosmic_sha256
export COSMIC_PORTABLE_ARTIFACT_FD COSMIC_PORTABLE_CORE_FD
export COSMIC_PORTABLE_TARGET_ID COSMIC_PORTABLE_CONFIGURATION_ID
export COSMIC_PORTABLE_CORE_OFFSET COSMIC_PORTABLE_CORE_LENGTH
export COSMIC_PORTABLE_CORE_SHA256

# Where test(1) asks the kernel, `test -x` also reflects a noexec filesystem.
# Check before the special-builtin exec: a non-interactive shell exits on
# execve failure and never reaches a diagnostic after it.
[ -x "$cosmic_core" ] ||
  portable_die 'verified core cannot execute on the cache filesystem'
trap - HUP INT TERM
umask "$cosmic_original_umask" || portable_die 'cannot restore caller umask'
# BusyBox test answers `-x` from the mode bits alone, so there a noexec cache
# passes the check above and the exec itself fails. ash, dash and mksh still
# run the EXIT trap as they exit on that failure, and a successful exec
# replaces the shell before any trap can run. The shell has already printed
# the errno. 126 is any core found but refused (E2BIG and an LSM denial too),
# so the hint names noexec only as the reading of a Permission denied there.
portable_exec_failed() {
  trap - EXIT
  case $1 in
    126) portable_die 'verified core was refused execution; Permission denied here usually means a noexec cache filesystem' ;;
    *) portable_die 'cannot execute verified core' ;;
  esac
}
trap 'portable_exec_failed "$?"' EXIT
exec "$cosmic_core" --artifact "$cosmic_artifact" "$@"
exit
]=]

local test_hook_function = [=[portable_test_hook() {
  [ "${COSMIC_PORTABLE_TEST_HOOK-}" = "$1" ] || return 0
  [ -n "${COSMIC_PORTABLE_TEST_READY-}" ] || portable_die 'test hook names no ready FIFO'
  [ -n "${COSMIC_PORTABLE_TEST_GO-}" ] || portable_die 'test hook names no release FIFO'
  printf 'ready\n' > "$COSMIC_PORTABLE_TEST_READY"
  IFS= read -r portable_test_release < "$COSMIC_PORTABLE_TEST_GO" ||
    portable_die 'test hook was not released'
}
]=]

local function substitute(text: string, marker: string, replacement: string): string
  return (text:gsub(marker, function(): string return replacement end))
end

--- Renders a release launcher, or a fixture-only launcher with deterministic
--- FIFO gates. Release bytes contain neither the hooks nor their environment
--- names.
function launcher.render(arms: string, test_hooks: boolean): string
  local rendered = substitute(template, "@TARGETS@", arms)
  if test_hooks then
    rendered = substitute(rendered, "@SELECT_HOOK@",
      "portable_test_hook after_select")
    rendered = substitute(rendered, "@ADOPT_HOOK@",
      "portable_test_hook after_artifact_open")
    rendered = substitute(rendered, "@REPAIR_HOOK@",
      "  portable_test_hook after_repair_lock")
    rendered = substitute(rendered, "@PUBLISH_HOOK@",
      "  portable_test_hook before_publish")
    rendered = rendered:gsub("portable_die%(%) %{", test_hook_function .. "\nportable_die() {")
  else
    rendered = substitute(rendered, "@SELECT_HOOK@", "")
    rendered = substitute(rendered, "@ADOPT_HOOK@", "")
    rendered = substitute(rendered, "@REPAIR_HOOK@", "")
    rendered = substitute(rendered, "@PUBLISH_HOOK@", "")
  end
  return rendered
end

return launcher
