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
if apt-mark showhold 2>/dev/null | grep -qx "broadcom-sta-dkms"; then r "apt-mark hold set" 1; else r "apt-mark hold set" 0; fi
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
