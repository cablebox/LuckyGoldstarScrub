# ACR / content-identification / ad-targeting audit: LG OLED55CXPUA, webOS 5 (fw 04.64.00, o20, ATSC)

Scope: static analysis of the decrypted firmware only. Nothing was executed. All paths are relative to
`rootfs.pak.unsquashfs/` unless stated otherwise. `otncabi-atsc`, `otycabi-atsc` and `bsppart-atsc` were also
searched: they contain no ACR, Alphonso or LivePick components (matches there are unrelated string noise).

Legend:
- **[OBS]** means directly observed in a file. The quoted string or config line is given.
- **[INF]** means inference drawn from naming, log strings or how the code is structured. Not verified at runtime.

---

## 0. Executive summary

| Component | What it is | Captures content? | Talks to |
|---|---|---|---|
| `usr/sbin/acr2` (luna `com.webos.service.acr`) | LG's ACR host daemon ("Live Plus") | **Yes.** It reads audio PCM through ALSA `dsnoop:0,12` and has a video frame-capture path through `libvtcapture` | LG SDP (`*.lgtvsdp.com`, `acrconfig`) for the config, via `sdx` |
| `usr/lib/libalphonsosolution.so.1.0.0` | Plugin that acr2 loads with `dlopen` (`CreateSolution`). Adapter for Alphonso | Gets audio buffers from acr2 | (through libas) |
| `usr/lib/libas.so.3.0.93` | **Alphonso (now LG Ad Solutions) ACR SDK "LGASAPI"**. Prebuilt, closed source | Computes audio fingerprints on the device (`acrAudioOctetToFingerprint`) | `prov-lg.alphonso.tv`, `eulacheck.alphonso.tv`, plus ACR, lookup, location, recommendation, debug and clock servers whose names are provisioned at runtime |
| `usr/sbin/adoverlay-service` + `libalphonsoadoverlay.so` + `libaos.so.1.2.0` + `libshopping.so` | Alphonso "overlay ads SDK". Shows ads and shopping overlays on top of TV and HDMI, keyed on the ACR result | No (uses the ACR result) | `config-overlay-ads.alphonso.tv`, an encrypted config through SDP, interactive URLs |
| `usr/sbin/livepick-plus` (`com.webos.service.livepickplus`) | LG "Shoptime" Video-ACR and food-delivery overlay scheduler | No. It polls `com.webos.service.acr/getContentProperty` for TMS IDs | `aic-ngfts.lge.com` (GFTS JSON) |
| Apps `com.webos.app.acr{component,overlay,hdmi1-4}` | Invisible "LivePlus" web containers. They open `contentTarget` (a remote URL) over live TV, HDMI or component input | No | URL chosen by the ACR solution |
| Apps `com.webos.app.ad{overlay,hdmi1-4}` | Ad overlay containers. They open `interactiveUrl` | No | URL from Alphonso overlay SDK |
| Apps `overlaycontainer*`, `fooddelivery*` | Video-ACR and food overlay containers | No | `https://aic.videoacr.lgtvcommon.com/`, `https://aic.fooddelivery.lgtvcommon.com/` |
| `usr/sbin/user-context-manager` | Logs app, channel and set-top-box usage and uploads it (viewing history) | No (metadata) | LG SDP / RIC servers via `sdx` |
| `usr/sbin/admanager` | LG home, launcher and screensaver ad client (IFA, LMT, DNS) | No | ad server from SDP, `info.lgsmartad.com` |

**No other ACR vendor was found.** Samba TV, Gracenote ACR, ACRCloud, Inscape, iSpot, Nielsen, Kantar and Verance
are all absent. `images.sports.gracenote.com` appears only as a sports image host. The ATSC 3.0
`audioWatermark/videoWatermark/audioFingerprint/videoFingerprint` strings in `interactive-content-api-server` are
the A/344 `org.atsc.query.contentRecoveryState` response fields. They are not a detector.

---

## 1. Capture: what is captured, how, and from which sources

### 1.1 acr2: audio capture (main path for Alphonso)
- [OBS] `usr/sbin/acr2` links `libasound.so.2` and imports `snd_pcm_open`, `snd_pcm_hw_params_set_rate_near`,
  `snd_pcm_hw_params_set_channels` and `snd_pcm_mmap_readi`. Classes: `capture::AlsaAudioWrapper` and `capture::AudioCapture`.
- [OBS] ALSA device string: `dsnoop:0,12`. This is a snoop tap on the TV's mixed audio output path, so it captures
  what the TV is playing. It does not use a microphone.
- [OBS] Audio parameters come from a remote XML config. The keys are: `capture_audio_capture`,
  `capture_audio_samplerate`, `capture_audio_channels`, `capture_audio_duration`, `capture_audio_sleep`,
  `capture_audio_format`, `capture_audio_option`, `pcm_option` and `sample_rate`. The firmware ships no default
  values, so the **sample rate and duty cycle cannot be recovered statically**. libas supports
  `ASAPI_SAMPLE_RATE_8K … 192K`. The Alphonso server can override `sample_rate` through `v5/acr_fp_config`
  ("sample_rate is absent in fp config response", "set value of sample_rate to").
- [OBS] Alphonso SDK fingerprinting runs on the device. Imports and strings: `acrInitialiseFingerprinter`,
  `acrFingerprinterCreateSession`, `acrAudioOctetToFingerprint`, `kiss_fftr`, `as_resample_*`,
  `AlphonsoBelowAvgPwrFP`. The upload carries fingerprints (`payload`, `v3_fps_payload`, `v3_frames_payload`).
  [INF] Raw audio does not appear to be uploaded. The upload consists of FFT-derived fingerprints.
- [OBS] The libas timing knobs are all provisioned by the server: `wakeup_interval`, `id_attempt_sleep_interval`,
  `id_attempt_sleep_interval_livetv`, `id_attempt_sleep_interval_dvr`, `id_attempt_timeout_ms`, `id_retries`,
  `capture_prepare_interval`, `acr_fp_mode`, `acr_fp_skip_count`, `power_optimization_mode`,
  `power_controls_weekdays`, `fp_upload_request_timeout` and `lookup_request_interval`.
- [OBS] The SDK also contains a microphone source (`UtilsMicReader`, "Audio source as microphone."). [INF] On this
  TV, acr2 feeds the SDK buffers from `dsnoop:0,12`, so the mic path appears unused. There is no evidence that acr2
  opens a microphone device.

### 1.2 acr2: video frame capture
- [OBS] acr2 links `libvtcapture.so.1` and has the classes `capture::VideoCapture`, `VideoCaptureBuffer` and
  `ImageConverter`. Log strings: "[VideoCapture] FPS = %d", `SetCaptureOneShot`,
  "[ImageConverter] DumpCaptureBMP". The capture path refuses scrambled, CI+, ATSC 3.0, analog, LG Channels and
  "blocked" channels. That is a content-protection policy, not a privacy policy.
- [INF] Video capture serves LG's own "Video ACR" (Shoptime and food overlays, `aic.videoacr.lgtvcommon.com`).
  Alphonso works on audio. The FPS and resolution come from the downloaded config, so they cannot be recovered
  statically.

### 1.3 Sources covered
- [OBS] Live tuner: acr2 subscribes to `getCurrentChannel` / `getChannelState` (UTP broadcast).
- [OBS] HDMI and component inputs: `OnInputSourceInfo : current_input input_name ...`. **It also collects the
  connected device's identity**: HDMI-CEC OSD name and type, UEI brand and type, and the SPD InfoFrame
  manufacturer, type and description (for example "Roku", "PS5", or a cable box model).
- [OBS] LG Channels (FAST) and VOD: no audio capture, but **metadata is passed to the solution directly**: cpId,
  channelId, channel name and number, programId, title, genre, rating, start and end time, seriesId, season and
  episode.
- [OBS] Foreground app: `current app info : is_foreground, input_source, input_source_app, foreground_app`, and
  "send ott info".

---

## 2. Endpoints and data sent

| Host / route | Component | Purpose | Data (from format strings) |
|---|---|---|---|
| `prov-lg.alphonso.tv` | libas | Provisioning. Returns the ACR, lookup, clock, recommendation and debug server names plus all timing knobs | `?device_id=`, `&country=`, `&ipaddr=`, `&zipcode=` [OBS] |
| `eulacheck.alphonso.tv` (`/countryList`) | libas | Which countries require which EULA | country |
| ACR server (provisioned) | libas | Upload audio fingerprints | `payload`, `v3_fps_payload`, `v3_frames_payload`, `ts_start`/`ts_end`, device id |
| `/user/lookups`, `/user/timed-lookups` | libas | Results lookup: what was identified | device id |
| `/user/location` | libas | Location update | `zipcode`, `country_code`, `longitude`, `locationType` [OBS] |
| `/recommendation`, `/recommendation/info` | libas | Recommendations, including OTT recommendation feedback | — |
| `/device/clock?&device_request_time=` | libas | Clock-skew sync, so fingerprints align with broadcast schedules | time |
| debug server (provisioned) | libas | `AS_DEBUG_SERVER_RESPONSE` | unknown |
| `config-overlay-ads.alphonso.tv` | adoverlay-service | Ad-overlay config | IFA, IFA type, LMT, DNS [OBS `OnIfa`] |
| LG SDP via `com.webos.service.sdx` (`/requestACRVersion`, `ACR_VERSION_DOWNLOAD`) | acr2 | Downloads `acr.xml`: `solution_lib`, `solution_token`, all capture parameters | device auth (sdx-signed) |
| `aic.videoacr.lgtvcommon.com`, `aic.fooddelivery.lgtvcommon.com` | overlay and food apps | Overlay web content keyed to the identified content | TMS id of the identified program [INF from URL params] |
| `http://aic-ngfts.lge.com/fts/gftsDownload.lge?biz_code=LGSHOPPING...` | livepick-plus | Shopping and food overlay service JSON. **Plain HTTP**, no TLS | IP, request |
| LG SDP via `sdx/send` | user-context-manager | **Viewing history upload**: app, channel and STB event logs since the last upload (`/mnt/lg/cmn_data/ucm/{app,channel,stb}_upload_time.txt`) | foreground app ids, channel ids/numbers, durations and timestamps |
| ad server via SDP, `info.lgsmartad.com` | admanager | Home, launcher and screensaver ads | IFA, LMT, DNS, frequency capping |

**Device and context parameters pushed to Alphonso** (acr2 → libalphonsosolution → libas, from the
`[ACR_SEND_INFO_LOG]` format strings) [OBS]:
- `menu_language`, `primary_audio_language`, `secondary_audio_language`, `country`
- `adid` (LG advertising id / IFA), `lmt` (limit ad tracking), `dns` (do not sell), `uuid`
- `os`, `os_ver`, `model_name`
- `provider`, `input`, `channel_name`, `channel_number`, `major_number`, `minor_number`
- `cec`, `spd` (connected device identity), `livetv`, `vod` metadata
- EULA flags: `general_terms_allowed`, `live_plus_allowed`, `interest_based_ad_allowed`, `data_partner_agreement_allowed`

[OBS] **LMT and DNS are passed to the vendor as flags.** The device keeps fingerprinting and sends the flags with
the data. Turning them on does not stop capture: `setDoNotTrack` / `setDoNotSellMyPersonalInformation` on
`AsapiDeviceIdParams`. Only the EULA and Live Plus gates (section 3) stop capture.

**Frequency.** Every interval is set by the server (`wakeup_interval`, `id_attempt_sleep_interval_livetv`,
`lookup_request_interval`, `AdId poll duration`, `power_controls_weekdays`), so it **cannot be determined
statically**. [INF] Published academic research on smart-TV ACR (IMC 2024, "Watching TV with the Second-Party") observed contact with
`alphonso.tv` roughly every 15 seconds while watching linear TV or HDMI with Live Plus on. Treat that figure as
external context, not something this firmware analysis proved.

**Server-controlled behavior.** The `solution_lib` field of the downloaded `acr.xml` picks which plugin acr2
`dlopen`s. The writable path `/mnt/lg/cmn_data/acr/lib/` exists alongside it. [INF] LG can therefore change or
swap the ACR vendor plugin from the server without a firmware update. The firmware analyzed here represents only
the *shipped* behavior.

---

## 3. Consent gates and settings

[OBS] Defaults in `etc/palm/defaultSettings.json`, before OOBE: all `eulaStatus.*Allowed` flags are `false`
(`acrOnAllowed`, `acrAdAllowed`, `additionalDataAllowed`, `customAdAllowed`, `marketingOnAllowed`,
`voiceAllowed`, `remoteDiagAllowed`, `thirdPartySharingAllowed` …) except `networkAllowed: true`. In the
`option` category `livePlus` is `off` and `livePromotion` is `on`. In `general`, `lmt` is off,
`doNotSellMyPersonalInformation` is off and `adCookie` is on. **Accepting the "agree to all" screen during setup
flips these to true.**

| Gate (settings key) | Checked by | Effect |
|---|---|---|
| `eulaStatus.generalTermsAllowed` | acr2, adoverlay, admanager, livepick-plus | Master gate: without it nothing ACR or ad related runs |
| `eulaStatus.acrOnAllowed` ("Viewing Information" agreement) [INF on the menu mapping] | acr2 (`EulaLivePlusAllowed`), livepick-plus, adoverlay | Without it there is no capture, no Shoptime/food overlay and no ad overlay |
| `option.livePlus` (menu: General → System → Additional Settings → Live Plus) | acr2 `IsLivePlusOn` | Second capture gate |
| `eulaStatus.acrAdAllowed` / IBA ("Interest-Based Advertising") | acr2 → solution `interest_based_ad_allowed` | Passed to Alphonso. [INF] Controls ad targeting, not capture |
| `eulaStatus.additionalDataAllowed` | user-context-manager | Gates the viewing-history upload (`No additionalDataAllowed field`) |
| `eulaStatus.customAdAllowed` | admanager, adoverlay | Personalized home/overlay ads |
| `eulaStatus.marketingOnAllowed` | livepick-plus | "Prime Time" / reservation notice-bar promos |
| `option.livePromotion` (default **on**) | adoverlay, livepick-plus | Overlay promotions |
| `general.lmt`, `general.doNotSellMyPersonalInformation` | acr2, admanager, adoverlay (registered as a "ccpa_change" activity that restarts ACR) | Flags only, see section 2 |
| `general.adCookie` (default **on**) | admanager | Ad cookie |

[OBS] When the EULA is withdrawn, acr2 writes opt-out marker files (`SetOptoutFilesByEula`,
`/mnt/lg/cmn_data/acr/data/{first_optout,intensional_off,eula_disallowed_rebooted}`). This is consistent with it
honoring withdrawal at runtime.

---

## 4. Startup and runtime cost

- [OBS] `etc/palm/activities/com.webos.service.acr/activity-com.webos.service.acr.start.json` calls
  `luna://com.webos.service.acr/startAcr` once `bootManager` reports `rest-boot-done`, on every boot. acr2 also
  re-registers on EULA, Live Plus and CCPA changes.
- [OBS] "ACR service as dynamic for eula allowed": when the EULA is not allowed, acr2 is expected to terminate
  ("ACR Service terminated"). With consent given, acr2 runs continuously with audio capture, FFT fingerprinting,
  a video capture thread, an image converter thread and HTTPS uploads.
- [OBS] **Debug-level logging in production:** `etc/pmlog.d/acr.conf` sets context `acr` to `"level":"debug"`
  with `logToConsole: true`, written to `/var/log/acr.log` (5 rotations). The log includes channel names,
  titles, connected device names and the adid in `[ACR_SEND_INFO_LOG]` lines. That is a CPU and flash-write cost,
  and a local privacy artifact.
- adoverlay-service, livepick-plus, admanager and user-context-manager are separate always-running daemons
  (upstart / luna dynamic). The hidden overlay web apps (acr*, ad*, overlaycontainer*, fooddelivery*) are
  launched by SAM when a TMS id matches, which spins up a Chromium renderer over your content.

---

## 5. Mitigations

**No root needed (do these first):**
1. Settings → General → System → Additional Settings → **Live Plus: Off**.
2. Settings → Support → Privacy & Terms → **User Agreements**: withdraw **Viewing Information**,
   **Interest-Based Advertising** and **Voice Information**. Leave Terms of Use/Privacy Policy accepted only if you
   want LG apps and the store, since `generalTermsAllowed=false` disables the ACR/ad stack completely but also the
   LG Content Store and some apps.
3. Settings → Support → Privacy & Terms → **Limit Ad Tracking: On** and **Do Not Sell My Personal Information: On**
   (flags only, but they stop IFA-based targeting). Turn off **Live Promotion** / "Home Promotion" where shown.
4. Settings → General → System → Additional Settings → Home Settings: turn off **Home Auto Launch** and
   **Home Promotion** / "Content Recommendation".
5. DNS block (router or Pi-hole): `prov-lg.alphonso.tv`, `eulacheck.alphonso.tv`, `config-overlay-ads.alphonso.tv`,
   `aic.videoacr.lgtvcommon.com`, `aic.fooddelivery.lgtvcommon.com`, `aic-ngfts.lge.com`, `qt2-ngfts.lge.com`,
   `info.lgsmartad.com`, plus the ad hosts in `blocklist.txt`. Do **not** block all of `lgtvsdp.com`: the store,
   apps and sdx authentication need it.

**Rooted TV (e.g. webosbrew), via a startup script in `/var/lib/webosbrew/init.d/`:**
- `luna-send -n 1 luna://com.webos.service.settings/setSystemSettings '{"category":"option","settings":{"livePlus":"off","livePromotion":"off"}}'`
- Stop the daemons: `stop admanager` (upstart), and `pkill -f usr/sbin/acr2` / `adoverlay-service` /
  `livepick-plus` / `user-context-manager` after boot. Luna will relaunch these on demand, so killing alone is weak.
- More robust: an empty file at `/mnt/lg/cmn_data/acr.xml` made immutable or read-only (so the config download
  fails and acr2 gets no `solution_lib`). [INF] Untested.
- Reduce ACR logging: copy `etc/pmlog.d/acr.conf` with `"level":"err"` via a bind mount from a writable path.
- What breaks: Shoptime/food overlays and some "LG Channels" promos (desired). Normal TV, HDMI and apps are unaffected.
