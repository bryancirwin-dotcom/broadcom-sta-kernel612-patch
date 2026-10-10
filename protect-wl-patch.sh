#!/bin/bash
# =============================================================================
# protect-wl-patch.sh — protect the local kernel-6.12 compat patch for
#                       broadcom-sta-dkms (BCM4331 -> 5 GHz via proprietary wl)
#
# The patch is a ONE-LINE source edit:
#     #include <asm/unaligned.h>   ->   #include <linux/unaligned.h>
# (kernel 6.2 removed asm/unaligned.h; without this, the dkms build fails and
#  the machine falls back to b43, which is 2.4 GHz-only on this PHY.)
#
# Threat: an apt upgrade of broadcom-sta-dkms replaces /usr/src/broadcom-sta-*
#         with pristine upstream sources -> patch silently reverted -> next
#         kernel/dkms rebuild fails -> 5 GHz gone.
#
# Defence in depth applied here:
#   1. copy patch + pristine original OUTSIDE the package tree
#   2. apt-mark hold                      (blocks `apt upgrade`)
#   3. apt preferences pin at exact ver   (blocks tools that ignore holds)
#   4. recovery script (idempotent, version-agnostic)
#   5. read-only check script for the standing gate
#   6. marker file so the gate can assert "protection is in place"
#
# Idempotent: safe to run repeatedly.
# =============================================================================
set -eu

SRCROOT=/usr/src
STORE=/usr/local/share/broadcom-sta-patch
RECOVERY=/usr/local/sbin/fix-broadcom-sta-6.12.sh
CHECKER=/usr/local/sbin/check-wl-patch.sh
PINFILE=/etc/apt/preferences.d/broadcom-sta-dkms
PKG=broadcom-sta-dkms

say() { printf '  %s\n' "$*"; }
echo "=== protecting the broadcom-sta 6.12 compat patch ==="

# ---- locate the source tree (version-agnostic) -----------------------------
SRC=$(ls -d "$SRCROOT"/broadcom-sta-* 2>/dev/null | head -1 || true)
if [ -z "$SRC" ]; then
  echo "FATAL: no /usr/src/broadcom-sta-* tree found" >&2
  exit 1
fi
F="$SRC/src/wl/sys/wl_linux.c"
[ -f "$F" ] || { echo "FATAL: $F missing" >&2; exit 1; }
say "source tree : $SRC"

VER=$(basename "$SRC" | sed 's/^broadcom-sta-//')
say "version     : $VER"

# ---- 1. store patch assets OUTSIDE the package tree ------------------------
mkdir -p "$STORE"
chmod 755 "$STORE"

ORIG="$F.orig-6.12-compat"
if [ -f "$ORIG" ]; then
  cp -p "$ORIG" "$STORE/wl_linux.c.pristine"
  say "pristine copy -> $STORE/wl_linux.c.pristine"
else
  say "NOTE: no .orig backup beside the source (tree may already be pristine)"
fi

# generate a proper unified diff for the record (relative paths => portable)
if [ -f "$ORIG" ]; then
  ( cd "$SRC" && diff -u "src/wl/sys/wl_linux.c.orig-6.12-compat" \
                     "src/wl/sys/wl_linux.c" > "$STORE/wl-6.12.patch" || true )
  say "unified diff -> $STORE/wl-6.12.patch ($(wc -c < "$STORE/wl-6.12.patch") bytes)"
fi

# ---- 2. recovery script ----------------------------------------------------
cat > "$RECOVERY" <<'RECOVERY_EOF'
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
RECOVERY_EOF
chmod 755 "$RECOVERY"
say "recovery  -> $RECOVERY"

# ---- 3. read-only checker for the gate ------------------------------------
cat > "$CHECKER" <<'CHECKER_EOF'
#!/bin/bash
# Read-only assertion that the broadcom-sta 6.12 patch + its protection are
# intact. Prints PASS/FAIL per item; exits non-zero if anything is wrong.
# No root needed for the source/hold checks.
ok=0 bad=0
r() { if [ "$2" = 1 ]; then printf '  PASS  %s\n' "$1"; ok=$((ok+1)); else printf '  FAIL  %s\n' "$1"; bad=$((bad+1)); fi; }

SRC=$(ls -d /usr/src/broadcom-sta-* 2>/dev/null | head -1 || true)
if [ -z "$SRC" ]; then
  r "source tree present" 0
else
  r "source tree present" 1
  F="$SRC/src/wl/sys/wl_linux.c"
  [ -f "$F" ] || F=""
  if [ -z "$F" ]; then
    r "wl_linux.c present" 0
  else
    if grep -qF '#include <linux/unaligned.h>' "$F"; then
      r "patch applied (linux/unaligned.h)" 1
    else
      r "patch applied (linux/unaligned.h)" 0
    fi
    if grep -qF '#include <asm/unaligned.h>' "$F"; then
      r "old include absent (asm/unaligned.h)" 0
    else
      r "old include absent (asm/unaligned.h)" 1
    fi
  fi
fi

# package hold (apt-mark)
if apt-mark showhold 2>/dev/null | grep -qx "$PKG_NAME"; then r "apt-mark hold set" 1; else r "apt-mark hold set" 0; fi
# preferences pin
if grep -q '^Package: broadcom-sta-dkms' /etc/apt/preferences.d/broadcom-sta-dkms 2>/dev/null; then
  r "apt preferences pin present" 1
else r "apt preferences pin present" 0; fi
# recovery assets
[ -x /usr/local/sbin/fix-broadcom-sta-6.12.sh ] && r "recovery script exists" 1 || r "recovery script exists" 0
[ -f /usr/local/share/broadcom-sta-patch/wl-6.12.patch ] && r "patch stored outside pkg tree" 1 || r "patch stored outside pkg tree" 0
[ -f /usr/local/share/broadcom-sta-patch/wl_linux.c.pristine ] && r "pristine source stored outside pkg tree" 1 || r "pristine source stored outside pkg tree" 0
# dkms registration
dkms status 2>/dev/null | grep -q 'broadcom-sta.*installed' && r "dkms module installed" 1 || r "dkms module installed" 0
# running module
lsmod | grep -q '^wl ' && r "wl module loaded" 1 || r "wl module loaded" 0

printf '  ---- %d ok, %d bad ----\n' "$ok" "$bad"
[ "$bad" -eq 0 ]
CHECKER_EOF
# fix the package-name variable the heredoc references
sed -i 's/\$PKG_NAME/broadcom-sta-dkms/' "$CHECKER"
chmod 755 "$CHECKER"
say "checker   -> $CHECKER"

# ---- 4. apt-mark hold ------------------------------------------------------
PKGS_VER=$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null || echo unknown)
apt-mark hold "$PKG" >/dev/null
say "apt-mark hold: $(apt-mark showhold | tr '\n' ' ')"

# ---- 5. apt preferences pin (blocks tools that ignore holds) ---------------
cat > "$PINFILE" <<PIN_EOF
# ---------------------------------------------------------------------------
# Protects the local kernel-6.12 compat patch for the BCM4331 WiFi driver.
#
# broadcom-sta-dkms ships a source tree in /usr/src that does NOT compile on
# kernel >= 6.2 (it includes <asm/unaligned.h>, removed upstream). The local
# fix is a one-line change to <linux/unaligned.h>. An apt upgrade would replace
# that source with pristine upstream and silently revert the fix, breaking the
# dkms build and dropping this machine to b43 (2.4 GHz only).
#
# Pinning to the exact installed version prevents any upgrade.
# Recovery if it ever does revert:
#     sudo /usr/local/sbin/fix-broadcom-sta-6.12.sh --reload
# Verify any time:
#     sudo /usr/local/sbin/check-wl-patch.sh
# ---------------------------------------------------------------------------
Package: $PKG
Pin: version $PKGS_VER
Pin-Priority: 1001
PIN_EOF
chmod 644 "$PINFILE"
say "pin       -> $PINFILE (version $PKGS_VER, priority 1001)"

# ---- 6. store marker + make assets read-only ------------------------------
touch "$STORE/PROTECTED"
chmod 444 "$STORE"/*.patch "$STORE"/*.pristine "$STORE/PROTECTED" 2>/dev/null || true

echo ""
echo "=== verification ==="
"$CHECKER" || true

echo ""
echo "=== apt simulation: would an upgrade touch it? ==="
if apt-get install --dry-run --only-upgrade "$PKG" 2>&1 | grep -qE "^(Inst|Conf) $PKG"; then
  say "WARNING: apt still wants to upgrade it"
else
  say "apt will NOT upgrade $PKG  (held + pinned)"
fi
echo "=== DONE ==="
