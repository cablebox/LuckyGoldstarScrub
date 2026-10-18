# Backporting Hue Sync to the C3: what it would actually take

**Bottom line:** there is nothing to backport into the C3's firmware. Every TV-side piece Hue Sync needs is already
present in the shipping C3 image and is wired to switch itself on automatically the moment the Hue app is installed.
The only thing keeping Hue Sync off a C3 is that LG's Content Store does not *offer* the app to a 2023 model. That is
a server-side catalog decision, not a firmware limitation — so "backporting" is the wrong frame. The realistic
question is how to get the app (or an equivalent) onto the TV, and the honest answer has one clean route and two dead
ends.

This is static analysis of the C3 image `43.21.84` (o22n, webOS 11). Nothing was run on a TV.

## 1. The C3 firmware is already complete

Everything the 2024 models use is in the C3 image, byte-for-byte the same build in the parts that matter
(`libvtcapture` is identical to the officially supported webOS 11 G4 — see `models.md` §5):

| Piece | C3 status |
|---|---|
| Frame/histogram capture API (`libvtcapture`) | present; identical build to the supported G4 |
| Histogram wired to the kernel (nyx `ScreenCapture` → V4L2 `/dev/video60` → `V4L2_CID_EXT_HISTOGRAM_*`) | present and functional |
| Capture permission for the Hue service | the Hue service (`/com.lighting.huesync.service/hue_sync_service`) is **already on the capture allowlist** inside `libvtcapture`, and `com.webos.service.capture` is present |
| TV↔Hue bridge (`color-info-miner`, `com.webos.service.colorInfoMiner`) | present, with the `hueSync` API (`SetHueSyncAutoValue`, `NotifyHueSyncGetStatus`, `getHueSyncInfo`) |
| Settings keys | `other.hueSyncAutoEnable` / `hueSyncManualEnable` exist in `defaultSettings.json` |

### The bridge auto-activates on app install — with no model check

The decisive evidence. `color-info-miner` is started by this activity
(`etc/palm/activities/com.webos.service.colorInfoMiner/...start.json`):

- **Trigger:** subscribe to `luna://com.webos.applicationManager/getAppStatus` for `appId: com.lighting.huesync`,
  fire when `exist == true`.
- **Callback:** `luna://com.webos.service.colorInfoMiner/startUp`.
- **Description (LG's own):** *"Start colorInfoMiner service, if hueSync service installed."*

There is no model, year, chip, or `supportHueSync` condition anywhere in the trigger, and none inside
`color-info-miner` itself (its only consent-type string is the generic `additionalDataAllowed`). The C3 is built to
turn Hue Sync on the instant the app appears. LG simply never lets the app appear.

## 2. So the only real gate is the store catalog

The Hue app (`com.lighting.huesync`) is **not** in the firmware — it is a paid third-party app from Signify
($129.99 one-time or a subscription) downloaded from the LG Content Store. The Store decides which models may see and
install it, keyed on model year. That filter lives on LG's servers, not on the TV, and matches Signify's public line
that the app needs "capabilities only available on LG TVs from model year 2024 onwards" — a statement the C3 firmware
contradicts (`models.md` §5), which points to a commercial/certification arrangement rather than a hardware fact.

That reframes the task: you cannot "patch" a C3 into supporting Hue Sync, because it already supports it. You can
only change whether the app gets onto the TV.

## 3. Routes

### Route A — the legitimate fix: get LG/Signify to extend the allowlist
The capability gap is fictional, and this repo documents why. The clean path is to make that case to the parties who
own the catalog filter: Signify (who stated the 2024 requirement) and LG. This is the only route that ends with the
*official, supported, licensed* app running on a C3, and it is a business decision on capable hardware, not an
engineering problem. Realistically it needs public/user pressure, not a single request.

### Route B — the open-source equivalent (recommended, works today on a rooted C3)
You don't need LG's app to drive Hue lights from the screen. The webosbrew stack does the same job with software you
install yourself, and it is the same approach `huesync.md` recommends for the CX — except the C3 is a *better* host
for it (newer SoC, the full modern capture path):

1. **Root** the TV (webOS Homebrew Channel). Check the current rootability of C3 firmware `43.21.84` / whatever build
   your set is on before starting; LG patches root methods in newer releases, so this is the real gating step, not
   anything about Hue.
2. Install **PicCap** (`org.webosbrew.piccap`), the front-end for **hyperion-webos**, which captures the screen
   through the same `libvtcapture` the Hue app would use.
3. Run **Hyperion.NG** (on the TV via `org.webosbrew.hyperion.ng.loader`, or on a Pi/PC).
4. In Hyperion.NG, add a **Philips Hue** device in **Entertainment** mode: press the bridge's link button to pair,
   pick an entertainment area, and lay out the lights around the screen.

Caveats, stated honestly:
- **DRM-protected video can't be captured**, on the C3 exactly as on the CX. Every image in this study, the
  supported 2024 models included, carries `LIB_CAPTURE_REFUSED_WATCHING_SECURE_VIDEO`; the capture path refuses
  protected streams. So built-in Netflix/Disney+/etc. won't light up; HDMI inputs, Live TV and unprotected apps
  will. The official Hue app lives with the same boundary. This is a content-protection limit, not a bug to route
  around — play protected services from an HDMI stick if you want them captured.
- It's reverse-engineered homebrew: expect occasional capture stalls needing a reboot, and some CPU cost.

### Route C — sideloading the official app: not a path I'll help build, and probably a dead end anyway
In principle the C3 would run the real app if its IPK were placed on the TV, because (§1) the firmware is ready. But
making that happen means taking a paid, licensed Signify app off a 2024 TV and installing it on hardware the Store
won't sell it to — circumventing both the purchase and LG's distribution control. I'm not going to write that
procedure.

Separately, it very likely wouldn't work even if attempted: the app is a paid product that almost certainly performs
its own entitlement check against Signify's servers and may check the TV model itself. None of that is in the firmware
(the app isn't on-disk to inspect), so the TV-side readiness in §1 is necessary but not sufficient. Route B gets you
the actual feature — lights that follow the screen — without any of this.

## 4. Summary

- **Nothing to backport.** The C3 firmware already contains and auto-enables the complete Hue Sync TV stack; the
  activation trigger has no model gate.
- **The block is LG's store catalog**, a business decision, not a hardware or firmware limit (consistent with
  `models.md` §5 and `huesync.md`).
- **To get the official app:** the only legitimate route is persuading LG/Signify to list the C3 (Route A).
- **To get the feature now:** the open-source Hyperion.NG + PicCap route (Route B) works on a rooted C3 and is the
  same method used for the CX, with the same DRM-capture limitation that even the official app has.
