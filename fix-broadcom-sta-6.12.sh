#!/bin/bash
# Re-apply the kernel-6.12 compat patch to broadcom-sta and rebuild via dkms.
# Idempotent. Safe to run any time. Exits 0 if already correct.
#
# Usage:  fix-broadcom-sta-6.12.sh [--reload]
#   --reload   also unload/reload the wl module so the running driver matches
#              (skipped by default; wlp4s0 is normally idle/static anyway)
set -eu

RELOAD=0
if [ "${1:-}" = "--reload" ]; then RELOAD=1; fi

STORE=/usr/local/share/broadcom-sta-patch
OLD='#include <asm/unaligned.h>'
NEW='#include <linux/unaligned.h>'

say()  { printf '  %s\n' "$*"; }
fail() { printf '  FAIL: %s\n' "$*" >&2; exit 1; }

SRC=$(ls -d /usr/src/broadcom-sta-* 2>/dev/null | head -1 || true)
[ -n "$SRC" ] || fail "no /usr/src/broadcom-sta-* tree (package removed?)"
F="$SRC/src/wl/sys/wl_linux.c"
[ -f "$F" ] || fail "$F not found"

say "source: $SRC"

# ---- already correct? ----
if grep -qF "$NEW" "$F" && ! grep -qF "$OLD" "$F"; then
  say "patch: ALREADY APPLIED"
else
  say "patch: NOT applied - fixing"
  # restore from pristine first if we have it, so we never double-patch
  if [ -f "$STORE/wl_linux.c.pristine" ]; then
    cp -p "$STORE/wl_linux.c.pristine" "$F"
    say "restored pristine source"
  fi
  if ! grep -qF "$OLD" "$F"; then
    fail "expected line '$OLD' not found - source changed upstream?"
  fi
  sed -i "s|$OLD|$NEW|" "$F"
  say "applied one-line fix"
fi

# ---- verify ----
if ! grep -qF "$NEW" "$F"; then fail "verification failed: $NEW absent"; fi
if grep -qF "$OLD" "$F"; then fail "verification failed: $OLD still present"; fi
say "verify: linux/unaligned.h present, asm/unaligned.h absent  OK"

# ---- rebuild ----
VER=$(basename "$SRC" | sed 's/^broadcom-sta-//')
KVER=$(uname -r)
say "rebuilding dkms for kernel $KVER ..."
dkms install "broadcom-sta/$VER" -k "$KVER" --force 2>&1 | sed 's/^/    /' || \
dkms autoinstall -m broadcom-sta -k "$KVER" 2>&1 | sed 's/^/    /' || true

if [ -f "/lib/modules/$KVER/updates/dkms/wl.ko" ] || \
   [ -f "/lib/modules/$KVER/updates/dkms/wl.ko.xz" ]; then
  say "module present: /lib/modules/$KVER/updates/dkms/wl.ko*  OK"
else
  fail "module not rebuilt at /lib/modules/$KVER/updates/dkms/"
fi

# ---- optional reload ----
if [ "$RELOAD" = 1 ]; then
  if lsmod | grep -q '^wl '; then
    say "reloading wl module ..."
    modprobe -r wl 2>/dev/null || say "  (in use, not reloading)"
    modprobe wl && say "wl reloaded"
  else
    modprobe wl && say "wl loaded"
  fi
  ip link show wlp4s0 >/dev/null 2>&1 && \
    say "wlp4s0 state: $(cat /sys/class/net/wlp4s0/operstate 2>/dev/null || echo '?')"
fi

say "DONE"
