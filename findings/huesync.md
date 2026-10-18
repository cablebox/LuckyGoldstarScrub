# Philips Hue Sync TV: hardware limit or business decision?

**Short answer:** it depends on the model.
- **C3 (2023): most likely a business or certification decision, but not proven.** Its current firmware
  (webOS 11) ships the Hue bridge service, allowlists the Hue app by name, and wires the histogram API through to the
  kernel (nyx ScreenCapture module → V4L2 `/dev/video60` → `V4L2_CID_EXT_HISTOGRAM_*`). The officially supported
  2024 G4 runs the same webOS 11 build with an identical capture library. *Correction:* an earlier version of this
  file said the C3's capture library never calls the hardware. It does, through the nyx module, which the first
  check didn't follow. `models.md` §5 extends this to the 2022/2023 B and C lines.
- **CX (2020): partly a real limit.** It lacks the histogram capture API and the Hue bridge service, and its
  frame-capture path refuses DRM-protected video. The official app can't be backported, but rooted CX owners can
  get most of the effect with open-source tools (see the last section).

This was found by static comparison of three firmware images: CX 04.64.00 (o20), C3 43.21.84 (o22n) and C4
23.23.30 (o22n2). The C4 image is from September 2025. LG's newer C4 build (33.31.69) is listed in a second page
format the first scraper missed. `models.md` adds the other 2020-2024 lines, including the webOS 11 G4 (43.21.71).
See `qms.md` for how the images were obtained. Nothing was run on a TV.

## Public statements
- Philips: available on "2024 and newer LG TV models with webOS24 or higher". It is a $129.99 store app (or a
  subscription) that needs a Hue Bridge.
- Philips told Hueblog that the app "is dependent on the capabilities of the TV firmware at a deep level", that
  these are "only available on LG TVs from model year 2024 onwards", and that this "does not depend on the webOS
  version". So a 2023 C3 upgraded to webOS 24/25 still can't get it.

## How the 2024 firmware supports the app

| Piece | Where | What it does |
|---|---|---|
| Hue app | Store app `com.lighting.huesync`, with background service `com.lighting.huesync.service` (binary `hue_sync_service`) | Does the sampling and talks to the Hue Bridge |
| Capture permission | `usr/lib/libvtcapture.so` (`lib32-screen-capture-webos`) | Checks `/proc/<pid>/cmdline` against an allowlist ("Client not found on the whitelist." → `LIB_CAPTURE_REFUSED_PERMISSION_DENIED`) |
| **Histogram API** | `libvtcapture`: `vtCapture_initHistogram`, `setPresetHistogram`, `getHistogram`, `finalizeHistogram` (`webos_vt_histogram.cpp`, `vtHistogram.cpp`) | Picture statistics rather than raw frames. On C4 it calls `HAL_StartHistogram`/`HAL_GetHistogram`/`HAL_SetPresetHistogram` in `bsp/usr/lib/libpqeca.so`, i.e. a picture-engine hardware block |
| TV integration | `usr/sbin/color-info-miner` (`com.webos.service.colorInfoMiner`, APIs `hueSync/getStatus`, `setAutoEnable`, `setManualEnable`). It starts when `com.lighting.huesync` is installed (activity on `getAppStatus`) and at boot when `other.hueSyncAutoEnable` is true (`colorInfoMiner-start.service`) | Settings and lifecycle bridge between the TV menu and the Hue service. **No capture code**: it links only glib, luna, PmLog and pbnjson |

## Comparison

| | CX 2020 | C3 2023 | C4 2024 |
|---|---|---|---|
| Frame capture (`vtCapture_init/process/...`) | yes (the ACR daemon uses it) | yes | yes |
| Histogram API in `libvtcapture` | **no** | yes | yes |
| Hue service on the capture allowlist | no | **yes**, hard-coded `/com.lighting.huesync.service/hue_sync_service` in `libvtcapture` and `captureservice` | **not in 23.23.30.** No Hue entry in any file there. **Present in the current 33.31.69 build**, which also switches to the same V4L2 histogram route and the same `libvtcapture` build as the unsupported C2 (see `models.md` §5) |
| Histogram wired to hardware | — | **yes, via nyx.** `libvtcapture` calls `nyx::ScreenCapture_1_0::getHistogramData`. `usr/lib/nyx/modules/nyxScreenCapture.module` implements `start/stop/getHistogramData` with V4L2 ext controls on `/dev/video60`, and the C3 kernel defines `V4L2_CID_EXT_HISTOGRAM_{START,STOP,DATA,PRESET}`. The webOS 11 G4 (supported) uses the same route | **yes.** Imports `HAL_Start/Stop/Get/SetPresetHistogram` from `libpqeca` |
| `color-info-miner` Hue bridge | no | **yes** | yes |
| Device-profile difference vs. C4 | — | In the **C4 firmware's own** `etc/configd/layers/product/default/{o22n,o22n2}/profile.json`, 9 of 23 keys differ, all model-year, remote or store-demo fields; none relate to capture or lighting. The C3 image's copy of the 2024 profiles agrees | — |
| Picture-engine statistics | luma histogram (`PE_HST_HW_O20_GetLumaHistogram`) and per-block brightness (APL). No color statistics found | ? | HAL histogram via `libpqeca` (contents not visible statically) |
| Protected video | frame capture refuses it (`LIB_CAPTURE_REFUSED_WATCHING_SECURE_VIDEO`) | same refusal code present | same refusal code present |

**C3 verdict:**
- The C3 and C4 are the same chip family (o22n and o22n2), and their profiles differ only in model year, even in
  the C4 firmware's own copy.
- The C3 firmware ships the Hue bridge service, the histogram API, a hard-coded Hue allowlist entry, and a working
  path from that API to the kernel's histogram controls.
- On webOS 11, the C3 and the supported G4 share the same `libvtcapture`. Their device profiles differ in nothing
  related to capture or lighting.
- [Inference] So the exclusion is most likely a store filter that lists the app only for 2024+ models, i.e. a
  business or certification decision. Philips' "does not depend on the webOS version" fits a model-year filter.
- Static analysis can't prove the C3's histogram hardware returns data as good as the 2024 chips' (bin count, color
  vs luma, latency).

**CX verdict:** the CX genuinely lacks the histogram API and the Hue bridge service, and its picture engine exposes
only brightness statistics. The histogram API is software that could in principle be written. [Inference] It
probably relies on a color-statistics hardware block the CX may not have. The CX's frame capture works but refuses
protected video. So a CX version can't see DRM-protected content in the built-in apps (Netflix, Disney+, and
similar), which is a real limit of the CX's secure video path.

## Getting Hue sync on a CX anyway (rooted TV)

**The official app can't be used.** The store won't offer it to a 2020 model, it calls a histogram API the CX
doesn't have, and copying the licensed app package from a 2024 TV isn't an option.

**The open-source alternative already exists** and covers most of the feature:
1. **Root** the TV and install the Homebrew Channel (webosbrew). Check its compatibility list for firmware
   04.64.00 first; newer firmware has patched earlier root methods.
2. Install **PicCap** (`org.webosbrew.piccap`). It's a front end for **hyperion-webos**, which captures the picture
   through the same `libvtcapture` library (webOS 5+) and the UI through `libhalgal`, and sends low-resolution frames
   over the network.
3. Run **Hyperion.NG**, either on the TV through the `org.webosbrew.hyperion.ng.loader` homebrew package or on a
   Raspberry Pi/PC. Point PicCap at it.
4. In Hyperion.NG, add a **Philips Hue** LED device in Entertainment mode: pair with the bridge's link button,
   choose a Hue entertainment area, and lay out the lights around the screen.

Limitations compared with the official app:
- DRM-protected content in the TV's built-in apps can't be captured. hyperion-webos documents this, and it matches
  `LIB_CAPTURE_REFUSED_WATCHING_SECURE_VIDEO` above. HDMI inputs, Live TV and unprotected apps work. A workaround is
  to play streaming services on an HDMI stick instead of the built-in apps.
- It's experimental, built on reverse-engineered APIs. Community reports mention HDMI capture stopping until a
  reboot on some models.
- It adds CPU load on a TV that's already short of memory (see `performance.md`).

Sources: Philips Hue developer site (sync-with-tv/sync-app), Hueblog (hueblog.com/?p=17920),
github.com/webosbrew/hyperion-webos, repo.webosbrew.org (PicCap, Hyperion.NG loader).
