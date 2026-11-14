--- The launcher `cosmic release --launcher` writes into a project that is
--- built with a pinned cosmic release: a POSIX shell script the project
--- keeps as its own bin/cosmic. It reads the pin beside it (`<name>.pin`,
--- the three lines `cosmic release --pin` writes), fetches that release
--- once, checks it against the pin's sha256 and caches it by that digest,
--- then runs it with the arguments given. It is the part of
--- [`bin/cosmic-bootstrap`] a project needs: nothing downloaded runs
--- before its digest is the pin's, the cache is the one that script and
--- `cosmic release --cache` fill, and `COSMIC_TOOL` names another cosmic
--- to run in place of the pin's, as `COSMIC_BOOTSTRAP` does there. The
--- script's own leading comment says the rest, to the one who reads it
--- in a project.

local record pinned_launcher
end

--- The script, with `@NAME@` where the launcher's own file name goes.
local template <const> = [[
#!/bin/sh
# Written by `cosmic release --launcher`: write it again with that
# command, not by hand.
#
# Runs the cosmic release that @NAME@.pin, beside this script, names,
# with the arguments given, in the caller's directory, answering its
# exit status. The pin is three lines: a commit of cosmic-lua/cosmic,
# that commit's release URL, and the binary's sha256.
# `cosmic release --pin <the pin>` moves it.
#
# The binary is cached by digest, as
# $XDG_CACHE_HOME/cosmic/bootstrap/cosmic-<sha256> (default
# ~/.cache/cosmic/bootstrap/...), where `cosmic release --cache` puts
# one too. It is downloaded to a .part file beside that name, checked
# against the pin, made executable, and only then renamed into place:
# nothing downloaded runs before its sha256 is the pin's, and a warm
# run reads the pin and nothing else. A download that fails, or whose
# sha256 is not the pin's, is tried again from an empty .part file, up
# to COSMIC_TOOL_ATTEMPTS times (default 5).
#
# A cache this script did not fill (one a CI job restored) is checked
# again when COSMIC_TOOL_VERIFY is set: a cached file whose sha256 is
# not the pin's is removed and fetched afresh.
#
# COSMIC_TOOL, when set, names another cosmic to run in place of the
# pin's: one built from a checkout of cosmic, say. It must be an
# executable file; anything else is an error, never a silent fallback
# to the pin. Nothing is fetched or checked then, so it is refused
# together with COSMIC_TOOL_VERIFY. The cosmic it names runs with
# COSMIC_TOOL an absolute path, so that a launcher it starts in another
# directory runs the same one.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pin=$here/@NAME@.pin

die() {
  printf '%s: %s\n' "$here/@NAME@" "$1" >&2
  exit 1
}

if [ -n "${COSMIC_TOOL:-}" ]; then
  if [ -n "${COSMIC_TOOL_VERIFY:-}" ]; then
    die "COSMIC_TOOL and COSMIC_TOOL_VERIFY are both set: a stand-in is no digest-checked cosmic"
  fi
  if [ ! -f "$COSMIC_TOOL" ] || [ ! -x "$COSMIC_TOOL" ]; then
    die "COSMIC_TOOL=$COSMIC_TOOL is not an executable file"
  fi
  # A stand-in of this script would run itself without end.
  if [ "$COSMIC_TOOL" -ef "$0" ] || [ "$COSMIC_TOOL" -ef "$here/@NAME@" ]; then
    die "COSMIC_TOOL=$COSMIC_TOOL is this launcher, not a cosmic; name a built one"
  fi
  case $COSMIC_TOOL in
    /*) ;;
    *) COSMIC_TOOL=$(pwd)/$COSMIC_TOOL ;;
  esac
  export COSMIC_TOOL
  exec "$COSMIC_TOOL" "$@"
fi

[ -f "$pin" ] || die "no pin at $pin"
[ "$(wc -l < "$pin" | tr -d ' ')" = 3 ] || die "$pin is not three lines"
commit=$(sed -n '1p' "$pin")
url=$(sed -n '2p' "$pin")
digest=$(sed -n '3p' "$pin")
case $commit in *[!0-9a-f]* | '') die "$pin: line 1 is not a commit" ;; esac
[ "${#commit}" -eq 40 ] || die "$pin: line 1 is not a commit"
case $digest in *[!0-9a-f]* | '') die "$pin: line 3 is not a sha256" ;; esac
[ "${#digest}" -eq 64 ] || die "$pin: line 3 is not a sha256"
# A release is tagged YYYYMMDD-<commit>, or next-<commit> as the earlier
# ones are; the pin may name either.
base=https://github.com/cosmic-lua/cosmic/releases/download/
case $url in
  "$base"next-"$commit"/cosmic) ;;
  "$base"[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-"$commit"/cosmic) ;;
  *) die "$pin: line 2 is not the release of line 1's commit" ;;
esac

attempts=${COSMIC_TOOL_ATTEMPTS:-5}
case $attempts in
  [1-9] | 1[0-9] | 20) ;;
  *) die "COSMIC_TOOL_ATTEMPTS=$attempts is not a count from 1 to 20" ;;
esac

if [ -n "${XDG_CACHE_HOME:-}" ]; then
  cache=$XDG_CACHE_HOME/cosmic/bootstrap
else
  cache=${HOME:?HOME is unset}/.cache/cosmic/bootstrap
fi
cached=$cache/cosmic-$digest

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    die "need sha256sum or shasum to verify $url"
  fi
}

if [ -n "${COSMIC_TOOL_VERIFY:-}" ] && { [ -e "$cached" ] || [ -L "$cached" ]; }; then
  if [ -L "$cached" ] || [ ! -f "$cached" ]; then
    rm -f "$cached" || die "cannot remove $cached, which is not the pin's"
  else
    # An assignment, so a missing hash tool stops the script here.
    got=$(sha256_file "$cached")
    if [ "$got" != "$digest" ]; then
      rm -f "$cached" || die "cannot remove $cached, which is not the pin's"
    fi
  fi
fi

if [ ! -f "$cached" ] || [ ! -x "$cached" ]; then
  mkdir -p "$cache"
  partial=$cache/.cosmic-$digest.$$.part
  trap 'rm -f "$partial"' EXIT
  trap 'rm -f "$partial"; exit 1' HUP INT TERM
  if command -v curl >/dev/null 2>&1; then
    # One attempt gives up on no connection in 30 s, or on a stream
    # under 1 KiB/s for 60 s straight: a dead stream, not a slow one.
    fetch() {
      curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
        --output "$partial" "$url"
    }
  elif command -v wget >/dev/null 2>&1; then
    # wget has no minimum speed, so 30 s of silence ends an attempt. It
    # makes one try; the loop below makes the rest.
    fetch() { wget -q --timeout=30 --tries=1 -O "$partial" "$url"; }
  else
    die "need curl or wget to fetch $url"
  fi
  # Every attempt starts from no partial file, and a download whose
  # digest is wrong is tried again too, since a truncated transfer can
  # end without an error.
  attempt=1
  while :; do
    rm -f "$partial"
    if fetch; then
      got=$(sha256_file "$partial")
      [ "$got" = "$digest" ] && break
      why="$url has sha256 $got; the pin says $digest"
    else
      why="download failed: $url"
    fi
    if [ "$attempt" -ge "$attempts" ]; then
      rm -f "$partial"
      [ "$attempt" -eq 1 ] && die "$why (after 1 attempt)"
      die "$why (after $attempt attempts)"
    fi
    printf '%s: %s; retrying in %ss\n' "$here/@NAME@" "$why" "$((attempt * 2))" >&2
    sleep "$((attempt * 2))"
    attempt=$((attempt + 1))
  done
  chmod 755 "$partial"
  # Another process may have won the race; its file is the same bytes.
  mv -f "$partial" "$cached"
  trap - EXIT HUP INT TERM
fi

exec "$cached" "$@"
]]

--- The launcher to write at a file named `name`, which reads the pin
--- `<name>.pin` beside it; or nil and why `name` will not do. The name
--- is written into the script as it is, so it is held to letters, digits,
--- `.`, `_` and `-`, the first no `-`: nothing a shell reads as more
--- than a word.
function pinned_launcher.script(name: string): string?, string
  if name:find("^[%w._][%w._-]*$") == nil then
    return nil, "a launcher is named with letters, digits, '.', '_' and '-', not " .. name
  end
  return (template:gsub("@NAME@", function(): string return name end)), ""
end

return pinned_launcher
