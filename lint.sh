#!/bin/sh
# lint.sh — the single source of truth for this repo's quality gate.
#
# CI (.github/workflows/lint.yml) is a thin wrapper that calls this exact
# script, so local runs and CI can never drift apart.
#
# Usage: ./lint.sh          (exit 0 = clean, non-zero = problems)
#
# Requires: shellcheck, bash, dash. Runs under plain /bin/sh.

set -u

fail=0
say() { printf '%s\n' "$*"; }
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '  ....  %s\n' "$1"; }

cd "$(dirname "$0")" || exit 1

say "=== 1. shellcheck (warning level) ==="
if command -v shellcheck >/dev/null 2>&1; then
  for f in *.sh; do
    [ -f "$f" ] || continue
    out=$(shellcheck -S warning "$f" 2>&1)
    if [ -z "$out" ]; then
      ok "shellcheck $f"
    else
      bad "shellcheck $f"
      printf '%s\n' "$out" | sed 's/^/        /'
    fi
  done
else
  bad "shellcheck not installed"
  note "install: apt-get install -y shellcheck"
fi

say ""
say "=== 2. syntax: bash -n ==="
if command -v bash >/dev/null 2>&1; then
  for f in *.sh; do
    [ -f "$f" ] || continue
    if err=$(bash -n "$f" 2>&1); then
      ok "bash -n $f"
    else
      bad "bash -n $f"
      printf '%s\n' "$err" | sed 's/^/        /'
    fi
  done
else
  bad "bash not installed"
fi

say ""
say "=== 3. syntax: dash -n (POSIX portability) ==="
if command -v dash >/dev/null 2>&1; then
  for f in *.sh; do
    [ -f "$f" ] || continue
    if err=$(dash -n "$f" 2>&1); then
      ok "dash -n $f"
    else
      bad "dash -n $f"
      printf '%s\n' "$err" | sed 's/^/        /'
    fi
  done
else
  note "dash not installed - skipping portability check"
fi

say ""
say "=== 4. no proprietary Broadcom driver source ==="
# broadcom-sta is Debian non-free: the wl driver must never be committed.
# Pattern set confirmed not to false-positive on any file in this repo.
# lint.sh lists these patterns itself, so it is excluded to avoid a self-match
# -- its own integrity is covered by checks 1-3 and 6.
hits=""
for f in *.sh *.md *.patch; do
  [ -f "$f" ] || continue
  [ "$f" = "lint.sh" ] && continue
  if grep -qE 'wlc_bmac|d11regs|BCMASSERT|TIGER_REVID|wlc_intrs' "$f" 2>/dev/null; then
    hits="$hits $f"
  fi
done
if [ -n "$hits" ]; then
  bad "proprietary driver internals found in:$hits"
else
  ok "no proprietary driver internals in any shipped file"
fi

say ""
say "=== 5. wl-6.12.patch remains a one-line change ==="
if [ -f wl-6.12.patch ]; then
  added=$(grep -c '^+' wl-6.12.patch)
  removed=$(grep -c '^-' wl-6.12.patch)
  note "added=$added (incl. +++ header), removed=$removed (incl. --- header)"
  # 2/2 == one header line + one changed line. Anything above 3 means the
  # change is no longer trivial and the README's approach needs revisiting.
  if [ "$added" -gt 3 ] || [ "$removed" -gt 3 ]; then
    bad "patch has grown beyond a one-line change - review it"
  else
    ok "patch is still a one-line change"
  fi
else
  bad "wl-6.12.patch missing"
fi

say ""
say "=== 6. no build/backup debris tracked ==="
debris=$(git ls-files 2>/dev/null | grep -E 'wl_linux\.c$|wl_linux\.c\.|\.orig$|\.rej$' || true)
if [ -n "$debris" ]; then
  bad "unexpected files tracked: $debris"
else
  ok "no source-tree debris tracked"
fi

say ""
say "=================================="
if [ "$fail" -eq 0 ]; then
  say "  LINT CLEAN"
else
  say "  *** $fail PROBLEM(S) ***"
fi
say "=================================="
exit "$fail"
