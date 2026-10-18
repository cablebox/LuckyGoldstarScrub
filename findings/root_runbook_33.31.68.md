# Rooting runbook: OLED C3 on firmware 33.31.68 (webOS 10.3.1-3006, o22n/papikonda)

Ground truth as of 2026-10-18. Target: the user's own C3, reported on webOS 10.3.1-3006.
That release string maps to EPK `lib32-starfish-global-secured-o22n-papikonda-3006-33.31.68_prodkey_usb_V3_SECURED.epk`
(LG support page, fileId `6V7BLtysFHisS9136o14hw`, released 2026-06-29; downloaded to `fw/c3_33.31.68.zip`).

## Why this firmware is rootable

CanI.RootMy.TV data for OTAID `HE_DTV_W23O_AFABATAA` (US C3), variant `ponytail` (swMajor 33):

| Exploit | Latest vulnerable | Patched |
|---|---|---|
| dangbro | 33.31.68 (10.3.1-3006) | — (none recorded) |
| slopbro  | 33.31.68 (10.3.1-3006) | — (none recorded) |
| faultmanager | 23.20.61 (webOS 9) | 23.20.64 |

Everything older (crashd, WTA, asm, dejavuln) was patched in 2024-era builds. Note the
43.x/"queue" line (webOS 11, e.g. 43.21.84 released 2026-10-13) has **no** recorded exploit —
if the TV ever updates to it, this runbook dies. Do not update.

## Chosen chain: SlopBro (jsserver)

`throwaway96/slopbro` (cloned at `fw/tools/slopbro`, AGPL). Works webOS 4–11, includes a
bypass for LG's service-launch patch. No dev mode, no network credentials beyond SSAP pairing.

Flow: local HTTP server → SSAP launch of a stock WAM app with injected launch param
(webOS 10 targets: `com.webos.app.adoverlay`/`acroverlay`/`tinybrowser`/`dangbei-overlay`) →
privileged page fetches fake `com.webos.service.jsserver` package → `main.js` runs as root →
`autoroot.sh` installs Homebrew Channel.

Payload audit (`wwwroot/autoroot.sh` + `main.js`, done 2026-10-18): installs official
`org.webosbrew.hbchannel_0.7.3_all.ipk` from the pinned GitHub release; elevation + defensive
`start-devmode.sh` signature handling; `main.js` only execs `/bin/sh <script>` as root. No
dev-mode app dependency. Acceptable to run.

## Execution sequence

Preconditions: TV on this LAN (SSAP 3000 reachable), user near TV to accept the pairing prompt.

```sh
cd fw/tools/slopbro
python3 slopbro.py --webos-version 10.3 --debug <TV_IP>
```

- Accept the SSAP pairing prompt on the TV (writes `<TV_IP>.key`).
- Watch for "Payload complete" / "Rooting complete" toast; exploit intentionally segfaults
  once — that is expected.
- If the payload page stalls: retry, or try `--no-fake-service-path` (older patch state), or
  pick a different target app by editing TARGET_APPS order.

## Verification gates (must all pass before declaring root)

1. `ssh root@<TV_IP>` (hbchannel's dropbear) → `id` returns `uid=0(root)`.
2. Homebrew Channel icon present on launcher; app opens; "root status: ok".
3. Reboot (`luna-send -n 1 luna://com.webos.service.sleep/shutdown/machineReboot
   '{"reason":"remoteKey"}'`) → gates 1–2 still hold.
4. Block OTA auto-update before reconnecting the TV to the internet full-time:
   Homebrew Channel → "Block software updates" (or mask `swu`/`softwareupdate` paths).

## Post-root install set (IPKs already staged in `fw/ipks/`)

1. `org.webosbrew.piccap_0.5.3_all.ipk` — screen capture front end (hyperion-webos).
2. `org.webosbrew.hyperion.ng.loader_0.1.11_all.ipk` — Hyperion.NG on-TV.
3. Configure Hyperion: Philips Hue LED device, Entertainment mode, pair with bridge
   192.168.1.111 (link button), lay out entertainment-area lights.
4. Official `com.lighting.huesync` app: only if the user produces a vendor-provided package
   or a copy from their own licensed 2024+ set (see `huesync_c3_backport.md` §3; no
   payment circumvention).

## Debloat

Port `scripts/50scrub` (CX/webOS 5) to webOS 10.3 against the extracted 33.31.68 rootfs:
verify each systemd unit/service file exists on this build, add `service-logger.service`,
re-check `sportsalarm` luna-service path, re-check log-context names. Install to
`/var/lib/webosbrew/init.d/50scrub`. Bloat-app removal list to be confirmed with the user
(candidates from `factsheets/c3/apps.txt`: adoverlay*, adhdmi1-4, videoads, aipromotion,
newandhot, fooddelivery*, nais*, sportsalarm/sportsteamsettings, store-demo/sync-demo,
lifeonscreen, mediadiscovery, amazon.alexa*, totalmusic, gamehome, kidshome, tvuserguide...).

## Live-LAN state at time of writing

No webOS SSAP listener on 192.168.1.0/24 (both TVs off/unreachable). 192.168.1.111 is the
Hue Bridge (SSDP UUID OUI 00:17:88); 192.168.1.152 is an unrelated LAN appliance; .1 router.

## Offline verification (done 2026-10-18, extracted 33.31.68 rootfs at `fw/ext3368/rootfs`)

Every SlopBro prerequisite confirmed in the exact firmware image, not inferred:

| Check | Result |
|---|---|
| `com.webos.app.adoverlay` | present; `index.html` parses `interactiveUrl` launch param (2 refs) |
| `com.webos.app.acroverlay` / `tinybrowser` / `dangbei-overlay` | present |
| Fake service path `/usr/palm/services/com.palm.service.devmode` | present (`devmode_service.js`, `pub.pem`, `services.json`) |
| jsserver service registration | `usr/share/luna-service2/services.d/com.webos.service.jsserver.service` |

Scrub port written: `scripts/50scrub-webos10` — on webOS 10.3 the telemetry units moved to
`etc/systemd/system/` (all 8 verified: user-context-manager, nudge, rdxd, uploadd, iot-client,
webos-sddp, dmost, service-logger), sportsalarm/livepick-plus are on-demand luna services.

Rootfs extraction notes for reproducibility: `unsquashfs -f` is required (duplicate inodes
abort otherwise); native build decrypts the EPK in ~20s (`fw/tools/epk2extract/build-macos`).
Store-architecture investigation (catalog/entitlement/download/install enforcement) running
as a separate scout; results will land in `findings/`.

## SlopBro reach beyond the C3 (from the CanI.RootMy.TV bundle, 2026-10-18)

Parsed all 2020/2021 OTAIDs from the CanI app bundle: `slopbro` has **no patch recorded** on
every one of them, up to and including each line's latest firmware — 2021 models
(kisscurl, webOS 6.5.3-47 = `03.53.45`) and 2020 models (jhericurl, webOS 5.6.2-21 =
`04.64.00`, the CX). faultmanager is patched from `03.52.x`/`04.60.x`; the older chains are
dead. So whichever LG set appears on the LAN, the rooting command is the same SlopBro flow
with `--webos-version 6` (2021) or `--webos-version 5` (2020 CX).

## Why the kernel cannot run in QEMU (checked 2026-10-18)

Extracted the embedded config (`fw/kconfig_3368`, IKCFG from `kernel.pak.unlz4`,
"Linux/arm64 5.4.268-329.ptl4tv.5"): `CONFIG_PCI` unset, `CONFIG_VIRTIO_MMIO` unset,
`CONFIG_BLK_DEV_INITRD` unset (no initramfs at all), no `RD_*` decompressors. Storage is
LX-eMMC-only; the kernel supports PL011 console, GICv3, xHCI/USB-storage, squashfs-zstd,
overlayfs — but with no PCI and no virtio there is no QEMU device that can present a root
filesystem, and without initramfs there is no ramdisk path. QEMU `virt` boot is therefore
kernel-entry-only (no userspace), which has no validation value here. VM-based exercising of
the firmware is closed; offline validation stays static (as done above), and live validation
runs on the TV.

## CVE utilization track (opened 2026-10-18)

Pinned versions (opkg status + binary strings, `fw/ext3368/rootfs`): WAM Chromium
120.0.6099.270, Node 16.20.2, FFmpeg 5.0.1, GStreamer 1.24.0, OpenSSL 3.0.13, curl 7.82.0,
connman 1.35 (LG-patched), DIAL service 1.0.0-137, systemd 250.5, glibc 2.35, sqlite 3.38.5,
expat 2.4.30, lighttpd 1.4.67. Lead hypothesis: post-Chrome-120 renderer n-day fired via the
launch-param injection primitive (verified in this rootfs) into trusted WAM contexts. Two
scouts (CveChromium, CveNetwork) sweeping primary sources; results land in
`findings/cve_candidates_33.31.68.md`.
