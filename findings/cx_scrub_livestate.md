# CX (OLED CX, webOS 5, fw 04.63.20) root + scrub: post-reset rebuild state

Ground truth 2026-10-22 ~13:47 after factory reset + full re-root. TV at 192.168.1.175.

## Incident summary (pre-reset, for the record)

A mistaken `rm -rf /mnt/lg/appstore/*` (aimed at NSU staging, actually the shared
eMMC partition holding cryptofs/devmode-app/internal storage) cascaded: store installs
broken, webosbrew boot chain dead, launcher degraded. Factory reset was the correct
exit; everything was then re-rooted and re-applied scripted in ~30 min.

## Current boot chain (all live-verified across reboots)

1. webosbrew devmode chain (autoroot-patched start-devmode.sh) -> /var/lib/webosbrew/startup.sh
2. `/home/root/memchute_debug.sh` - memchute-ready.service ExecStartPost, runs EARLY:
   iptables REJECT 156.147.69.32 (the NSU hardcoded IP - THE modal killer), clears
   webosbrew_failsafe flag, dropbear guard. Its /etc/hosts append no-ops (rootfs RO at
   that stage - 50scrub's later append covers it).
3. `/var/lib/webosbrew/init.d/50scrub` (+105s): runtime masks, service-file blanks,
   pkills, eulaStatus withdrawal, acr.xml null, hosts append (incl nsu.lge.com),
   wake-unit trim, preload de-voice, iptables belt.
4. `/var/lib/webosbrew/init.d/60debloat` (+170s): 43 apps hidden, launcher-only restart.

## Verified outcomes

- **Firmware-update modal: ELIMINATED** (user-confirmed no-modal boot). Mechanism per
  fw/cx_04.63.25 disassembly (local://epk_analysis.md): fresh checks + resume-state both
  required reachable endpoints; iptables on the hardcoded IP + nsu hosts + reset-cleared
  state close all paths.
- Daemons: acr2/adstack/telemetry/voice/update/membership/tvdataexchanger all dead at
  boot; 43 bloat apps hidden; wake burst trimmed.
- Boot: 25.6-25.8s total (stock config 29.1s). Remaining: snapshot CRIU restore 10.9s +
  fullhome 8.8s = firmware-inherent (needs RO /etc/systemd drop-in; no runtime hook runs
  before snapshot-boot-components).
- Failsafe trips after forced `/sbin/reboot` = unclean-shutdown detection, not crashes;
  use `luna-send .../machineReboot` (clean) instead.

## Recovery runbook (if ever needed again)

- Re-root: `python3 slopbro.py --debug <ip>` (stock wwwroot; pairing prompt on TV).
- SSH: root/alpine, then install key + memchute hook FIRST, then init.d scripts.
- Exploit payload delivery requires /media/internal/downloads to exist (default in
  index.html; alternative dirs fail: /tmp noexec, others rejected by the service runner).

## Basic Home (2026-10-22 ~14:00)

Home Style -> Basic via the MENU (Settings > General > Home Settings > Home Style).
setSystemSettings cannot write nested/dotted keys on this build (both shapes silently
no-op) - use the menu or edit /var/luna/preferences/general + md5sum regen.
Effect: com.webos.app.home replaces fullhome as sole launcher, fullhome removed from
preload allow-list, boot 24.7s, launcher working set ~3MB class.
