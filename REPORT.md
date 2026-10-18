# LG OLED55CXPUA firmware 04.64.00: performance and privacy audit

**Target:** LG OLED55CXPUA (CX, 2020), firmware `04.64.00.01-HE_DTV_W20O_AFABATAA`, webOS TV 5.6.2, o20 SoC, US/ATSC.
Image built April 2026 and downloaded from LG's support site.

**Method:** static analysis only. The EPK3 was decrypted with the public o20 key from
[epk2extract](https://github.com/openlgtv/epk2extract); `scripts/extract.sh` reproduces it. All 15 partition images
decrypted, about 60k files in total; the rootfs alone is 2.2 GB and about 56k files. Configs, systemd units,
QML/JS apps and binary strings were then read. **Nothing was run on a TV.** Each claim in `findings/` is tagged
as observed in a file or inferred, and the main inferences are flagged below. All paths are relative to the
extracted rootfs.

| File | Contents |
|---|---|
| `REPORT.md` | This summary: what to change, what is slow, how the TV phones home |
| `findings/performance.md` | Boot, memory, preload, logging, scheduling and I/O analysis with 17 ranked changes |
| `findings/ui_apps.md` | Home launcher, Live TV/HDMI shell and Settings: per-launch network traffic and timers |
| `findings/acr.md` | Automatic Content Recognition (Alphonso) and the ad and overlay pipeline |
| `findings/telemetry.md` | sdx cloud broker, crash and analytics uploads, viewing logs, ads, voice, LAN exposure |
| `findings/endpoints.md` / `endpoints_raw.tsv` | Every server the firmware can contact, sorted by purpose |
| `findings/versions.md` | Component versions, CA bundle, debug leftovers |
| `blocklist.txt` | Hosts-format DNS blocklist: a "safe" section and an "optional" section |
| `scripts/50scrub` | Boot script for a rooted TV that applies the changes below |
| `scripts/extract.sh` | Reproduces the download, decryption and extraction |

---

## 1. Concrete changes

### Tier 1: TV menu only, no root (do these first)

The defaults are from `etc/palm/defaultSettings.json`. Menu labels are from the webOS 5 menu and may differ
slightly.

| # | Change | Setting key (default) | Effect |
|---|---|---|---|
| 1 | **Home Settings → Home Style → Basic Home** | `general.defaultApps.home` (`com.webos.app.fullhome`) | Replaces the 76 MB QML "New Home" with the 3 MB launcher bar. Every time it opens, New Home makes about 6 server calls, requests 4–6 ad slots and can play a hero video ad. Basic Home makes one ad request. **This is likely the biggest change you will notice** (the speed gain is inferred). |
| 2 | **Home Promotion → Off** | `general.homePromotion` (on) | Removes all home ad slots, the video ad and the impression trackers. |
| 3 | **Home Auto Launch → Off**, set in the menu | `general.homeAutoLaunch` (on) | Stops Home from rendering at every power-on. Setting it in the menu marks the value as user-chosen, so LG's server can no longer turn it back on. |
| 4 | **Additional Settings → Live Plus → Off** | `option.livePlus` | Stops the ACR daemon from fingerprinting what you watch, along with the ad and shopping overlays drawn over TV and HDMI. |
| 5 | **User Agreements:** withdraw **Viewing Information**, **Interest-Based Advertising** and **Voice Information** (keep voice if you use it) | `eulaStatus.acrOnAllowed`, `additionalDataAllowed`, `customAdAllowed`, `voiceAllowed` | These are the real off switches for ACR, the viewing-history upload and personalized ads (§3). |
| 6 | **Limit Ad Tracking On**, **Do Not Sell My Personal Information On**, Ad Cookie Off, reset the Ad ID | `general.lmt` (off), `doNotSellMyPersonalInformation` (off), `adCookie` (on) | These are sent as flags alongside the ad ID. They do not stop collection. |
| 7 | **AI Service → AI Recommendation Off**; Sports Alert Off; Screen Saver Promotion Off; Live Promotion Off | `general.aiNudge` (on), `sportsAlarm`, `general.screenSaverAd` (on), `option.livePromotion` (on) | Fewer background services and pop-ups. |
| 8 | **Cold reboot about weekly** if Quick Start+ is on (unplug for 1 minute) | `option.quickStartMode` | Quick Start+ resumes a saved memory image, so memory fragmentation, zram contents and leaks build up across weeks of "off". |
| 9 | Turn off **Mobile TV On / LG Connect Apps / AirPlay** if unused | `allowMobileDeviceAccess` (true) | Closes LAN port 3001 and the open DIAL app-launch ports (§3.6). |
| 10 | **Router DNS:** load the "safe" section of `blocklist.txt` | — | Blocks Alphonso ACR, LG ad, crash/analytics, viewing-log and remote-diagnostic hosts. **Don't block `*.lgtvsdp.com` or `snu.lge.com`**: that breaks the app store and security updates. Use `0.0.0.0` answers, not NXDOMAIN. If Home gets slower after blocking, unblock `recommend`/`nudge.lgtvcommon.com`; Home waits up to 3 s for its shelves. |

### Tier 2: rooted TV (e.g. webosbrew / Homebrew Channel)

Install `scripts/50scrub` as `/var/lib/webosbrew/init.d/50scrub` (chmod 755). The name must not contain a
dot. The rootfs is read-only squashfs and the image runs **systemd** (`/sbin/init → systemd`; the
`etc/init/*.conf` upstart files are leftovers that are never read). Every change is applied at runtime on each
boot, so deleting the script and rebooting reverts it.

| # | Change | Mechanism | Benefit / risk |
|---|---|---|---|
| R1 | Preload at most 2 apps (stock limit is 6 on 4K panels) | `luna-send … config/setConfigs {"com.webos.service.preloadmanager.maxPreloadApp":2}` | **Biggest RAM saving:** frees roughly 150–400 MB that Netflix, YouTube, Prime, the browser and others hold, and stops the cycle of killing and re-preloading them. The trade-off is that cold launches take 2–8 s. |
| R2 | Lower debug-level log contexts to warning | `PmLogCtl set <ctx> warning` (about 70 contexts ship at debug, including the bus and remote input) | `/var/log` is ramfs, so logs are never swapped and have no size cap. Low risk. |
| R3 | Stop the viewing-history, crash-upload, ThinQ, sports and Control4 daemons | `systemctl stop` + `systemctl mask --runtime` | Fewer resident processes and less upload traffic. Each one removes its feature. |
| R4 | Kill the ACR, ad-overlay and shopping-overlay daemons for this boot | `pkill acr2 adoverlay-service livepick-plus admanager` | Belt-and-braces on top of Tier 1 #4–5. |
| R5 | zram tuning | `vm.page-cluster` 3→0, `min_free_kbytes` 8192→16384 | Lower latency when swapped pages are read back, and fewer reclaim stalls during UI bursts. Measure before and after. |
| R6 | Bluetooth daemon nice -20 → 0 | `renice` | Bluetooth can no longer preempt the UI. Possible BT audio dropouts. |
| R7 | eMMC CFQ `slice_idle=0`; emmcd logging off | `/sys/block/mmcblk0/queue/iosched/slice_idle`, `/home/root/emmcd_config.json` | Less I/O idling behind db8 `sync=1` writes. Not in the script; measure first. |

**Do not** disable `memchute`: release builds set `panic_on_oom=1`, so an out-of-memory event reboots the TV.
Also leave `sam`, `configd`, `surface-manager`, `WebAppMgr`, `db8*`, `settings-service`,
`second-screen-gateway` and `tvservicemock` alone. `tvservicemock` provides
`com.webos.service.tv.systemproperty` despite its name. Removing the shipped example and test apps gains
nothing, because none of them is ever started.

---

## 2. What makes it slow (ranked)

1. **Memory pressure from preloading and keep-alive apps.** `maxPreloadApp: 6` (`etc/configd/layers/distro/hd2160-normal/com.webos.service.preloadmanager.json`) with "periodic" re-preload. Three keep-alive Chromium web apps run all the time (AirPlay, Google Assistant, Alexa). With `swappiness=100` and `page-cluster=3`, this means constant zram churn and memchute kills, felt as lag whenever the foreground app needs memory.
2. **The default Home launcher is heavy and network-bound.** `fullhome` is a 76 MB, interpreted Qt 5 QML app (70.9 MB of PNGs). Each time it opens: a shelf-config fetch (3 s timeout), a recommendation POST, an AI-board/weather fetch, 4–6 ad slots with 1 s × 9 retry timers, a ThinQ check that refreshes every 20 s, and a *synchronous* XHR for the "Home Effect" (luna-only key `homeEffect`, default on). Its image cache sits in `/tmp` and is wiped at power-off.
3. **ACR, ads and overlays while watching TV or HDMI.** `acr2` captures and fingerprints audio and has a video-capture thread. `admanager`, `adoverlay-service` and `livepick-plus` run alongside it, and up to 30 hidden overlay web apps can attach a Chromium renderer over your content.
4. **Debug logging into unswappable RAM.** About 70 of about 156 PmLog contexts are at `debug` (e.g. `etc/pmlog.d/acr.conf` is `"level":"debug"` with `logToConsole`). There are 101 log files of up to 10 MB × 5 rotations on ramfs. `WAM2_ENABLE_DEBUG_EVENT=1` is left on in `webapp-mgr.sh`.
5. **Network burst on wake.** On resume or reconnect, sdx, admanager, livepick-plus, care365, sportsalert, membership, igallery, aiservice, multiview and livemenu all start together, right when you start pressing buttons.
6. **About 117 long-running units at boot**, including forced-on `iot-client`, contentminer, user-context-manager + nudge, the voice stack, sportsalarm, miracast, dmr and sddp.
7. **No CPU isolation for the UI.** There are no cpusets or CPU shares, and `webos-bluetooth-service` runs at `Nice=-20`.
8. **Platform limits you can't change:** Chromium 68 (2018) for web apps, Qt 5 with `WEBOS_GL_DISABLE_THREADED_RENDERING=1`, a 32-bit userland and a `CONFIG_HZ=100` kernel. The CPU governor is already `performance`.
9. **eMMC:** all four db8 databases use `sync=1`, with CFQ idling.
10. **Long uptime under Quick Start+** (see change #8).

---

## 3. How it phones home

Almost everything goes through one broker, **`usr/sbin/sdx`** (`com.webos.service.sdx`). It maps service names
to hosts using `usr/palm/sdx/server_addr_version.conf`. The US hosts are `us.lgtvsdp.com`, `us.ibs.lgappstv.com`,
`*.lgtvcommon.com` and `*.lgtviot.com`. sdx attaches about 24 `X-Device-*` headers to every request: device ID,
model, country, firmware, the list of accepted terms and the LG account session. Device authentication uses an
encrypted MAC, and consent sync sends `hashedMacAddress` / `hashedlgudid`.

### 3.1 Automatic Content Recognition: identifying what is on screen (`findings/acr.md`)
- **Who:** `usr/sbin/acr2`, which loads the **Alphonso** (now LG Ad Solutions) SDK
  (`libalphonsosolution.so` → `libas.so.3.0.93`). It starts every boot at `rest-boot-done`
  (`etc/palm/activities/com.webos.service.acr/`). No other ACR vendor is present (no Samba, Gracenote ACR, Inscape
  or Nielsen).
- **What it captures:** the TV's own audio output through ALSA `dsnoop:0,12` (not a microphone), which is
  fingerprinted on the device (FFT) and uploaded as fingerprints. It also has a video frame-capture path
  (`libvtcapture`) for LG's own "Video ACR". It covers the **live tuner and all HDMI inputs**.
- **What it sends** (from the SDK's log format strings): device_id, **IP address, zipcode, country, longitude**,
  the ad ID (IFA), uuid, model, OS version, languages, channel name and number, the input, and **the connected
  HDMI device's identity (CEC OSD name, SPD manufacturer and description)**. For LG Channels and VOD it sends
  title, genre, rating, series, season and episode.
- **Where:** `prov-lg.alphonso.tv` (provisioning, which hands out the ACR, lookup, location, recommendation and
  debug servers), `eulacheck.alphonso.tv`, `config-overlay-ads.alphonso.tv`, plus LG's
  `aic.videoacr.lgtvcommon.com` and `aic.fooddelivery.lgtvcommon.com`. The shopping-overlay config is fetched
  over **plain HTTP** from `aic-ngfts.lge.com`.
- **Remote-controlled:** sample rate, capture duration and upload intervals all come from the server. The
  config (`acr.xml`, fetched via sdx) even names the **plugin library to load**, so LG can change ACR behavior
  without a firmware update. Capture frequency therefore can't be read from the firmware. Published research
  measured about every 15 s on LG.
- **Gated by:** `generalTermsAllowed` + `acrOnAllowed` (Viewing Information) + `option.livePlus`.
  **Limit Ad Tracking and Do Not Sell do not stop capture.** They are sent to Alphonso as flags alongside the
  fingerprints.

### 3.2 Viewing history, separate from ACR
- **`user-context-manager`** logs every **foreground app, live channel and set-top-box input with durations**
  and uploads it via `sdx/send` (to `nudge.lgtvcommon.com`), resuming from `/mnt/lg/cmn_data/ucm/*_upload_time.txt`.
  Gated by `additionalDataAllowed`.
- **`com.webos.app.inputcommon`**, the shell behind Live TV and every HDMI input (`PersonalDataLogModel.qml`),
  POSTs a per-channel watch log (`ibis_stat_secure` → `ibsstat.lgappstv.com` `livetvwatch.json`) with channel,
  zip, timezone and device ID. This is enabled for set-top-box inputs in the US.
- **Home launcher:** the recommendation request sends your **channel lineup and last channel**
  (`epgCodeList`) every time Home opens.

### 3.3 Ads
`admanager` sends the IFA with `&ifa= &lmt= &dns= &tcf=` to the ad server (`info.lgsmartad.com`, then a host
handed out by the server) and fires third-party impression and click trackers from a cookie jar. Out of the box,
LMT and Do Not Sell are **off** and the ad cookie is **on**.

### 3.4 Crash and analytics uploads
- `etc/rdxd.conf` has `AutoUpload=true`, uploading to `rdx2.lgtvsdp.com`. Crash bundles tar **every file in
  `/var/log`**, and many daemons log the UDID and MAC at info/debug level. One rdxd script includes the serial
  number and eMMC serial.
- PmLogDaemon analytics follow a 207–262-event whitelist: key presses, app launches, settings changes, inputs,
  ad impressions and voice use. **LG can push a new encrypted whitelist** to change what is collected.
- Browser error reports go to `lgtvbrowser.lgtvsdp.com`, and Amazon metrics to `device-metrics-us-2.amazon.com`.
- All of this is gated by `generalTermsAllowed` (Terms of Use / Privacy Policy).

### 3.5 Runs regardless of consent
- The connectivity check `http://lgtvonline.lge.com/`, over plain HTTP.
- Device authentication and time sync with LG's server (`"AllowNTPTime": false`).
- Certificate and broadcast-config downloads, and firmware-update checks (`snu.lge.com`, Base64 XML with device
  ID, model and country).

### 3.6 Local network exposure
- **Port 3001** (secure websocket remote API) is open to the LAN behind a pairing prompt; port 3000 is
  localhost-only.
- **DIAL** on 36866/18181 launches apps without authentication.
- **SSDP** on 1900 advertises the model, name and a persistent UUID, and avahi answers mDNS.
- **IP Control** is off but has the default key "828".
- No firewall rules are loaded at boot.

### 3.7 Voice
Push-to-talk audio streams to cloud speech-to-text (ThinQ AI `/voice/stt/v1/dictation/upstream`) or to
Alexa/Google, gated by `voiceAllowed`. **The CX has no far-field microphone** (`supportVoiceLongDistance:
false`), so there is no always-listening path.

---

## 4. Other findings

- **Stale security stack** (`findings/versions.md`):
  - The image was built in 2026 but the userland dates from 2017–2018: kernel 4.4.84, OpenSSL 1.0.2p, curl 7.61,
    **Chromium 68**, Node 8.12, connman 1.35, wpa_supplicant 2.6.
  - Versions that match known CVEs include libwebp CVE-2023-4863 and FreeType CVE-2020-15999, unless LG
    backported the fixes.
  - The CA bundle dates from April 2018: 19 certificates have expired, distrusted Symantec-family roots are
    still trusted, and newer roots (ISRG X2, GTS) are missing.
- **Debug and QA leftovers in production:**
  - `webapp-mgr.sh` starts Chromium with `--no-sandbox` and `--remote-debugging-port=9998` (probably bound to
    localhost).
  - `upnpd` hard-codes `curl -F file=@… https://qt2-kic.service.lgtvcommon.com/service/uploadFile` to a QA
    server.
  - The dev hosts `snu-dev.lge.com` and `he-kr-qa-ai.lgthinq.com` are present.
  - care365 ships a developer Azure IoT key.
- **USB execution:** `etc/connman/run_waveagent.sh` runs `waveagent` as root from whatever USB drive is
  mounted. It appears to be reachable only from factory or test menus, so it matters only with physical access.
- **Hosts DNS can't block:** hard-coded IPs `156.147.69.32` (update fallback) and `165.244.62.249` (remote
  diagnostics).
- **Leftovers from other markets:** Chinese voice stacks (Dangbei/AISpeech `*.dui.ai`, Xiaomi) and a Korean
  time server (`rdate -s time.bora.net`) ship on the US image.

## 5. Open items: confirm on a real TV

- Whether `setConfigs` persists across reboots, and whether SAM picks up a changed keep-alive list without a
  restart.
- The real ACR capture rate and upload cadence, which are server-provisioned. A packet capture with Live Plus on
  vs off would settle it.
- Actual frame-time and RAM gains from Basic Home and `maxPreloadApp: 2`. Measure with `free` and
  `/proc/meminfo` before and after.
- Whether this firmware is still rootable. Check webosbrew's compatibility list for 04.64.00; newer CX firmware
  has patched the earlier exploits.
