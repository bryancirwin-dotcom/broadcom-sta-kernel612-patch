#!/bin/bash
# Adversarial test: simulate what an apt upgrade would do, prove the
# checker catches it, prove recovery fixes it.
set -u
SRC=$(ls -d /usr/src/broadcom-sta-* | head -1)
F="$SRC/src/wl/sys/wl_linux.c"
STORE=/usr/local/share/broadcom-sta-patch

echo "=== STEP 1: simulate apt upgrade (restore PRISTINE source = revert patch) ==="
cp -p "$STORE/wl_linux.c.pristine" "$F"
echo "  reverted. line is now: $(grep -m1 'unaligned.h' "$F" | sed 's/^ *//')"
echo "  module still loaded?  $(lsmod | grep -q '^wl ' && echo yes || echo no)  (expected yes - build not yet redone)"

echo ""
echo "=== STEP 2: does the checker CATCH the reversion? ==="
if /usr/local/sbin/check-wl-patch.sh; then
  echo "  *** BUG: checker PASSED on a reverted source ***"
  RC=0
else
  echo "  GOOD: checker exited non-zero (it caught the reversion)"
  RC=1
fi
echo "  checker exit code: $(/usr/local/sbin/check-wl-patch.sh >/dev/null 2>&1; echo $?)  (non-zero = correctly failed)"

echo ""
echo "=== STEP 3: run the recovery script (no reload first) ==="
/usr/local/sbin/fix-broadcom-sta-6.12.sh
REC=$?
echo "  recovery exit code: $REC"

echo ""
echo "=== STEP 4: does the checker now PASS? ==="
if /usr/local/sbin/check-wl-patch.sh; then
  echo "  GOOD: fully restored"
else
  echo "  *** FAIL: still broken after recovery ***"
fi

echo ""
echo "=== STEP 5: full dkms rebuild + module reload (the real end-to-end) ==="
/usr/local/sbin/fix-broadcom-sta-6.12.sh --reload
echo "  exit: $?"

echo ""
echo "=== FINAL STATE ==="
echo "  line    : $(grep -m1 'unaligned.h' "$F" | sed 's/^ *//')"
echo "  wl.ko   : $(ls -la /lib/modules/$(uname -r)/updates/dkms/wl.ko.xz 2>/dev/null | awk '{print $5" bytes, "$6" "$7" "$8}' || echo MISSING)"
echo "  loaded  : $(lsmod | grep -q '^wl ' && echo yes || echo NO)"
echo "  wlp4s0  : $(cat /sys/class/net/wlp4s0/operstate 2>/dev/null || echo absent)"
echo "  check   : $(/usr/local/sbin/check-wl-patch.sh >/dev/null 2>&1 && echo PASS || echo FAIL)"
