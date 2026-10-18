# Quick Media Switching (QMS-VRR): can it be backported to the CX?

**Short answer:** no. QMS depends on HDMI receiver code in the kernel, and the CX kernel doesn't have it. The kernel is
compiled-in and verified by secure boot, so it can't be replaced, even on a rooted TV.

This was found by static comparison of three official LG firmware images. Nothing was run on a TV.

| TV | Firmware | Platform | Kernel |
|---|---|---|---|
| OLED55CXPUA (2020) | 04.64.00 | o20, webOS 5 | 4.4.84 |
| OLED55C3PUA (2023) | 43.21.84 | o22n, webOS 8 base (shared "Re:New" image) | 6.12.44 |
| OLED55C4PUA (2024) | 23.23.30 | o22n2, webOS 9 | 5.4.268 |

The C3 and C4 images were downloaded from LG's US support pages (`gscs-b2c.lge.com`) and decrypted with
epk2extract's public keys. The C4 keeps its filesystems in an Android-style "super" partition, unpacked with
`scripts/lpunpack.py`. EDIDs were decoded with `scripts/edids.py`.

## How the C3 and C4 implement QMS

| Layer | Evidence (C3/C4) | CX |
|---|---|---|
| **Feature flag** | `"supportQmsVrr": true` in per-device profiles (`etc/webos-profile/platform/layers/00-device/*/profile.json` on C3; `etc/configd/layers/product/...` on C4) | No such key |
| **User setting** | `"qmsVrr": "on"` in `etc/palm/defaultSettings.json` (C4) | Absent |
| **EDID advertisement** | `usr/sbin/eim` reads `qmsVrr` and passes `qms_vrr` to `libhdmi-conn-protocol.so` (`SUPPORT_QMSVRR`, `supportQmsVrr`). The library sets the QMS bit at runtime; its static templates still show `QMS=0` | Advertised HF-VSDB has `QMS=0` (ALLM=1, M_delta=1, VRR 40/48-120 Hz). No code path to set it |
| **Mode-change handling** | `usr/sbin/extinput-integration`: `registerQmsVrrEnableCb`, "This model supports QMS-VRR" | Absent |
| **Kernel HDMI 2.1 RX** | `EM QMS Mode[On]. MD1/MD2/MD3`, `QMS BaseRate`, `QMS Next TFR[idx]`, `MConst_Zero_Counter` debouncing, `HDMI21__VIDEO_QMS_EM_TIMEOUT`, "QMS-VRR Timeout(msec)", `HDMI21__LINK_FORCE_QMS_MODE`, `QMSTime` | **None of these.** Only leftover status fields (`MConst[%d] QMSMode[%d]`, `hdmiQms`) and a `forceQMS` debug control. It does parse VRR metadata packets (`EM VrrRcvTime`) |

String counts in the CX kernel: `EM QMS` 0, `QMS BaseRate` 0, `Next TFR` 0, `MConst_Zero` 0, `FORCE_QMS_MODE` 0,
`QMS_EM_TIMEOUT` 0, `isQmsMode` 0. `EM VrrRcvTime` appears twice.

## LG gates QMS by chip generation

LG's shared device database (133 profiles in the C3 image) sets `supportQmsVrr` like this:
- **false** on every 2022 profile, including the C2's o22 OLED, which is newer than the CX's chip and fully HDMI 2.1;
- **true** on 2023 o22n (C3/G3) and o22n8k, k8hpp, and the 2024-2026 high-end platforms;
- **absent** for o20: CX profiles aren't in the database at all.

*Correction:* an earlier version of this file inferred that leaving out the 2022 C2 suggested a hardware limit.
The C2's own current firmware (33.31.68, webOS 10) contradicts that:
- Its kernel contains the same LX QMS receiver code as the C3/C4: "EM QMS", BaseRate, Next TFR and
  `MConst_Zero_Counter` debouncing.
- Its user space has the full QMS support.
- The o22 and o22n product profiles differ only in model-year fields, a few audio/broadcast extras and
  `hdmi.supportQmsVrr`.

The Realtek 2022 B2 (k8hp) vs 2023 B3 (k8hpp) shows the same pattern. Static analysis can't rule out a silicon
difference between the chip revisions. See `models.md` §4, which includes an untested experiment for rooted 2022 TVs.
**The CX conclusion below is unchanged:** its kernel has none of this code.

## Why it can't be backported
1. **The kernel can't be replaced.** The receiver code is compiled into the kernel image, which is verified by
   secure boot with LG's key. Root access doesn't change that.
2. **The newer driver code doesn't transfer.** It's closed source, written for kernels 5.4 and 6.12 rather than
   the CX's 4.4, and targets a newer chip.
3. **Advertising QMS alone would make things worse.** A rooted TV *could* set the EDID QMS bit (by overriding
   `libhdmi-conn-protocol.so`) and add a `qmsVrr` setting. Sources would then switch frame rates expecting the TV
   to follow seamlessly, and the CX would likely blank or stutter on every change.

The nearest alternative is the CX's existing HDMI Forum VRR, which needs a source that applies VRR to video.
Most sources only use it for games.
