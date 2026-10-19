# Post-root ambient light: Hyperion.NG vs HyperHDR, DRM capture, and the store-spoof question

Consolidates the 2026-10-18 decisions and in-image checks that followed the rooting phase.
Applies to the C3 (33.31.68) and the CX (04.64.00) unless noted. IPKs staged in `fw/ipks/`
(not committed): `org.webosbrew.piccap_0.5.3_all.ipk`, `org.webosbrew.hyperion.ng.loader_0.1.11_all.ipk`,
`org.webosbrew.hyperhdr.loader_22.0.1_all.ipk`.

## Architecture (both TVs)

PicCap/hyperion-webos on the TV captures via `libvtcapture`; a server consumes the stream and
drives the Hue bridge (192.168.1.111) through the **Entertainment API** (link button, pick an
entertainment area, position lights). Server can run on-TV (loader IPK) or off-TV (Mac/Pi);
off-TV costs the TV nothing and is recommended for the CX (2.5 GB-class RAM).

## Hyperion.NG vs HyperHDR

| | Hyperion.NG | HyperHDR |
|---|---|---|
| Role | Community successor of Hyperion; default ecosystem choice | Performance/quality fork of Hyperion.NG for low-power ARM |
| Grabber protocol | speaks PicCap's network feed | same |
| Hue Entertainment | yes | yes |
| Image pipeline | classic corrections | LUT tone mapping, better HDR→SDR handling, NEON optimizations |
| webOS loader | yes (staged) | yes (staged, v22.0.1) |

Decision rule: PicCap delivers post-tone-mapped (SDR) frames from the panel, so HyperHDR's
HDR edge mostly evaporates. Start with Hyperion.NG; swap servers later is a 5-minute test.

## DRM content: why root doesn't help (evidence)

`libvtcapture.so.1` (lib32-screen-capture-webos 1.0.0-56) makes no decision itself: it embeds
uMediaServer's `ResourceManagerClient` and obeys per-media-session DRM metadata registered by
the player (`com.webos.service.capturepermission`, `notifyForeground` strings in-image).
Widevine-L1 sessions are marked secure truthfully — plaintext frames never leave the
TEE-protected carveout — so a root-level check override yields kernel refusal or black, not
pixels. L3/software-decode sessions are not marked secure and are already capturable.
**Practical route for built-in DRM apps: play them from an HDMI source** (stick/console);
HDMI inputs capture normally. The official Hue app carries the identical limitation.

## Official app: the C4-spoof purchase experiment (design, untested)

Post-root idea: present a C4 identity (`build-info`/configd profile model fields) to the
store's SDP queries only, buy `com.lighting.huesync` at full price, install the resulting
licensed IPK. Constraints, from `findings/store_architecture.md`:
- The spoof must be scoped per-service — a global identity change would let `softwareupdate`
  offer C4 firmware on C3 silicon (brick).
- LG's server has the deviceId registered as a C3; purchase-time cross-check behavior is
  unknown (the catalog filter is server-side).
- Payment circumvention is not involved (full price paid); the open question is only whether
  LG/Signify's gates refuse the purchase or the app's runtime check refuses the model.
Priority: below the Hyperion baseline; run only after root, as a contained experiment.

## Applies to the CX too

CX (04.64.00, webOS 5.6.2): SlopBro unpatched at that firmware (CanI data) — root with
`--webos-version 5`; then this whole document applies unchanged (frame capture present since
webOS 5; the 2022+ histogram API only ever mattered to the official app).
