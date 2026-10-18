# LG OLED55CXPUA (webOS 5.6.2, fw 04.64.00, US) – privacy deep dive

Second pass over the privacy side. It covers only what `telemetry.md`, `acr.md`, `endpoints.md` and `ui_apps.md` don't:
identifiers, data kept on the TV, factory reset, transport security, how consent is enforced, what LG's servers can
trigger, location and sensors, and what store apps and web pages can reach.

Static analysis only; nothing was run on a TV. Binary claims come from string tables and, where marked, Thumb-2
disassembly (capstone) of the named binary. Paths are relative to `rootfs.pak.unsquashfs/`. `O/` =
`otncabi-atsc.pak.unsquashfs/usr/palm/applications/`.
Tags: **[Observed]** = read in a file, string or disassembly. **[Inference]** = conclusion, not confirmed on a TV.

---

## 0. Headline findings

| # | Finding | Section |
|---|---|---|
| 1 | **ACR traffic is not authenticated.** The Alphonso SDK turns off TLS certificate and hostname checks in all 19 of its API classes, including fingerprint upload and location. Its provisioning server can also switch it to plain HTTP | §4.1 |
| 2 | **ACR locates the home from nearby Wi-Fi.** acr2 hands the BSSID and signal strength of every access point the TV can hear, neighbors' included, to Alphonso's location service, which returns lat/long and zip | §6.1 |
| 3 | **The device ID can't be reset.** The LGUDID lives on a raw eMMC partition that factory reset never touches. The "hashed MAC" is an unsalted SHA-512 of the MAC string, so it is reversible | §1 |
| 4 | **Store apps can likely read the permanent IDs.** `deviceid/getIDs` (LGUDID, NDUID, SDI, hashed MAC, ad ID) is in the `public` group, which partner-trust store apps may request. Resetting the ad ID therefore doesn't stop cross-app tracking, and LG can link old and new ad IDs anyway | §1.2 |
| 5 | **Factory reset keeps a lot.** Viewing history lives in the main db8 partition, which the reset scripts don't wipe (inferred; check on a TV). Bluetooth pairings, marketing-consent history and per-channel watch time are kept on purpose | §2.3 |
| 6 | **Wi-Fi password storage is reversible.** It is Blowfish-encrypted with the hard-coded key `"com.webos.service.wifi"` | §2.2 |
| 7 | **sdx's bootstrap is unverified.** Requests sent before the device is authenticated, and the download of the server-domain list, skip certificate checks. One forged answer could plausibly repoint every LG cloud service for good | §4.2 |
| 8 | **Consent is bundled.** Netflix, YouTube and 75 other apps require the same agreement that switches on LG's crash and analytics uploads. Google Assistant and Alexa require Viewing Information | §5.1 |
| 9 | **LG's server decides what gets logged.** It sets flags per device that turn Live TV/HDMI watch logging on (RF, IP and set-top box via ACR/SCD/UEI). The only consent check sits in the Live TV app's QML, not in the uploading daemon | §5.2 |
| 10 | **Analytics collected with only the Terms of Use accepted:** your Home Dashboard device names (daily), your phone's Bluetooth name, remote key-press counts | §6.2 |
| 11 | **Secrets logged at info level** into `/var/log`, which crash reports upload: the ThinQ OAuth refresh token and the HomeKit password | §2.4 |
| 12 | **The LG browser is the leakiest app.** It makes its whole profile (cookies, history, saved passwords) world-readable and world-writable on every launch ("temp code for security issue"), sends Bing search suggestions over plain HTTP, and includes the failing page URL in error reports | §7.2 |

---

## 1. Identifiers

### 1.1 What each one is **[Observed: `usr/sbin/securitymanager` disassembly; `getIDs` dispatch table at `0x4abb8`]**

| ID | How it is made | Where it is stored | Survives factory reset | Who can read it |
|---|---|---|---|---|
| **LGUDID** | UUIDv5(name = MAC string, namespace = random UUIDv4). The record also holds the **plaintext MAC** and a SHA-256 check value | raw eMMC `/dev/mmcblk0p10`, offset `0x3fc00`, outside any filesystem | **yes**, for the life of the TV. Only the debug commands `erase_lgudid` / `break_lgudid` remove it | anyone allowed to call `getIDs` |
| **HashedMAC** | `Base64(SHA-512("xx:xx:xx:xx:xx:xx"))`, **no salt**. MD5, SHA-1 and SHA-256 variants exist. The MAC is read from the kernel cmdline `ethaddr=`, the factory address | not stored | **yes** (the MAC never changes) | same |
| **NDUID** | SHA-1 over a model secret (`msk.enc`) and fixed device data that includes the MAC | `/var/lib/secretagent/nduid` | the file is wiped, but the value is deterministic and regenerates identically **[Inference]** | same |
| **SDI** | factory-provisioned key pair + ID, returned as a signed token | secure store | yes **[Inference]** | same |
| **IFA** (ad ID) | UUIDv5 with a fresh random namespace on each reset | `/var/lib/secretagent/IFA.txt` | rotated | same |
| MAC, HbbTV ID | raw MAC; SHA-512(MAC + origin + time) | — | — | callers whose names start with `com.palm.` / `com.lge.` / `com.webos.` only |

- **The hashed MAC is the MAC in practice.** LG owns a few dozen MAC prefixes (OUIs), so finding the MAC means trying about 2^24 hashes per
  prefix. sdx sends this value as `&hashedMacAddress=` with consent sync (`telemetry.md` §1.1).
- **Wi-Fi and Bluetooth MACs are never randomized.** No `mac_addr` / `preassoc_mac_addr` setting appears in the
  wpa_supplicant or connman configs. Probe requests carry the real address **[Observed absence]**.
- The **SSDP UUID** is random and rotates on reset (`ssdp-discovery-lgtv` writes `/mnt/lg/cmn_data/ssdplgtv/uuid`). The UPnP
  description probably also advertises the wired and Wi-Fi MACs to the LAN (`vendorDefined` list next to `wiredMac`/`wifiMac`)
  **[Inference]**.
- **Factory DRM identities** (`idfile`, `widevine`, `cert`, `marlin` partitions) are on raw partitions that no reset touches
  **[Inference]**.

### 1.2 Store apps and the permanent IDs **[Observed ACLs; reachability Inference]**
- `usr/share/luna-service2/api-permissions.d/compat.api.json` lists `com.webos.service.sm/deviceid/getIDs` and `getIDList` in the
  **`public`** group.
- `usr/share/luna-service2/allowed_groups.json`: `"part": ["partner.api", "public"]`. Apps at **partner** trust level may request that group.
- securitymanager withholds only the raw MAC and the HbbTV ID from non-LG callers (`strncmp` prefix checks at `0x1fcc8`–`0x1fcf4`).
- So a partner-trust store app can most likely read the LGUDID, NDUID, SDI, hashed MAC and IFA. None of these is scoped per app, and
  the first four never change. Which store apps run at partner trust can't be seen in the firmware. Confirm on a TV by watching
  `ls-monitor` while launching the big streaming apps.
- **Resetting the ad ID** (Settings › Reset Advertising ID → `getIDs {"idType":["IFAID"],"origin":"reset"}`) really does generate a new
  ID. But it logs `NL_SETTING_CHANGE {menu_name:"resetIFAId"}` to LG's analytics first, and ad requests carry `X-Device-ID` next to
  `&ifa=`. LG can therefore link the old and new IFA; the reset only helps against parties that see the IFA alone **[Observed /
  Inference]**.
- Other public-group methods that return device data: `tv.systemproperty/getSystemInfo` (model, firmware),
  `eim/getDeviceInfo` (connected HDMI devices), `dmost/getClientMacInfo` (MAC) and `membership/getPubValue` (LG account values).
- Web apps without luna access get nothing identifying: `PalmSystem.deviceInfo` returns model and display only, and
  `webOSSystem.getIdentifier()` returns the app's own ID.

---

## 2. Data kept on the TV

### 2.1 Where it lives and what is encrypted **[Observed: `etc/systemd/system/mount-readwrite.d/00-partinfo.ext4.fstab`]**
| Partition | Mount | Contents | Encrypted |
|---|---|---|---|
| `mmcblk0p55` | `/mnt/lg/cmn_data` (+ `/var`, `/home`) | service data, Wi-Fi profiles, WAM cookies/cache, logs spool | no |
| `mmcblk0p54` | `/mnt/lg/db8` | **main db8**: viewing history, nudge and contentminer history, notifications, credentials manager, second-screen pairings | no |
| `mmcblk0p56` | `/mnt/lg/appstore` (`/media`) | store apps, mediadb | `/media/cryptofs` only (eCryptfs, **file names not encrypted**) |

Behavioral db8 kinds include:
- `com.webos.service.usercontextmanager.{app,channel,stb,youtube}`: history with time, weekday and duration. The **`youtube`** kind
  stores YouTube **channel IDs**.
- `nudge.history`, `contentminer.{contents,personalKey}`, `notificationhistory`, `tvReservationAgent.history`,
  `app.music.recentplay` and `sportalert.contents`.

No fixed retention limit was found. `com.webos.statisticsManager.appLaunchHistory` has no service binary in this image, so it stays empty.

### 2.2 Wi-Fi passwords **[Observed: `usr/sbin/connmand` disassembly]**
`/var/lib/connman/<service>/settings` stores `Passphrase` as `Base64(Blowfish-CFB64(passphrase, key = "com.webos.service.wifi", IV = 0))`.
The helpers are at `0x6dee4` (encrypt) and `0x6df9c` (decrypt), called from storage save and load with that string as the key. Anyone who gets
the file, from root, a backup or an over-broad log bundle, can decrypt it. Use a Wi-Fi password the TV doesn't share with anything else.

### 2.3 What "Reset to Initial Settings" wipes **[Observed: `usr/sbin/devicereset`, `etc/systemd/system/scripts/mount-readwrite.sh:166-200`, `etc/configd/layers/base/tv.config.json` `protectListUserInit`]**

**Mechanism:**
- `devicereset` writes `user` to `/mnt/lg/cmn_data/firstmount` and reboots.
- On the next boot, `mount-readwrite.sh` runs `find /mnt/lg/cmn_data/ ! -path <protect list> -delete` and clears a short remove-list.
- `devicereset` also calls `nyx-cmd System erase_partition all`, but no nyx module ships (`usr/lib/nyx/modules/` holds only a
  sentinel), so that most likely does nothing.

**Wiped:** everything in `/var` and `/home` not on the protect list. That includes Wi-Fi profiles, WAM cookies and storage, `IFA.txt`, the
NDUID file, the SSDP UUID, UCM upload checkpoints, crash spools and ACR data.

**Not touched by the reset scripts:**
- **`/mnt/lg/db8`.** Nothing that clears UCM or db8 on reset was found; `usercontextmanager/reset` is called only from Settings › AI Service ›
  Reset usage data. **Whether viewing history survives a factory reset needs a test on a TV**; statically it looks like it does.
- Raw ID partitions (LGUDID, MAC, DRM).
- Installed store apps.

**Kept on purpose (protect list):**
- `sdp/sdx/eula.json`, `maketingAllowedDate.json`, `remindMaketingTerm`: consent and marketing-consent history.
- `btsvc/pairing_history`, `bluedroid-*/conf/bt_config.*`: previously paired phones and headphones, probably including link keys.
- `broadcast/legacy-broadcast_watchingTime.json`: per-channel watch time.
- Also `MagicSearchResult.txt`, `uploadd/*`, `network/*`, `tee/*`, `efs/*`, `settingsservice/*`, `db8/*`.

**For resale:** after a factory reset the TV keeps the same LGUDID, NDUID, SDI and hashed MAC, so LG's servers can link the new owner to
the old account history. It also keeps the old Bluetooth pairings, and possibly the viewing history. §8 has a rooted wipe procedure.

### 2.4 Secrets and identifiers in `/var/log` **[Observed format strings and PmLog levels]**
Crash bundles (rdxd) tar all of `/var/log` (`telemetry.md` §1.2), so these leave the TV with any crash report.

| Daemon | Logged at info | Log file |
|---|---|---|
| `iot-client` | `[%s:%d] refreshToken: %s`: the ThinQ OAuth refresh token, on a server error; plus `homeconnect account: %s(%s) is found` | `iot-client-log` |
| `homekit` | `Password Setting: Password = %s`: the HomeKit access password | `/var/log/messages` |
| `iconnectivity`, `pbs`, `irdbmanager` | zip code, and `ZIPCODE(%s), LGUDID(%s)` | messages / own |
| `panelcontroller`, `legacy-broadcast`, `tvservicemock` | the serial number | messages |
| `asc` | `ssid = %s` (debug-level context) | `asc-log` |

---

## 3. Corrections to earlier findings

- **`telemetry.md` §1.10 says `remotediag` runs at boot.** Its only boot launcher is the upstart job `etc/init/remotediag.conf`, which systemd never reads
  (`performance.md` §0). It is started on demand through `usr/share/dbus-1/system-services/com.webos.service.remotediag.service`, i.e. when the
  Remote Service app or another caller uses it **[Observed]**.
- **`telemetry.md` §5.2's mitigation `systemctl stop remotediag`** has nothing to stop at boot. To block on-demand starts, bind-mount `/dev/null` over the
  dbus service file, as `performance.md` R5 does for ACR.

---

## 4. Transport security

**Method:** every `curl_easy_setopt` call site in the phone-home binaries was located and its constant option and value recovered with capstone.
The options are `CURLOPT_SSL_VERIFYPEER` = 64 and `CURLOPT_SSL_VERIFYHOST` = 81. `CURLOPT_PINNEDPUBLICKEY` (10230) is never used.

| Component | Carries | Certificate check |
|---|---|---|
| **Alphonso ACR SDK** (`usr/lib/libas.so.3.0.93`) | provisioning, fingerprints, location, user registration, recommendations, log upload | **off**: VERIFYPEER=0 and VERIFYHOST=0, constant immediates, in all 19 `*API::execute` |
| **Alphonso overlay ads** (`libaos.so.1.2.0`) | ad overlay config/serving | **off** (0/0) |
| **sdx** | LG cloud broker | **off until it holds an auth token; always off for the server-domain list**; on (1/2) afterwards |
| **admanager** | ad requests and trackers (IFA, LMT/DNS) | chain checked, **hostname not** (VERIFYHOST=0) |
| **PmLogDaemon** | analytics whitelist download | **off** (VERIFYPEER=0) |
| update, uploadd, pbs, livepick-plus, iot-client, libshopping | firmware, crash uploads, guide, shopping, ThinQ | on (1/2) |
| remotediag | LG remote support | pinned to a self-signed `usr/share/remotediag/server.pem` |
| care365 (Node, Azure IoT) | remote care | on (amqp10's `rejectUnauthorized:false` default is replaced at runtime) |

### 4.1 Alphonso **[Observed]**
- Example: `ACRFPConfigFetchAPI::execute` sets `movs r2,#0; movs r1,#0x40` and `movs r2,#0; movs r1,#0x51` at `0x9da50`–`0x9da60`.
  The other API classes do the same, including **FPUploadAPI**, **LocationAPI**, **ProvServAPI**, **UserRegAPI** and **SendBulkLogsProviderAPI**.
- Provisioning responses also carry per-server `insecureFlag` fields (`acr_insecure_server`, `acr_server_port_nossl`,
  `bulk_dump_log_server_insecureFlag`, …), so the server can move the SDK to plain HTTP.
- **What this means:**
  - Anyone in the network path can impersonate `prov-lg.alphonso.tv` with any certificate.
  - From there they can receive the device ID, IFA, IP, zip, lat/long, channel and HDMI device names, and the fingerprints.
  - Provisioning names every other Alphonso server, so one forged response redirects all of it **[Inference]**.
- Only reachable while ACR consent is given. Declining Viewing Information and turning Live Plus off is the complete fix.

### 4.2 sdx bootstrap **[Observed disassembly; attack chain Inference]**
- **The code:** `SDPHandle::_set_curl_opt` (`0x5f68c`) sets VERIFYPEER=1 / VERIFYHOST=2 only when `HTTPHeaderManager::get_authentication()` returns a
  token. On the empty-token branch, both are set from the previous call's return value, which is 0 (`0x5fa8e`–`0x5faa4`).
  `SDPServerDomainHandle::set_curl_opt` (`0x5f01a`–`0x5f030`) always sets 0/0.
- **Where the domain list goes:** the list it downloads is saved to `/mnt/lg/cmn_data/sdp/sdx/server_addr_version.conf` and maps every SDP service
  name to a host. sdx imports no signature-verification function.
- **Plausible chain:**
  1. An attacker intercepts an unauthenticated bootstrap and answers it.
  2. They point the domain list at their own domain. The list persists across reboots.
  3. Every later "verified" sdx request then goes to that domain and passes with a free certificate, because LG's CA bundle includes ISRG Root X1.
  - That would expose consent sync, app-store traffic, the `acr.xml` config (whose `solution_lib` field names the library acr2 loads) and the
    analytics whitelist URL.
- **Unconfirmed:** whether sdx limits domains to LG suffixes, and whether the first request of each session really goes out before a stored
  token is loaded.

### 4.3 CA bundles and shared keys **[Observed]**
- **No pinning anywhere** except remotediag.
  - `usr/share/ca-certificates/sdp/sdp-ca.pem` ("LG's" bundle) holds **222 unique roots, 67 expired**. It includes roots browsers have distrusted:
    CNNIC, Certinomis, Camerfirma, E-Tugra, Hongkong Post Root CA 1, and the VeriSign/thawte/GeoTrust Symantec family.
  - The system bundle still has TrustCor ECA-1.
  - Wherever verification is on, any of these CAs can issue a passing certificate.
- **Private keys identical on every TV** (fingerprints only):
  - `usr/share/google-assistant-adapter/device_attestation_key.pem`: EC P-256, Google Assistant device attestation, cert `CN=LG webOSTV`.
    Fleet-wide, so it is not a tracking ID, but it is not a per-device secret either.
  - RSA-2048 in `libdile_crypto.so.0.1.1` (labeled FreeView Play) and in `liblblisten.so.1.0.0` (DLNA).
  - The Open webOS SDK SSH key (`com.palm.service.devmode/.pc/…/ssh/webos`), installed as `authorized_keys` in Developer Mode. Already public; only
    matters while Developer Mode is on.
- **Plain HTTP that an attacker could rewrite without any certificate:**
  - The shopping-overlay config at `aic-ngfts.lge.com`, which supplies the service URL for web apps drawn over live TV.
  - The Remote Service terms XML.
  - EPG channel and genre images (`ngfts.lge.com`). These are decoded by libwebp 1.0 / freetype 2.9.1, which have known heap CVEs, in apps running
    as root or under WAM's `--no-sandbox` **[Inference: exploitability]**.
- Firmware updates **can't** be tampered with: the check is over verified TLS, and images are RSA-signed (`SWUPDATE_VerifyImage`).

---

## 5. Consent: what it really controls

### 5.1 Bundled agreements **[Observed: appinfo.json `requiredEULA`; group definitions in `com.webos.app.eula/main.js`]**
- **77 apps require `generalTerms`** (Terms of Use + Privacy Policy, documents `S_SVC, S_PRV, S_PRD`). They include Netflix, YouTube, Prime, Hulu,
  Disney+, Apple TV, Vudu, Spotify, Twitch, LG Channels and Remote Service. SAM won't launch them until it is accepted.
  The same `generalTermsAllowed` flag gates crash and log upload, basic PmLog analytics, iot-client registration, contentminer and
  sportsalarm. **Using any streaming app implies accepting LG's crash and analytics uploads**; only a rooted TV can separate them.
- **`google.assistant`, `amazon.alexapr` and `amazon.alexa.view` require `voice2`**, whose mandatory list includes `S_ADC, S_ADD`, the
  **Viewing Information** pair. Turning on either third-party assistant therefore also turns on:
  - the user-context-manager viewing-history upload
  - the full analytics whitelist
  - button-click logging

  LG's own `voice` group doesn't include them.
- `customAd` (interest-based ads) also requires Viewing Information.

### 5.2 Live TV/HDMI watch logging is switched by the server **[Observed: `com.webos.app.inputcommon/qml/Model/PersonalDataLogModel.qml`, `usr/sbin/pbs` strings]**
- **Server flags:** at authentication the IBS server (`*.ibsstat.lgappstv.com`) returns `watch_flag`, `ip_watch_flag`, `stb_acr_watch_flag`,
  `stb_scd_watch_flag` and `stb_uei_watch_flag`.
- **What they control:** these turn per-channel watch logging on for the tuner, IP channels and set-top-box inputs (with the box identified by ACR,
  SCD or UEI). Set-top-box logging is enabled for `KOR` and `USA` only.
- **Upload:** `livetvwatch.json` carries the device ID, timezone, **zip code** and channel codes, sent after a random delay of up to 10 s.
- **Consent check:** the only one is `if (!livetvwatchEula) return;` in the QML app. The comment there says the daemon blanks the device ID when
  consent is missing.
- So which sources get logged is decided per device by LG's server, and the consent check is in a UI app.

### 5.3 Server switches and endpoint moves **[Observed: `sdp_secure` `services` → `itemList[{name, switch}]`]**

| Switch | Effect |
|---|---|
| `auto_home_launch` | server overwrites `homeAutoLaunch` unless `checkHomeAutoLaunchValue` is `"user"` (known, `ui_apps.md`) |
| `avmsd` | **server hides the Home Auto Launch menu item**, removing the user's control as well as changing its value |
| `home_effect`, `nudge_service`, `search_recommendation`, `music_discovery`, `channel_plus`, `rdp_service`, `efs_service`, `streaming_live_tv` | feature toggles |

The same response feeds `_updateServerDomain`, so **the server can move sdx's endpoints** **[Inference]**. A DNS blocklist of today's hostnames is
therefore not a durable control. "Network-Based Personalization: Off" only adds an `X-Device-Personalization` request header; the same requests are
still made.

### 5.4 Consent reporting, re-prompts and pre-consent traffic **[Observed strings; timing Inference]**
- **Withdrawal reporting:** withdrawing consent is reported to LG (`deviceinfo?terms=…&lgudid=…&hashedlgudid=…`).
- **Pre-agreement MAC registration:** the initial state sends `deviceinfo?terms=initial:initial&mac=…`, registering the MAC before anything has been
  agreed. Whether that happens before the agreement screen needs a capture.
- **Re-prompts:**
  - A terms update brings up a full-screen re-agree overlay with "Back" instead of "Later".
  - Declined marketing consent is re-asked later through a scheduled toast (`maketingAllowedDate.json`, "within 2 years").
- **Before consent, the TV also:**
  - sets its clock from LG's server without authentication ("Set Server Time (without authentication)");
  - fetches the server feature switches;
  - looks up state/city/postcode through LG's IBS server during setup.

---

## 6. Location, sensors and the home network

### 6.1 Wi-Fi geolocation through ACR **[Observed: `usr/sbin/acr2`, `libalphonsosolution.so.1.0.0`, `libas.so.3.0.93`]**
- **Collection:** acr2 subscribes to `luna://com.webos.service.wifi/findnetworks` and maps each `bssInfo[].bssid/signal` to `mac_address` /
  `signal_strength`. It passes the list to `LGASAPI::updateWifiScanInfo`.
- **Upload:** the SDK (`UtilsReadWifiProperties`, `sortBySignalStrength`, `LocationClient() with lat/long and wifiScanOutput`) sends it to Alphonso,
  which replies with `latitude`, `longitude` and `ZipCode`.
- **Switch:** it is enabled per device by the provisioning flag `enable_wifi_scan`.
- **Result:** the lat/long in ACR traffic is computed from your public IP plus every access point the TV can hear. That is usually accurate to tens of
  meters, i.e. roughly your street address **[Inference]**.
- **How to stop it:**
  - Decline Viewing Information and turn Live Plus off.
  - On a wired TV, also turn Wi-Fi off so there are no scan results.
  - Rooted: killing acr2 (`50scrub`) covers it.

No other Wi-Fi geolocation (Google, Skyhook) is used anywhere else in the image.

### 6.2 Analytics with only the Terms of Use accepted **[Observed: PmLogDaemon picks `whitelist_basic.txt` when only `generalTermsAllowed` is set]**

| Event | Content |
|---|---|
| `NL_HC_DEVICELIST` (Home Dashboard, every 24 h) | every known device's type, protocol and **the name you gave it** |
| `NL_BT_SNK_CONNECT_STATE` (`btaudiosnk`) | `{"connect_state","device_name"}`: **your phone's Bluetooth name** when the TV is used as a speaker |
| `NL_BUTTON_CLICK`, `NL_PAIRING_CHECK` (`lginput2`) | remote key code with a running count, remote model, pairing events. lginput2 also checks `additionalDataAllowed`, so this may wait for that agreement **[Inference]** |
| `NL_HC_EVENT_USB` | USB actions (not file names) |

### 6.3 Other sources **[Observed]**
- **UEI QuickSet:** sends CEC and EDID signatures of HDMI devices with an online unique ID. Its LAN subnet/SSDP/mDNS scan is turned off on this model
  (`Skip, Disable IP Discovery on webOS5.0`).
- **iot-client:** reads OCF lock, temperature, humidity and switch state from ThinQ devices on the LAN when an account is linked.
- **USB webcams and mics:** they work (`CONFIG_USB_VIDEO_CLASS=y`, `CONFIG_SND_USB_AUDIO=y`). WAM grants capture to any web app whose manifest
  declares `allowVideoCapture` / `allowAudioCapture`, with **no user prompt** **[Inference: webOS OSE semantics]**. No built-in app declares them.
- **Clean or inert:**
  - Music recognition calls a service that isn't in the image.
  - AI Acoustic Tuning records through the remote's mic but sends nothing.
  - No USB file names are uploaded.
  - BLE setup advertising (`asc`) is off by default.
- **DevTools (port 9998):** `libcbe.so` binds `0.0.0.0` and checks `devmode_enabled`, so it is most likely LAN-reachable only in Developer Mode
  **[Inference]**.

---

## 7. Apps and the browser

### 7.1 Third-party SDKs: none in the firmware **[Observed]**
- **Search:** one grep for about 40 analytics and ad vendors over all partitions found only false positives: Xumo mock data, an OCR dictionary, the OUI
  table, Chromium's built-in Google host list, and the browser's UA-spoof list. No analytics package is in the 43 bundled `node_modules`.
- **Content apps aren't in the image.** Every content partner app is a `type:"stub"` placeholder. The real app and its SDKs come from the LG store,
  outside the image.
- **What is in the image:**
  - `com.webos.app.adapp` is a hidden, prerendered, trusted ad-rendering app; all its reporting goes through admanager.
  - **admanager:** LMT and Do Not Sell only switch frequency capping (`Frequency capping enabled. DNS = %s, LMT = %s`). Impression and click trackers
    fire either way. The cookie jar persists in `/mnt/lg/cmn_data/admanager`. **Home Promotion off is the real ad switch.**
  - **`dmost`:** runs at every boot and reads the IFA, LGUDID and MACs, yet logs `M2R is NOT supported in Canada and USA.` On a US set it does nothing
    useful.

### 7.2 LG browser **[Observed: `O/com.webos.app.browser/run_webbrowser`, `share/*.json`, `libcbe.so`]**
- **Open profile:** `chmod -R 777 ${CHROME_CACHE}` under the comment `# temp code for security issue`, on every launch. The profile under
  `/mnt/lg/cache/webbrowser/chrome` (cookies, history, form data, saved passwords) becomes readable and writable by every process on the TV.
- **Weak launch flags:** `--no-sandbox`, `--ssl-version-min=tls1` (TLS 1.0 allowed), `--prerender=enabled`,
  `--safebrowsing-disable-download-protection`, `--always-authorize-plugins`.
- **Plain-HTTP search suggestions:** 41 of the 48 search-suggestion URLs are plain HTTP. In the US that matters for **Bing**
  (`http://api.bing.com/osjson.aspx?query={searchTerms}`): what you type goes out in cleartext. Google and Yahoo suggestions use HTTPS.
- **Error reports:** sent to `lgtvbrowser.lgtvsdp.com` (`ErrorReport::Request(GURL, …)`), including **the URL of the failing page** with device info.
  Gated by a first-use prompt and a server switch.
- **Chromium 68 defaults:** third-party cookies are allowed; WebRTC exposes local IPs to pages (no mDNS masking before Chromium 76); DNT is off.
  The UA (`… SmartTV/9.0 Crow/1.0`) carries no model or serial **[Inference for defaults]**.
- The launcher also sources `${CACHE_DIR}/extra_conf`. That file sits one level above the world-writable directory, so it isn't writable by others
  unless the parent is.

### 7.3 Possible LAN takeover through a web app **[Observed config; Inference]**
- **The allow-list:** `etc/wam/security_policy.conf [Allowed]` lets every web app read
  `/var/preferences/com.webos.service.secondscreen.gateway/userinfo/`.
- **The key in the filenames:** the second-screen gateway names its per-client files with the pairing **`clientKey`** as a prefix
  (`client-profile-manager.js`). That key is the bearer token for the port-3001 remote-control API.
- **The risk:** if a packaged web app can list that directory, it can learn valid keys and control the TV over SSAP without a pairing prompt. Needs a
  test on a TV.

---

## 8. Mitigations

### No root (adds to `REPORT.md` Tier 1)
1. **Accept only Terms of Use.** Decline Viewing Information, Interest-Based Ads and Voice Information.
2. **Don't enable Google Assistant or Alexa** (§5.1). LG's own voice doesn't need Viewing Information.
3. **Wired TV:** turn Wi-Fi off (§6.1).
4. **Neutral names:** give your phone a non-personal Bluetooth name before using the TV as a speaker, and use neutral names for Home Dashboard devices
   and the TV itself (§6.2).
5. **Don't link ThinQ or HomeKit** (token and password logging, §2.4).
6. **Use a Wi-Fi password the TV doesn't share** with your other devices (§2.2), ideally on a guest or IoT network.
7. **Don't sign in to websites in the LG browser**, and pick Google or Yahoo, not Bing, for search (§7.2).
8. **Unplug USB webcams and mics** when not in use (§6.3).
9. **Keep the TV off untrusted networks** (hotel Wi-Fi, public hotspots); every item in §4 needs an attacker on the path.

### Rooted (in `scripts/50scrub` unless marked)
- `checkHomeAutoLaunchValue: "user"` pins Home Auto Launch against the server switch (§5.3).
- Stop `dmost` (§7.1).
- Lower `iot-client`, `ASC` and `HOMEKIT` logging to warning and remove old `iot-client` logs (§2.4).
- **Optional, off by default in the script:**
  - Bind-mount the shipped `usr/palm/sdx/server_addr_version.conf` over the downloaded copy, which blocks a persistent domain redirect (§4.2). Undo
    it if LG migrates domains.
  - Block on-demand `remotediag` starts (§3).
- **Not scripted:**
  - Removing `getIDs` from the `public` group (bind-mount an edited `compat.api.json`): this may break store login and DRM.
  - Emptying `whitelist_basic.txt`: untested whether LG's update overwrites it.

### Before selling or giving away the TV (rooted, after "Reset to Initial Settings", before setup; untested)
```sh
luna-send -n 1 luna://com.webos.service.usercontextmanager/reset '{}'      # viewing history in db8
rm -f /mnt/lg/cmn_data/btsvc/pairing_history /mnt/lg/cmn_data/btsvc/bluedroid-*/conf/bt_config.* \
      /mnt/lg/cmn_data/broadcast/legacy-broadcast_watchingTime.json /mnt/lg/cmn_data/MagicSearchResult.txt
du -sh /mnt/lg/db8/vardb/main    # what's left in the main db8
```
The LGUDID, NDUID, SDI and hashed MAC can't be rotated. Don't use the `erase_lgudid` debug command, because its effect on device authentication is unknown.

### DNS
- Add `api.bing.com` (optional; LG browser Bing suggestions only).
- `lgrecommends.lgappstv.com` is already listed; blocking it also breaks Google, Amazon and Facebook sign-in to the LG account.
- The Alphonso hosts, `ibsstat.lgappstv.com` and `aic-ngfts.lge.com` are already in `blocklist.txt`.

---

## 9. Open questions to settle on a TV
1. Does sdx's first request after boot complete through an intercepting proxy with an untrusted certificate (§4.2)? Does it accept a domain list naming a
   non-LG domain (lab DNS only)?
2. Does `/mnt/lg/db8` keep UCM records after "Reset to Initial Settings"?
   `luna-send -n 1 luna://com.palm.db/find '{"query":{"from":"com.webos.service.usercontextmanager.app:1"}}'`
3. Which store apps run at partner trust, and do they call `deviceid/getIDs` (`ls-monitor`)?
4. Does the IBS auth response set `watch_flag` / `stb_*_watch_flag` true for a US set with Viewing Information declined?
5. Is `deviceinfo?terms=initial:initial&mac=` sent before the agreement screen?
6. Can a packaged web app list the second-screen `userinfo/` directory (§7.3)?
7. Does acr2 check the `solution_lib` it is told to load (SHA512 is imported)?
8. Is `mmcblk0p10` the `macadr` or `env_nvm` partition (`cat /proc/partinfo`)?
