# LG OLED model lines 2020–2024: firmware comparison

The CX audit (the rest of this repo) was repeated, in condensed form, for every major LG OLED line from 2020 to
2024. Each US firmware image was downloaded from LG's support pages, decrypted, unpacked and reduced to a "fact sheet"
(`scripts/factsheet.sh`; outputs in `factsheets/`). Nothing was run on a TV, so everything here is static analysis.

**Short version:**
- **Privacy:** every line has the same phone-home stack as the CX: Alphonso ACR listening on `dsnoop:0,12`, ad
  overlays, viewing-history upload and crash/analytics upload. Defaults are the same everywhere. 2021+ adds consent
  flags for broadcaster audio watermarks (Verance) and shopping. 2022+ adds `service-logger`, which records
  connected HDMI devices (monthly) and HDMI game-session details (on input changes) and sends them through LG's
  `sdx` broker.
- **Performance:** the B series is the weak spot. 2022–2024 B models have 2 GB of RAM against 2.5 GB on the C/G,
  yet LG gives them the same preload budget (6 apps).
- **QMS and Hue Sync on 2022/2023 TVs look like product decisions, not hardware limits.** These sets have been updated
  to webOS 10/11.
  - **QMS:** the C2 and B2 (2022) kernels contain the same QMS receiver code as the 2023/2024 models. The only
    visible difference is LG's profile flag `hdmi.supportQmsVrr`, which is off for 2022.
  - **Hue Sync:** the 2022/2023 images have the same end-to-end histogram path as officially supported 2024 models,
    in the same library builds.
- **Not covered:** Z2/Z3 (8K, 2022–23) couldn't be decrypted; no public key exists for their chips. Z1, RX and M4
  have no firmware on LG's US support site.

## 1. Which firmware covers which model

Many models share one image, so 15 images cover all 2020–2024 lines. Model codes were checked on lg.com/us/support.

| Year | Line (US models checked) | Firmware image | Chip | webOS | Kernel | RAM¹ |
|---|---|---|---|---|---|---|
| 2020 | **CX**, GX, WX (OLED55CXPUA, 65GXPUA, 65WXPUA) | 04.64.00 | o20 (LG α9 Gen3) | 5.6.2 | 4.4.84, arm64 | – |
| 2020 | **BX** (OLED55BXPUA) | 04.64.00 | k6hp (Realtek) | 5.6.2 | 4.4.84, 32-bit | – |
| 2020 | **ZX** 8K (OLED88ZXPUA) | 04.64.00 | o208k | 5.6.2 | 4.4.84, arm64 | – |
| 2021 | **A1/B1** (48/55A1PUA, 55B1PUA) | 03.53.45 | lm21u (MediaTek) | 6.5.3 | 4.4.84, 32-bit | – |
| 2021 | **C1/G1/R1** (48/55/65/83C1, 55/65G1PUA, 65R1PUA) | 03.53.45 | o20n | 6.5.3 | 4.4.84, arm64 | – |
| 2022 | **A2/B2** (55A2PUA, 55B2PUA) | 33.31.75 | k8hp (Realtek) | 10.3.2 | 5.4.268 | 2 GB |
| 2022 | **C2/G2** (55C2PUA, 55G2PUA) | 33.31.68 | o22 | 10.3.1 | 5.4.268 | 2.5 GB |
| 2022 | Z2 8K (77/88Z2PUA) | 33.31.75 | o228k | – | – | 3.5 GB |
| 2023 | **B3** (55B3PUA) | 33.31.75 | k8hpp (Realtek) | 10.3.2 | 5.4.268 | 2 GB |
| 2023 | **C3**, G3, M3 (55C3/55G3/83M3PUA) | 43.21.84 | o22n | 11.2.0 | 6.12.44 | 2.5 GB |
| 2023 | Z3 8K (77/88Z3PUA) | 33.31.61 | o22n8k | – | – | 3.5 GB |
| 2024 | **B4** (55B4PUA) | 33.31.75 | k24 (Realtek) | 10.3.2 | 5.4.268 | 2 GB |
| 2024 | **C4** (55C4PUA) | 33.31.69 (and the older 23.23.30²) | o22n2 | 10.3.1 (23.23.30: 9.2.4) | 5.4.268 | 2.5 GB |
| 2024 | **G4** (55/65G4SUB) | 43.21.71 | o24 | 11.2.0 | 6.12.44 | 2.5 GB |
| 2024 | M4 | not on LG US support | o24 (`TV_2024_o24_W24O_OLED_2.5G_M4`) | – | – | 2.5 GB |

¹ From the RAM size in LG's device profile names (e.g. `TV_2022_k8hp_W22H_OLED_2G`). The 2020/2021 images have no
such database. ² 23.23.30 is the build analyzed in `qms.md` and `huesync.md`. The tables below use 33.31.69, LG's current
C4 release.

How the images were obtained and processed:
- Firmware links come from the JSON in each support page. There are two formats: a `downloadLink` URL, or a
  `fileName` holding the file ID. The ~2 MB "SW File" entries are just the PDF update guide.
- Z2 (o228k) and Z3 (o22n8k) fail with "proper AES key is missing". epk2extract's public key list has no entry for
  those chips.
- 2022+ LX images (C2 onward) use zstd squashfs, which epk2extract's built-in unsquasher can't read (it aborts). Run
  `epk2extract -n` and unpack with system `unsquashfs` (squashfs-tools 4.5+).
- MediaTek/Realtek kernels are gzip-compressed (BX: inside a uImage). `factsheet.sh` decompresses them.
- 2022 and later sets have been moved to newer webOS by LG's "Re:New" upgrade. So the current 2022 firmware is
  webOS 10 and the current 2023 C3 firmware is webOS 11, newer than the shipping OS of those models.

## 2. Privacy: what's the same and what's new

### Same on every line (2020–2024)
Every image has all of these:
- **ACR:** the `acr2` daemon with the Alphonso SDK (`libas.so` 3.0.93; 3.0.98 on the webOS 11 C3/G4), listening
  on ALSA `dsnoop:0,12`.
- **Ads:** `admanager`, `adoverlay-service`, and the per-HDMI ad overlay apps (`acrhdmi*`/`overlaycontainerhdmi*`
  on 2020, `adhdmi*` later).
- **Viewing history and nudges:** `user-context-manager` and `nudge`.
- **Uploads:** crash and analytics upload (`rdxd`, `uploadd`) and LG's `sdx` broker.
- **Remote access and beacons:** LG Remote Service (`remotediag`) and the `dmost` beacon (hashed UDID, encrypted
  MAC).

- ACR endpoints are the same everywhere (`eulacheck.alphonso.tv`, `prov-lg.alphonso.tv`).
- Out-of-box defaults are identical on every image (`etc/palm/defaultSettings.json`):
  - `livePlus` off until the user accepts terms;
  - `adCookie` on, `lmt` (limit ad tracking) off;
  - `homePromotion` on, `livePromotion` on, `screenSaverAd` on.

  The one change is `homeAutoLaunch`, which became **on** by default in the webOS 10/11 images: it opens the Home
  screen at power-on.
- **The CX privacy settings apply to every line.** These are the menu switches in `REPORT.md` §3 and the DNS
  blocklist.

### New since the CX
| Change | Where | What it is |
|---|---|---|
| Consent flags `veranceOnAllowed`, `shoppingOnAllowed`, `wasuOnAllowed` | 2021+ (all lines) | New EULA keys. `wasu` is the China Wasu IPTV partner and does nothing in the US. |
| ATSC 3.0 watermark "content recovery" (`content-recovery-data`, plus Verance support in `hybridtv-manager`, A/336 VP1) | 2021+ | The TV detects broadcaster audio/video watermarks so ATSC 3.0 broadcaster apps keep working when the picture comes through a cable box over HDMI. `content-recovery-data` *downloads* a recovery table from an LG service URL; nothing in the strings suggests it uploads audio. Gated by `veranceOnAllowed`. [Inference] Broadcaster apps launched this way are web apps that can do their own audience measurement. |
| **`service-logger`** (`com.webos.service.logger`, starts at boot) | 2022+ (B2, C2, B3, C3, B4, C4, G4) | Rule-driven logging (`etc/palm/service-logger/rules/`). One rule runs monthly and lists every active input with its CEC device name and brand. Another fires on HDMI picture-mode/aspect changes and records the current app, input, volume, picture mode and resolution (`getGameDeviceInfo.py`). Others collect first-use, child-mode and screen info. Results go through `luna://com.webos.service.sdx/send` to LG. **[Unverified]** whether `sdx` applies a consent gate to these logs. The binary itself contains no consent check. |
| `objectdetection` + `ai-inference-manager` | 2022+ images (C4's 23.23.30 has only `objectdetection`) | On-device AI. `objectdetection` takes frames from `com.webos.service.capture`; this analysis found no network code in it. |
| `awareness-agent` | webOS 11 (C3, G4) | Presence-sensing framework (types `sound_mic`, `vision_camera`, `mmwave`, `ultrasonicSensor`). Needs a camera/mic accessory or a set with sensors. |
| `com.webos.service.microphone`, `camera2` | 2021+ | USB camera/mic support for video calls and voice. |
| `iot-client` (ThinQ) | moved from `usr/sbin` to `usr/bin` in 2022+ | Same service, still running. |

### Turning it off on newer models
The menu settings and DNS blocklist from `REPORT.md` work on every line. `scripts/50scrub` targets the CX's
firmware 04.64.00, and these are the per-line differences:
- **Its systemd units exist on every line**: `user-context-manager`, `nudge`, `rdxd`, `uploadd`, `iot-client`,
  `webos-sddp`, `dmost`. So the stop/mask block works unchanged wherever the TV can be rooted.
- **`sportsalarm` has no systemd unit on any image, the CX included.** It's an on-demand luna service, so the old
  `systemctl` line did nothing. `50scrub` now blocks its service file instead.
- **2022+:** also stop `service-logger.service` if you want the HDMI-device and game-session logging gone.
- `livepick-plus` is absent on the 2021 images and on the C4's 23.23.30. `pkill` on a missing process is harmless.
- **Rooting:** these recipes need a rooted TV. Whether a given firmware can be rooted changes often, so check the
  webOS Homebrew Channel's compatibility notes. Current 2022+ firmware may not be rootable.

## 3. Performance across lines

| | CX/GX/ZX | BX | A1/B1 | C1/G1 | B2 | C2 | B3 | C3/G3/M3 | B4 | C4 | G4 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| RAM (profile) | – | – | – | – | 2 GB | 2.5 GB | 2 GB | 2.5 GB | 2 GB | 2.5 GB | 2.5 GB |
| Preloaded apps (`maxPreloadApp`) | 6 | 6 | 6 | 6 | 6 | 6 | 6 | 6 | 6 | 6 | 6 |
| Kernel tick (`CONFIG_HZ`) | 100 | 100 | ? | 100 | 250 | 250 | 250 | 250 | 250 | 250 | 250 |
| Kernel | 4.4 | 4.4 (32-bit) | 4.4 (32-bit) | 4.4 | 5.4 | 5.4 | 5.4 | 6.12 | 5.4 | 5.4 | 6.12 |
| Binaries in rootfs | 1,039 | 992 | 1,019 | 1,068 | 1,239 | 1,244 | 1,236 | 1,541 | 1,237 | 1,247 | 1,548 |
| Luna services | 120 | 111 | 129 | 138 | 194 | 199 | 191 | 285 | 192 | 200 | 287 |

- **All lines run the "normal" variant with 6 preloaded apps.** LG hard-codes the variant in `configd.service`
  (`WEBOS_TARGET_DISTRO_VARIANT=normal`), so the 2 GB B models keep as many apps warm as the 2.5 GB C/G models.
  This is why B-series sets kill apps and cold-start more often.
  - The `preloadApp.maxPreloadApp: 6` in every 2022+ device profile confirms it.
  - The CX advice in `findings/launch.md` (replace LG's preload mix with the apps you use, via `scripts/60launch`)
    matters most on B models.
- **The software has kept growing.** webOS 11 (C3/G4) carries about 50% more binaries and more than twice the luna
  services of webOS 5 (CX), on the same 2.5 GB.
  - The debug-level log contexts the CX script turns down have grown too. Log configs mentioning `debug` went from
    74 on the CX to about 115 on webOS 10/11.
  - The CX tuning (log levels to `warning`, zram `page-cluster` 0, stopping optional daemons) still applies.
  - Some log context names differ between versions. `PmLogCtl` just errors on a context that doesn't exist.
- **Newer kernels help.** 2022+ kernels run at 250 Hz rather than 100 Hz and use MGLRU (`CONFIG_LRU_GEN=y`), which
  copes better with memory pressure than the 4.4 kernel's reclaim.
  - The 2020–2021 lines are stuck on 4.4. The kernel is signed, so this can't be changed.
  - The webOS 10/11 upgrades are a real performance improvement for 2022/2023 owners, separate from any UI changes.

## 4. QMS-VRR by line

`qms.md` compared CX, C3 and C4. With the other lines added:

| | CX/BX/ZX | B1/C1 | B2 | C2 | B3 | C3 | B4 | C4 | G4 |
|---|---|---|---|---|---|---|---|---|---|
| Kernel QMS receiver code | no | no | **yes** (Realtek QMS state machine) | **yes** (LX "EM QMS", same as C3/C4) | yes | yes | yes | yes | yes |
| User-space QMS support (`eim`, `extinput-integration`) | no | no | yes | yes | yes | yes | yes | yes | yes |
| Profile flag `hdmi.supportQmsVrr` | – | – | **false** | **false** | true | true | true | true | true |

**2020–2021 (CX, BX, ZX, B1, C1): impossible.** Neither the kernel nor user space has the code, and the kernel is
signed (see `qms.md`).

**2022 (B2, C2): probably a decision, not a hardware limit.**
- Both 2022 kernels contain the same QMS receiver code as the 2023 model on the same chip family: Realtek k8hp vs
  k8hpp, and LX o22 vs o22n. There's no chip-revision check in the QMS strings.
- The configd product profiles for 2022 vs 2023 differ in the same handful of keys on both families: model-year
  fields, a few audio/broadcast extras, and `hdmi.supportQmsVrr` false→true. `extinput-integration` reads that flag
  through `com.webos.service.config` (`profile.hdmi` → `supportQmsVrr`) and otherwise logs "This model does not
  support QMS-VRR".
- [Inference] The o22→o22n and k8hp→k8hpp revisions may still differ in silicon in ways the strings can't show
  (scaler or frame-rate-converter timing). Static analysis can't rule that out.
- **Possible experiment (untested, rooted 2022 TV only):**
  1. Set the flag with configd's private `setConfigs` method (present in these builds):
     `luna-send -n 1 luna://com.webos.service.config/setConfigs '{"configs":{"profile.hdmi.supportQmsVrr":true}}'`
  2. Restart `extinput-integration` and `eim`.
  3. Turn on the `qmsVrr` setting that then appears.

  If the hardware can't do it, the likely result is a blank screen on frame-rate changes, which is the same risk
  `qms.md` describes. configd may persist the change, so undo it by setting the flag back to `false`.

**2023–2024 (B3, C3, B4, C4, G4):** supported officially.

## 5. Hue Sync by line (corrects `huesync.md`)

The Philips app is officially 2024+ only. Signify says it relies on firmware capabilities "only available on LG TVs
from model year 2024 onwards" and "not dependent on the webOS version".

| | CX/BX/ZX | B1/C1 | B2 | C2 | B3 | C3 | B4 | C4 | G4 |
|---|---|---|---|---|---|---|---|---|---|
| Histogram API in `libvtcapture` | no | no | yes | yes | yes | yes | yes | yes | yes |
| Path to hardware | – | – | V4L2 `/dev/video60` → Realtek kernel (computed in a TrustZone app) | V4L2 `/dev/video60` → LX kernel | same as B2 | nyx `ScreenCapture` module → V4L2 `/dev/video60` → kernel | same as B2 | same as C2 (23.23.30 used LG `HAL_*Histogram` instead) | same as C3 |
| Kernel defines `V4L2_CID_EXT_HISTOGRAM_*` | no | no | yes | yes | yes | yes | yes | yes | yes |
| `color-info-miner` Hue bridge | no | no | yes | yes | yes | yes | yes | yes | yes |
| Hue service allowlisted in `libvtcapture` | no | no | yes | yes | yes | yes | yes | yes (not in 23.23.30) | yes |
| Officially supported | no | no | no | no | no | no | **yes** | **yes** | **yes** |

- **Same webOS build, same library, different answer, three times over:**
  - **webOS 10, LX chips:** the supported C4 (33.31.69) and the unsupported C2 have an identical `libvtcapture`
    (same strings, so it's the same build). Both kernels define the histogram controls. Their product profiles
    differ only in model-year fields, a few audio/broadcast/camera extras and `hdmi.supportQmsVrr`.
  - **webOS 11:** the supported G4 and the unsupported C3 ship identical `libvtcapture` strings and the same
    histogram path. Their device profiles differ only in
  model-year, multi-view, sign-language-avatar and audio fields.
- **The same holds for the Realtek B line.** On webOS 10, the supported B4 and the unsupported B2/B3 share an
  identical `libvtcapture`. All three kernels implement the histogram controls.
- **[Inference] On current firmware, the 2022/2023 exclusion looks like a store or business decision.** Signify's
  "deep firmware capability" can't be found in these images. What static analysis *can't* show is whether the
  histogram data from older silicon is as good: bin count, color vs luma, latency.
- **The 2020/2021 lines really lack the pieces.** `huesync.md`'s CX alternative (PicCap + Hyperion.NG) applies to
  BX, ZX, B1 and C1 too.

`huesync.md` said the C3 build of `libvtcapture` "never calls that hardware". That was wrong: it calls it through the
nyx module, which the earlier check didn't follow. `huesync.md` has been corrected.

## 6. Note on the C4

`qms.md` and `huesync.md` used the C4's 23.23.30 build (webOS 9) and said the newer 33.31.69 wasn't downloadable.
It is: LG lists it in the second JSON format, which the first scraper missed.
- 33.31.69 is webOS 10.3.1, on the same kernel build string as the C2 (5.4.268-329.ptl4tv.5).
- It replaces the HAL histogram route with the V4L2 route that the 2022/2023 models use.
- Both C4 builds are in `factsheets/` (`c4` = 23.23.30, `c4_33.31.69`).
