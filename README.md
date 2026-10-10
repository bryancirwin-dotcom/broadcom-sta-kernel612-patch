# broadcom-sta-kernel612-patch

[![lint](https://github.com/bryancirwin-dotcom/broadcom-sta-kernel612-patch/actions/workflows/lint.yml/badge.svg)](https://github.com/bryancirwin-dotcom/broadcom-sta-kernel612-patch/actions/workflows/lint.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

A one-line source fix that lets Debian's `broadcom-sta-dkms` (the proprietary
**`wl`** driver) compile against **Linux 6.12** — plus scripts that apply it,
verify it, and stop `apt` from silently reverting it.

Without this fix the DKMS build fails and the machine falls back to the
in-kernel `b43` driver, which is **2.4 GHz only** on this PHY. The patch is
what puts 5 GHz back.

---

## The bug

`broadcom-sta-dkms` ships source containing:

```c
/* src/wl/sys/wl_linux.c, line 59 */
#include <asm/unaligned.h>
```

On modern kernels that header no longer exists. Verified against the installed
Debian kernel headers:

```
$ find /usr/src/linux-headers-* -name unaligned.h -path '*/asm/*' | wc -l
0
```

Zero copies across *every* installed header tree
(`6.12.12+bpo`, `6.12.12+bpo-common`, `6.12.95+deb12-amd64`,
`6.12.95+deb12-common`). The include cannot resolve, so the DKMS build dies
and `wl.ko` never gets produced.

The replacement **does** exist:

```
/usr/src/linux-headers-6.12.95+deb12-common/include/linux/unaligned.h
```

## The fix

```diff
--- src/wl/sys/wl_linux.c.orig-6.12-compat
+++ src/wl/sys/wl_linux.c
@@ -56,7 +56,7 @@
 #include <asm/irq.h>
 #include <asm/pgtable.h>
 #include <asm/uaccess.h>
-#include <asm/unaligned.h>
+#include <linux/unaligned.h>
 
 #include <proto/802.1d.h>
```

Full patch: [`wl-6.12.patch`](./wl-6.12.patch).

---

## Verified results

Built and tested end to end — the source was reverted to pristine, the checker
was proven to catch it, then recovery rebuilt and reloaded the module:

```
total BSS blocks : 40
  2.4 GHz         : 17
  5  GHz          : 23        <-- the whole point
5 GHz frequencies : 5220 5240 5300 5500 5660 5765 5785 5805

04:00.0 Network controller: BCM4331 802.11a/b/g/n [14e4:4331] (rev 02)
        Subsystem: Apple Inc. AirPort Extreme
        Kernel driver in use: wl
```

23 BSSIDs across eight channels from 5220 → 5805 MHz. `b43` cannot do this on
this hardware.

---

## Install

```sh
sudo bash protect-wl-patch.sh
```

This applies the patch and sets up **defence in depth**, because the real risk
isn't making it work once — it's an `apt upgrade` silently reverting it:

| # | Mechanism | Protects against |
|---|---|---|
| 1 | Copy patch + pristine source to `/usr/local/share/broadcom-sta-patch/` | package upgrade deleting the only backup |
| 2 | `apt-mark hold broadcom-sta-dkms` | `apt upgrade` |
| 3 | `/etc/apt/preferences.d/broadcom-sta-dkms` pin (priority 1001) | tools that ignore holds / `--only-upgrade` |
| 4 | `/usr/local/sbin/fix-broadcom-sta-6.12.sh` | rebuilding after any revert |
| 5 | `/usr/local/sbin/check-wl-patch.sh` | silent drift — wired into the host's health gate |

Items 1–3 matter because the pristine backup that ships beside the source
(`wl_linux.c.orig-6.12-compat`) lives **inside** `/usr/src/broadcom-sta-*` —
exactly the directory an upgrade overwrites.

## Verify

```sh
sudo /usr/local/sbin/check-wl-patch.sh
```

```
  PASS  source tree present
  PASS  patch applied (linux/unaligned.h)
  PASS  old include absent (asm/unaligned.h)
  PASS  apt-mark hold set
  PASS  apt preferences pin present
  PASS  recovery script exists
  PASS  patch stored outside pkg tree
  PASS  pristine source stored outside pkg tree
  PASS  dkms module installed
  PASS  wl module loaded
  ---- 10 ok, 0 bad ----
```

Exits non-zero if anything is wrong, so it can gate a health check.

## Recover

If the source ever reverts (upgrade, `apt-get install --reinstall`, hand edits):

```sh
sudo /usr/local/sbin/fix-broadcom-sta-6.12.sh          # patch + dkms rebuild
sudo /usr/local/sbin/fix-broadcom-sta-6.12.sh --reload  # ...then unload/reload wl
```

Idempotent and **version-agnostic** — it globs `/usr/src/broadcom-sta-*`
rather than hardcoding a version, refuses to double-patch (it restores from the
pristine copy first), and verifies before and after.

## Test the safety net

```sh
sudo bash test-wl-recovery.sh
```

Adversarial: restores the pristine source to simulate an upgrade, asserts the
checker **fails**, runs recovery, asserts it passes again, then does a full
`dkms` rebuild and module reload. Safe to run — it always ends restored.

---

## Files

| File | Purpose |
|---|---|
| `wl-6.12.patch` | the one-line unified diff |
| `protect-wl-patch.sh` | installer — applies patch + all five protections |
| `fix-broadcom-sta-6.12.sh` | recovery / rebuild (also written by the installer) |
| `check-wl-patch.sh` | read-only 10-point checker (also written by the installer) |
| `test-wl-recovery.sh` | adversarial end-to-end test of the above |
| `broadcom-sta-dkms.pin` | the apt preferences file, verbatim |

`fix-broadcom-sta-6.12.sh` and `check-wl-patch.sh` are *generated* by
`protect-wl-patch.sh`; the copies here are the deployed versions, byte-identical
by MD5. They're included so the code can be reviewed before running it as root.

---

## Why there is no Broadcom source in this repo

`broadcom-sta-dkms` is Debian **`non-free/kernel`** — the `wl` driver is
proprietary Broadcom code. This repo therefore contains only:

- a 322-byte unified diff showing one `#include` line changing, and
- shell scripts of my own writing.

The pristine `wl_linux.c` is deliberately **not** published. Apply the patch
against your own copy obtained from the package.

---

## Tested on

| | |
|---|---|
| Package | `broadcom-sta-dkms 6.30.223.271-23` (`non-free/kernel`) |
| Kernel | `6.12.95+deb12-amd64` — Debian 12 (bookworm) |
| Hardware | BCM4331 `[14e4:4331]`, subsystem *Apple AirPort Extreme* |
| Machine | iMac13,1 21.5" Late 2012 (Z77) |

**Caveat:** Debian splits kernel headers. `linux/unaligned.h` lives in the
`-common` package (`linux-headers-<ver>-common`), not the arch one. If
`linux-headers-<ver>-common` isn't installed, no `linux/unaligned.h` exists and
this patch cannot help — install it first.

**Recovery if it ever breaks anyway:** the in-kernel `b43` driver still works,
but 2.4 GHz only. Remove `/etc/modprobe.d/blacklist-b43.conf` and unload `wl`
to fall back.

---

## License

[MIT](./LICENSE). The shell scripts and documentation here are original work.

`wl-6.12.patch` is a trivially-derived one-line diff against Broadcom's
non-free source; that source stays under Broadcom's own terms and is **not**
included in this repository.

## Contributing

Scripts in this repo are run as **root** and can unload a wireless driver, so
they are held to a slightly higher bar than usual. Run the gate before pushing:

```sh
./lint.sh        # exit 0 = clean
```

CI runs that **same script** on every push to `main` and on every pull request,
so a local pass and a CI pass can never disagree.

It checks, and every item below is enforced rather than left to convention:

- `shellcheck -S warning` is clean across all scripts
- `bash -n` and `dash -n` both pass — keeping them POSIX-parseable
- **`wl-6.12.patch` stays a one-line change.** If it grows past a trivial diff,
  that is a signal the approach has changed and this README needs to say so —
  more than an include swap means the kernel interface moved in a way worth
  documenting, not papering over
- **no proprietary Broadcom driver source.** `lint.sh` greps shipped files for
  driver internals, and `.gitignore` blocks the filenames as a second line of
  defence
- no source-tree debris (`wl_linux.c`, `*.orig`) tracked by git

New checks belong in `lint.sh` (repo-wide) or `check-wl-patch.sh` (machine
state — the host's health gate calls that one).

`test-wl-recovery.sh` reverts the source on purpose to prove the safety net
works — run it only where breaking WiFi for ~a minute is acceptable.
