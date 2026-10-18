# LG OLED55CXPUA (webOS 5, fw 04.64.00, o20/ATSC): telemetry, logging and phone-home audit (non-ACR)

Scope: a static review of the decrypted firmware, covering telemetry, analytics, crash/log upload, device IDs, update checks, voice, IoT, ads/IFA, LAN exposure and logging verbosity. ACR (acr2, alphonso, `videoacr.lgtvcommon.com`) is covered elsewhere and only mentioned in passing here.

Method: I used `strings`, `rg` and Python (`-I`) parsing of configs, and executed nothing from the firmware. Paths are relative to `rootfs.pak.unsquashfs/` unless noted.

Legend: **[O]** means I saw it directly (quoted string, config line or script). **[I]** means I inferred it from naming or context; it is likely but not proven statically.

---

## 0. Executive summary

* **Everything goes through one cloud: LG SDP/SDX (`*.lgtvsdp.com`, `*.lgtvcommon.com`, `*.lgappstv.com`, `*.lgtviot.com`).** `com.webos.service.sdx` is the gatekeeper. It authenticates the device using an encrypted MAC, manages the consent ("EULA") state, and attaches a standard set of `X-Device-*` headers to almost every cloud request. That set includes `X-Device-ID`, `X-Device-Model`, `X-Device-Country`, `X-Device-FW-Version`, `X-Device-Eula` (the list of accepted terms) and `X-Login-Session`. Most other daemons call `luna://com.webos.service.sdx/send` instead of talking HTTP themselves. **[O]**
* **Consent is enforced per daemon, not centrally.** Each daemon reads `eulaStatus.*Allowed` from settings. Factory defaults are all `false` except `networkAllowed: true` (`etc/palm/defaultSettings.json`). **[O]** In practice:
  * `generalTermsAllowed` (Terms of Use + Privacy Policy) gates crash and analytics upload (rdxd/uploadd), the *basic* PmLog analytics whitelist, firmware auto version checks, ThinQ/IoT and nudges.
  * `additionalDataAllowed` (US "Viewing Information" **[I]**) gates the *full* analytics whitelist, user-context-manager app/channel/STB history upload, remote-button-usage events and more.
  * `customAdAllowed` (Interest-Based Advertising) gates admanager targeting.
  * `voiceAllowed`/`voice2Allowed` gates cloud STT.
* **Some traffic runs regardless of consent.**
  * The connman online check goes to `http://lgtvonline.lge.com/` in plain HTTP. **[O]**
  * SDX device auth, country detection and the EULA download run before consent, because they are needed to show the terms. **[I]**
  * System time comes from SDP (NTP is disabled). **[O]**
  * Manual update checks run.
  * Certificate and broadcast-config downloads go via SDX.
  * The LAN services (DIAL, SSDP, mDNS and the second-screen websocket) stay up.
* **Crash and analytics reports contain identifiers and whole log directories.**
  * `uploadd` crash reports tar every file directly under `/var/log/`.
  * The rdxd "overview" script writes the **raw serial number, NDUID and eMMC serial**.
  * Many daemons log UDIDs and MACs at debug/info level (`"%s: UDID: %s"`, `"macAddr: %s"`, `"_g_udid = %s"`).
* **Production logging is verbose.** Of about 156 PmLog contexts, 60 are set to `debug` and 94 to `info`. Logs go to `/var/log`, which is a symlink to `/tmp/var/log`, which is **ramfs** (no size cap). That costs RAM and CPU, and it widens what a crash upload can contain.
* **Analytics events are server-controlled.** PmLogDaemon downloads an encrypted replacement whitelist into `/mnt/lg/cmn_data/whitelist/`. LG can therefore change which `NL_*` events are collected without a firmware update. **[O]**

---

## 1. Phone-home components

### 1.1 SDX / SDP service broker: `com.webos.service.sdx` (`usr/sbin/sdx`)

* **Endpoint table:** `usr/palm/sdx/server_addr_version.conf` **[O]**

| SDX serviceName | Domain | Base path | Main users (binaries that reference it) |
|---|---|---|---|
| `sdp`, `sdp_secure`, `sdp_devauth`, `sdp_terms`, `sdp_terms_withdrawal`, `sdp_detect_country`, `sdp_check_acr`, `sdp_oss`, `sdp_secure_notice` | `lgtvsdp.com` (region-prefixed, e.g. `us.`/`aic-` **[I]**) | `rest/sdp/v11.2/` | sdx, contentminer, memchute, sam, dmost, voiceconductor, nlpmanager, alexa/google adapters, iot-client |
| `sdp_apps*` | `lgtvsdp.com` | `rest/appstore/v11.0/` | appinstalld, admanager, certupdmgr, broadcast-conf-downloader, WAM, libcbe (browser) |
| `ibis`, `ibis_secure` / `ibis_stat_secure` | `ibs.lgappstv.com` / `ibsstat.lgappstv.com` | `ibs/v3.1/` | pbs (EPG/channel map), iconnectivity |
| `rdx`, `rdx_secure` | `rdx2.lgtvsdp.com` | `/v11.0/` (+ `log/crash`, `log/normal` from `etc/uploadd.conf`) | uploadd, crashd/rdxd |
| `iot` | `api.lgtviot.com` | `/v2.0/` | iot-client, performer, google-assistant-adapter |
| `wau_secure` | `wau.lgtvcommon.com` | `wau/v1.0/` | performer (voice) |
| `voice_proxy_secure` | `netflixvoice.lgtvcommon.com` | `proxy/` | voice |
| `nudge_secure` | `nudge.lgtvcommon.com` | `nudge/` | user-context-manager, nudge |
| `homeprv_secure` | `homeprv.lgtvcommon.com` | `homeprv/` | contentminer (home preview) |
| `nlp_setting_secure`, `nudge_setting_secure`, `service_setting_secure` | `service.lgtvcommon.com` | `service/` | nlpmanager, pbs, remotediag, miracast, micomservice |
| `cpv_secure` | `cpv.lgtvcommon.com` | `rest/csi/` | (content provider) |
| `recommend_secure` | `recommend.lgtvcommon.com` | `recommend/v1/` | nlpmanager |
| `iot_push_secure`, `iot_sports_secure` | `push.lgtviot.com`, `sports.lgtviot.com` | `v1.0/` | sportsalarm (MQTT) |
| `cdp_service_secure` | `cdpsvc.lgtvcommon.com` | `api/v1.0/` | pbs |
| `smartshare` | `smartshare.lgtvsdp.com` | | |
| `iap` | `lgtvsdp.com` | `rest/iap/v1.1/` | hybridtv-manager |

* **Headers added by sdx/admanager [O]:** `X-Authentication`, `X-Device-Brand`, `X-Device-ContentsQA-Flag`, `X-Device-Country`, `X-Device-Country-Group`, `X-Device-Country-Subdivision`, `X-Device-Eco-Info`, `X-Device-Eula`, `X-Device-FCK`, `X-Device-FW-Version`, `X-Device-ID`, `X-Device-Language`, `X-Device-Locale`, `X-Device-Model`, `X-Device-Netcast-Platform-Version`, `X-Device-Personalization`, `X-Device-Platform`, `X-Device-Product`, `X-Device-Publish-Flag`, `X-Device-Remote-Flag`, `X-Device-SDK-VERSION`, `X-Device-Sales-Model`, `X-Device-Type`, `X-Login-Session`.
* **Device auth [O]:**
  * `"%s[%d] macAddr: %s"`, `"pEncryptedMac: %s"`, `"pUrlEncodingEncryptedMac: %s"`, `"minimalBootDone: %d, fullmacAuth: %d, UDID: %s"`.
  * Query params `&hashedMacAddress=`, `&hashedlgudid=`, `&eulaStatusList=`, `&timeStamp=`, `?voice=Y/N`, which sync the consent state to LG.
* **Identifiers:**
  * The **LGUDID** is generated and stored by securitymanager (`SM_DEVICEID_GenerateLGUDID`, `sm_deviceid_lgudid.c`).
  * The MAC is used in encrypted form for authentication and in hashed form for consent sync.
  * The LG account session is sent in `X-Login-Session`. **[O]**
* **Gating:** none for auth, country detection and EULA download. These are prerequisites for the consent UI. **[I]** sdx also schedules a marketing-consent reminder (`usr/palm/sdx/maketingActivity.json`: "Create toast within 2 years that reminds maketingAllowed"). **[O]**
* **Time:** `etc/palm/defaultPreferences.txt` has `"AllowNTPTime" : false` and `"timeSources" : ["sdp","broadcast-adjusted","broadcast","micom"]`. The network clock therefore comes from LG SDP (`X-Server-Time`), not NTP. **[O]**

### 1.2 Crash and analytics reporting: rdxd, crashd, uploadd, faultmanager, PmLogDaemon

**Components:**

* `etc/init/rdxd.conf`: `exec /usr/sbin/rdxd -s` (starts on minimal-boot-done, respawns). `etc/rdxd.conf`: `AutoUpload=true`. **[O]**
* `etc/rdxd.d/uploadd.crash.json` → `com.palm.uploadd/uploadCrashReport`; `uploadd.analytic.json` → `com.palm.uploadd/uploadAnalyticsReport`. **[O]**
* `crashd` waits for `/var/log/core.%s.%i.gz.complete` and calls `rdx_make_report_from_file` (`librdx.so.4`). `remotelogger` is only a local backtrace/unwind helper: it has no network strings and writes to `/var/log/crashd/`. **[O]**
* `faultmanager` matches `RDXD_.*__Linux Crash`, runs `/usr/share/rdxd/make_sysinfo.sh`, and can reboot the TV through tvpower. It has no direct network access. **[O]**
* `uploadd`:
  * Gets its URL from sdx (`luna://com.webos.service.sdx/getRdxServerUrl` → `rdx2.lgtvsdp.com`) and the header from `getHttpHeaderForServiceRequest`.
  * `etc/uploadd.conf`: `AnalyticsLogURL=log/normal`, `CrashLogURL=log/crash`, `MaxUploadBytes=2097152`, `NumberOfRetries=5`, `MinSecsDelayOnFailure=3600`.
  * Spool directories are `/var/spool/uploadd/{pending,uploaded}`, with history in `/var/log/uploadd/uploadd-history.txt`.
  * It is periodic: `"Upload analytics log event reached on the interval.. [%d] seconds"`, `"%s?requestInterval=%d"`, `anonymousInterval`. The interval is supplied by the server. **[O]**

**What a report contains [O]:**

* **Crash report** (`usr/share/uploadd/make_sdp_crash.sh`):
  * The last 40 KB of `/var/log/messages`.
  * `make_syslog.sh`: `tar -czf $target `find log/ -type f -maxdepth 1``. This is **every top-level file in /var/log**, including the per-daemon logs listed in section 3.
  * The package manifest, the last 40 KB of dmesg, and the preboot log.
* **Overview header** (`usr/share/uploadd/make_overview_head.sh`):
  * Fields: product id, HW revision, `DEVICE_NAME`, build id/name, release, and the **full SDX header string** (which carries `X-Device-ID` etc.).
  * `SERIAL_SNUM=` is written empty.
  * `DEVICE_UID` is `sha256(device_cycle_date + nduid)` with its last 4 characters masked, i.e. pseudonymous.
* **rdxd "Sumologic Overview"** (`usr/share/rdxd/make_overview.sh`, CONTEXTLOG in `etc/rdxd.conf`):
  * `SERIAL_SNUM=$serial_number` (**raw serial**) and `DEVICE_UID=$nova_device_uid` (**raw NDUID**).
  * The SDX header.
  * `/proc/cpuinfo`, the **eMMC `manfid`/`oemid`/`serial`**, `/proc/mounts`, `ps aux`, `df -h` and `ls -l /var/luna/preferences`.
* **`make_sysinfo.sh`** additionally captures `ifconfig` (MACs and IPs) and the results of these luna calls: attached USB storage, external input status (HDMI devices), power-off reasons, connection status, and running apps.
* **PmLogDaemon** feeds analytics:
  * Two event whitelists: `etc/PmLogDaemon/whitelist_basic.txt` (207 lines) and `whitelist.txt` (262 lines).
  * Log string: `"[DEBUG] g_isAdditionalTermsAccepted [%d] | g_isGeneralTermsAccepted [%d]"`. **[O]**
  * The replacement whitelist is downloaded and decrypted (`/tmp/whitelist.enc`, `"updateYn : %s, newVersion : %d, url : %s"`, `DILE_CRYPTO_SDP_ReadCommonKey`) into `/mnt/lg/cmn_data/whitelist/`. **[O]**
  * Inference **[I]**: the basic list applies with general terms only, and the full list applies with additional terms.
  * Events in the basic list include:
    * Ads and app lifecycle: `NL_ADMAN_IMP`, `NL_ADMAN_CLK`, `NL_ADMAN_IFA_RST`, `NL_APP_LAUNCH`, `NL_APP_INSTALLED`.
    * Inputs, settings, power and storage health: `NL_EIM_INPUTLIST`, `NL_SETTING_CHANGE`, `NL_PICTURE_SETTING_CHANGE`, `NL_POWER_STATE`, `NL_EMMC_LIFETIME`.
    * Voice, music recognition and ACR status: `NL_VOICE_LAUNCH`, `NL_MUSIC_RECOG`, `NL_ACR_CAP_STATUS`, `NL_ACR_OFF_REASON`.
    * Remote control use: `NL_BUTTON_CLICK` (lginput2), `NL_RCU_CONTROL_USE`, `NL_SCREEN_REMOTE_KEY_USE`, `NL_VKB_INPUT_METHOD`.
    * Home-screen UI interaction: `NL_HOME_SHOWN`, `NL_HERO_CLICKED`.
  * The full list adds `NL_BROADCAST_WATCH_SLINGTV`, `NL_NUDGE_CONTENTS_INFO`, `NL_HBBTV_*`, shopping events (`NL_CLICK_ORDER`, `NL_SELECT_PRODUCT_LIST`), `NL_RESERVATION_INFO`, `NL_SHOW_WWW` and `NL_QUICK_ACCESS_LAUNCH`.
* **Previous-boot logs:** `/var/spool/rdxd/previous_boot_logs.tar.gz` is referenced by PmLogDaemon. **[O]**

**Gating [O]:**

* rdxd: `"EULA is not accepted yet, crash report will not be created."`, `"EULA has not accepted yet, analytics reports will not be created"`, `"Devmode is enabled, analytics reports will not be generated"`, `generalTermsAllowed`. It also has per-type switches (`"Upload switch is disabled for crash reports"`, `{"analyticsLog":..,"crashLog":..}` via `setLogSettings`).
* uploadd: `"EULA not accepted - unschedule pending reports upload"`, `"Not authenticated with SDP/SDX"`, `"EULA allows additional data upload"`.
* Inference **[I]**: crash upload needs Terms of Use + Privacy Policy, and richer analytics needs additional consent. I found no `remoteDiagAllowed` reference in rdxd/uploadd; that key is only used by sam, sdx and securitymanager.

### 1.3 Firmware update check: `update` (`usr/sbin/update`)

* **Endpoints [O]:**
  * Production: `https://snu.lge.com/CheckSWAutoUpdate.laf`, `CheckSWManualUpdate.laf`, `DownloadResult.laf`, `SWDownloadStartLog.laf`, `SWDownloadEndLog.laf`.
  * Legacy: `http://su.lge.com/`, `https://su-ssl.lge.com/`, `http://nsu.lge.com:5100/`.
  * Development: `snu-dev.lge.com` and `http://156.147.69.32:8080/` (an LG internal IP).
* **Body [O]:** Base64-encoded XML (`"XML Body should be BASE64-Encoded"`) with `<DEVICE_ID>`, `<MODEL_NM>`, `<PRODUCT_NM>`, `<COUNTRY>`, `<COUNTRY_GROUP>`, `<LANGUAGE_CODE>`, `<SW_TYPE>`, `<IMAGE_NAME>`, `<AUTH_FLAG>`, `<REQ_ID>`. **[I]** `DEVICE_ID` is MAC-derived; the binary logs `"Master TV's MAC address is (%s)"`.
* **Download telemetry:** Start, End and Result logs are reported back to LG. **[O]**
* **Gating [O]:**
  * `"## %s - User doesn't agree general terms - do not start NSU auto update"`. With no general terms, there is no automatic version check.
  * `support.automaticUpdate` defaults to `"off"`, or `"on"` in KOR. When it is off, the check still runs and creates a popup: `"NSU Update Version is found(AutomaticUpdate:false) - create Update popup"`.
  * `option.appUpdateMode="manual"`. Manual checks from Settings always contact snu.

### 1.4 User Context Manager (usage history): `user-context-manager`

* **What it collects [O]:** app, channel (live TV) and **STB (cable box via HDMI/IR channel detection)** viewing events with durations. The schema enum is `"liveTV","STB","VOD","OTT","app","channel","schedule"`, plus `channelId`, `channelNumber`, `detectedChannelNumber` and YouTube channel info.
* **Upload [O]:** `"Uploading app log is failed"`, `"Uploading channel log is failed"`, `"Uploading STB log is failed"`, `"Log uploaded. evenType : %d"`. Upload times are kept in `/mnt/lg/cmn_data/ucm/{app,channel,stb}_upload_time.txt`.
* **Transport [O]:** SDX `nudge_secure` (`nudge.lgtvcommon.com`) and `sdp_secure`. It also feeds nudge and preload-manager (`last_preload_app`, `ucm_model`, an on-device ML model: "channel predict").
* **Gating [O]:** `"EULA is not accepted"`, `"No additionalDataAllowed field"`. Upload requires **additionalDataAllowed (Viewing Information)**. Local collection appears to continue regardless **[I]**.

### 1.5 Nudge / AI recommendations: `nudge`

* Starts on `ucm-ready`. Server data comes from `nudge.lgtvcommon.com`; `"Eula is not accepted, so do not use server data"` and `"REQUIRED.EULA(ACCEPT)"` show the consent check. **[O]**
* The setting `general.aiNudge` defaults to `"on"` (`"off"` for JPN). User text: "You can receive AI generated recommendations ... based on your TV usage history." **[O]**
* Nudge results are reported as `NL_NUDGE_RESULT_INFO` and `NL_NUDGE_CONTENTS_INFO` in the analytics whitelist. **[O]**

### 1.6 PBS (EPG/channel service) and IBS: `pbs`

* **Endpoints:** `ibs.lgappstv.com`, `ibsstat.lgappstv.com`, plus SDX `cdp_service_secure`. **[O]**
* **What it sends:** the channel map (scanned channels, user edits, STB favourites; `"requestBody send: [%s]"`) and `macAddress`. It authenticates with IBS and sends `X-Device-Eula`. **[O]**
* **Gating:** `"eula changed (general terms=%d, additional data=%d, custom ad=%d)"`. **[O]** `ibsstat` ("ibis_stat") is a statistics endpoint. **[I]** It likely carries guide-usage stats.

### 1.7 Ads and advertising ID: `admanager` and `securitymanager`

* **IFA:**
  * securitymanager generates it (`SM_DEVICEID_GenerateIFAID`, stored in `/var/lib/secretagent/IFA.txt`, plus `/mnt/lg/cmn_data/adid`). **[O]**
  * Reset is logged as `NL_ADMAN_IFA_RST`.
* **Ad request params [O]:** `?app_id=`, `&ifa=`, `&ifa_type=`, `&lmt=`, `&dns=` (Do-Not-Sell), `&opt_out=`, `&tcf=`, `&width=`, `&height=`, `&roll_type=`, `&down_app_id=`. Headers are the same `X-Device-*` set plus `X-Device-ID`.
* **Tracking [O]:** VAST impression and click trackers (`MSG_AD_SEND_IMPRESSION_TRACKER`, `ClickTracking`, `CompanionClickTracking`). Requests go directly to third-party tracking URLs via curl with a cookie jar (`CURLOPT_COOKIEFILE/COOKIEJAR`).
* **Endpoint:** `info.lgsmartad.com` is the only hard-coded host. The ad server address is supplied by the server (`adServer : %s`). **[O]** **[I]** The usual hosts are `us.ad.lgsmartad.com` and `us.info.lgsmartad.com`.
* **Gating [O]:**
  * `"Custom ad agreements not allowed"` (customAdAllowed).
  * `"Terms And Conditions Not Allowed"`.
  * `"Restart admanager service when adcookie status is changed."` (`general.adCookie`, default `"on"`).
  * `general.lmt` (default `"off"`) and `general.doNotSellMyPersonalInformation` (default `"off"`): `"Frequency capping disabled. DNS = %s, LMT = %s"`.
* **Behaviour:** with LMT/DNS on, the IFA is still sent, and the flags are passed to the server as `lmt`/`dns`. **[O]** Ads (home banner, "Home Promotion") still display, just non-targeted. **[I]**

### 1.8 ThinQ / IoT: `iot-client`, `mqtt-client`, `ocf-onboarding`, `sportsalarm`, homeconnect apps

* **iot-client** (`etc/init/iot-client.conf`) only runs if one of these exists: `/mnt/lg/cmn_data/.iot/accountInfoFile`, `pendingAccountInfoFile`, or `ocfres.json`. In other words, it needs ThinQ account linking or OCF onboarding. **[O]**
  * Endpoints: `api.lgtviot.com`, `common.lgthinq.com/route`, `lss.lgthinq.com`, `kr.lgeapi.com`, `*.lgtviot.com/hc_auth_uid`, `hc_refresh_token`, `*.lgtvsdp.com/rest/appstore/v11.0/key/hdcp`.
  * Gating: `"User Agreement is NOT allowed"`, `"generalTermsAllowed is false"`, `"Eula status generalTerms : %s, additionalData : %s"`. **[O]**
* **mqtt-client** is the AWS IoT device SDK (`aws_iot_shadow_add_reported`, `aws_iot_jobs_*`, mbedTLS). It is a luna on-demand service used by iot-client, sportsalarm and amazon-alexa-vsk. The device shadow "reported" state is pushed to AWS IoT. **[O]** **[I]** The endpoint is provisioned at runtime.
* **sportsalarm** uses `push.lgtviot.com` and `sports.lgtviot.com` over MQTT, with the check `"EULA is NOT Allowed.... delete mqtt data"`. **[O]**
* **Home Dashboard apps** (`com.webos.app.homeconnect`, `com.webos.app.partialview`) call `https://<cc>.api.lgtviot.com/v1.0/device/register`. **[O]**

### 1.9 Voice: voiceconductor, voiceinput, nlpmanager, lg.thinqai.adapter, performer, Alexa, Google Assistant

* **Cloud STT [O]:** `lg.thinqai.adapter` has `/voice/stt/v1/dictation/upstream` and `/downstream` with streamed PCM (`PUT_AUDIO`, `CLIENT_STT_PARTIAL`). nlpmanager reports errors like `"STT network server is not respoding"`, `"STT voice recognition server is not responding"` and `embeddedSttResult`. Audio does go to the cloud on push-to-talk. Recognised text and context then go through nlpmanager/performer, using SDX `recommend_secure`, `service_setting_secure` and `wau.lgtvcommon.com`.
* **Context sent with queries [O]:** performer reads UCM history (`luna://com.webos.service.usercontextmanager/getHistory`), the LGUDID (`policy_getUdid`) and IoT macros (`luna://com.webos.service.iotclient/getMacro`). voiceconductor has `InteractorContextCollectorAndSttBridge`.
* **Gating [O]:** `"Voice terms EULA is not set"`, `"General terms EULA is not set"`, `"Additional terms EULA is not set"`, plus the flags `_g_is_voice_eula_allowed` and `_g_is_voice2_eula_allowed`. The voice2 group requires S_ADC/S_ADD as well (com.webos.app.eula mapping).
* **Wake word [O]:** voiceinput has Nuance recognizers and logs `"eula is false. disable wov!"`. `supportVoiceLongDistance` is `false` in `etc/configd/layers/base/com.webos.service.voiceinput.json`. Only WX/RX/GX/ZX/WS/NANO9x tooltypes set it to true, and there is no CX layer. **So the CX has no far-field or always-listening mic.** Voice is push-to-talk on the Magic Remote. (`general.voiceLongDistance="on"` is irrelevant on this model.)
* **Debug artefact [O]:** thinqai has an "autorecord" feature that writes `/tmp/thinqai/autorecord/`, `temp.pcm`, `"AUTO_RECORD_INIT {"LT_AUTORECORD_SUPPORT": true}"`. **[I]** It is probably a debug path that is inactive in retail. `/var/luna/preferences/voice_server_sync_disabled` exists as a flag.
* **Alexa and Google Assistant:** the adapters only work after in-app account sign-in. They use vendor endpoints (amazon-alexa-adapter references a CloudFront host; google-assistant-adapter uses gRPC googleapis). The `NL_ACTIVATE_ALEXA` and `NL_FARVOICE_*` events are whitelisted. **[O]**

### 1.10 Remote Service (LG support remote control): `remotediag` + `com.webos.app.remoteservice`

* **Runtime:** it runs at boot (`etc/init/remotediag.conf`, respawn; its description is mislabelled "External Input Manager"). **[O]**
* **Endpoints [O]:** `rone-aic/eic/kic/saic.lge.com` and `rone-tv-{aic,cic,eic,kic,saic}.lge.com`. Connections are TLS with a device private key from the secure store, with separate main and stream ports.
* **Capabilities [O]:** `ScreenCapture`/`HighScreenCapture`, `SendKey`, `GetMACAddress`, `GetSerialNumber`, `FactoryReset`, `ResetPicture`/`ResetSound`, `DLNAServerIpInfo` and fetch-log (`ImplFetchLog`). This is effectively full remote control of the TV plus screen capture.
* **Gating:** `RequestServiceAgreeConfirm`/`Cancel` and `/remote/regist/remoteServiceTerms.dev`. **[O]** **[I]** A session is only established when the user opens Support → Remote Service and agrees with an agent-supplied code. No boot-time connection was evident.

### 1.11 Store/demo and commercial agents

* **care365 (Azure IoT)** is a node service in `usr/palm/services/com.webos.app.care365.service`.
  * Activity: `etc/palm/activities/com.webos.app.care365.service/*.json` starts it only when `storeMode == "store"` and the internet is available, or when `other.care365.value == "on"` (default `"off"`). **[O]**
  * Endpoints: `download.365care.lge.com`, `*.azure-devices.net`, `*.azurewebsites.net`.
  * Not relevant in Home mode. Note that `preman/remote/azure/test/001_azure_comm.js` ships a hard-coded dev IoT-Hub `SharedAccessKey`. **[O]**
* **storedemo** only creates the preload directories. Home mode (`option.storeMode="home"`) is the default. **[O]**

### 1.12 Other phone-home items observed

* **Connectivity check (no consent):** `etc/connman/main.conf` has `Ipv4StatusUrl=http://lgtvonline.lge.com/`, `Ipv6StatusUrl=...`, `TakeDnsIpResolutionAsOnline=true`. It is plain HTTP on every network change. `8.8.8.8` is present in connmand. **[O]**
* **certupdmgr:** fetches CA updates via SDX: `{"serviceName":"sdp_apps_secure",...,"url":"app/appResource","bodyData":"app_info=com.webos.service.certupdmgr.certificates"}`. **[O]**
* **broadcast-conf-downloader:** downloads broadcast config via SDX `sdp_apps_secure` and decrypts it with `decryptSdpFile`. **[O]**
* **contentminer:** pulls home-preview content from `homeprv.lgtvcommon.com`; it is EULA-aware (`generalTermsAllowed`). **[O]**
* **memchute:** sends a `sdp_secure::services` request once. **[O]**
* **iconnectivity (UEI QuickSet):**
  * Auto-detects HDMI-CEC and LAN devices and handles IR codes, keyed by `LGUDID`, `ZIPCODE` and `COUNTRY` (`"HDMI(%d), NETWORK(%d), EULA(%d), COUNTRY(%s)... ZIPCODE(%s), LGUDID(%s)"`).
  * Strings include "Upload Configuration to Cloud" and "Submit debug report".
  * It uses SDX `ibis_secure`/`sdp_oss`. **[O]**
* **upnpd:** contains `qt2-kic.service.lgtvcommon.com/service/uploadFile`, a QA host. **[I]** This is likely a test or debug path.
* **Browser:**
  * The engine is `libcbe.so` (Chromium). It contains `lgtvbrowser.lgtvsdp.com`, `/safebrowsing`, breakpad microdump code and gaia/oauth code. **[O]**
  * WAM: `etc/wam/plugins/conf.sh` sets `export WAM2_ENABLE_DEBUG_EVENT=1` and `QT_WEBKIT_LOG="Media"`. **[O]**
  * **[I]** Breakpad microdumps go to the log, which may then be swept into crash uploads; there is no separate Google crash upload.
* **statisticsmanager:** `usr/share/luna-service2/services.d/com.webos.statisticsmanager.service` has `Exec=/usr/bin/webos-statistics-manager`, but **that binary is absent** from the image. It is a dead registration. **[O]**
* **appcts:** a local signing/verification helper; no network strings. **[O]**
* **event-monitor:** a local plugin host (`usr/lib/eventmonitor/network-starfish.so`) that only produces toasts and alerts. **[O]**

---

## 2. Consent and settings matrix

Consent group mapping, from `usr/palm/applications/com.webos.app.eula/main.js` **[O]**:

| eulaStatus key | Required documents | Probable US UI name **[I]** | Gates (binaries referencing key) **[O]** |
|---|---|---|---|
| `generalTermsAllowed` | S_SVC, S_PRV, S_PRD | User Agreements: Terms of Use / Privacy Policy | rdxd, uploadd, PmLogDaemon (basic), update auto-check, iot-client, nudge, contentminer, sportsalarm, performer, nlpmanager |
| `additionalDataAllowed` | +S_ADC, S_ADD (KR title "시청정보 수집 이용 동의", i.e. viewing-info collection) | **Viewing Information** | PmLogDaemon (full whitelist), user-context-manager, lginput2 (`NL_BUTTON_CLICK`), bthidmanager, pbs, nudge, nlpmanager, voiceconductor, performer, iot-client, sportsalarm, legacy-broadcast, factorymanager |
| `customAdAllowed` | +S_TAD ("맞춤형 광고", customised ads) | **Interest-Based Advertising** | admanager, livepick-plus, pbs, sportsalarm |
| `voiceAllowed` / `voice2Allowed` | +S_VDC, S_VDD, S_NVC, S_NVD (Nuance) | **Voice Information** | voiceconductor, performer, nlpmanager, thinqai |
| `acr*Allowed` | | Viewing Info / Live Plus (ACR; see the ACR report) | acr2 |
| `remoteDiagAllowed`, `thirdPartySharingAllowed`, `cookiesAllowed`, `marketingOnAllowed` | | (per-region extras) | sam/sdx/securitymanager, admanager/livepick-plus |

Other relevant settings and their defaults (`etc/palm/defaultSettings.json`) **[O]**:

| Setting | Default | Effect |
|---|---|---|
| `general.lmt` | off | Limit Ad Tracking; IFA still sent, `lmt=1` |
| `general.doNotSellMyPersonalInformation` | off | CCPA flag `dns=` to ad server |
| `general.adCookie` | on | admanager cookie jar |
| `general.aiNudge` | on | AI recommendation nudges (uses usage history) |
| `general.personalRecommend` | off | personalised recommendations |
| `general.homeAutoLaunch` | on | Home Auto Launch (home + promo banners at boot) |
| `option.quickStartMode` | off, but `on` when `InstantBoot=quickStartPlus` | Quick Start+: TV in suspend, daemons stay up (network keeps flowing) **[I]** |
| `option.livePlus` | off | Live Plus (ACR interactivity) |
| `support.automaticUpdate` | off (KOR on) | Auto firmware install; checks still occur |
| `option.appUpdateMode` | manual | |
| `network.allowMobileDeviceAccess` | true | Second-screen websocket (3001), "LG Connect Apps" |
| `network.wolwowlOnOff` | false | Wake-on-LAN/WLAN (Mobile TV On) |
| `option.enableIpControl` / `password_ipcontrol` | off / **"828"** | Commercial IP control; weak default key if ever enabled |
| `option.enableSDDP` | off | Control4 SDDP (`webos-sddp` exits unless on) |
| `option.storeMode` | home | `store` would start care365 and demo flows |
| `other.care365.value` | off | |

**Traffic that runs regardless of consent [O/I]:**

* The connman online check (`lgtvonline.lge.com`).
* SDX device auth, country detection and EULA download (`*.lgtvsdp.com`), plus SDP time sync. **[I]**
* User-initiated firmware checks (`snu.lge.com`).
* certupdmgr and broadcast-conf-downloader via SDX. **[I]** I saw no EULA check in their strings.
* App store, CDN and image fetches for the home launcher.
* LAN services: DIAL, SSDP, mDNS, second-screen.
* Local collection by UCM and PmLog. Only the *upload* is gated.

---

## 3. Logging verbosity (privacy and performance)

* `/var/log` → `/tmp/var/log`, mounted as `mount -t ramfs ramfs /tmp/var/log` (`etc/init/mount-readonly-volatile.conf:117`). **ramfs has no size limit and cannot swap**, so every log byte is resident RAM. **[O]**
* PmLogDaemon is launched with `/usr/sbin/PmLogDaemon -z -f 6 -m` (`etc/init/PmLogDaemon.conf`). **[O]**
* `etc/pmlog.d/*.conf`: about **60 contexts at `debug`**, 94 at `info` and 101 separate output files (typically `maxSize 10000` KB × 5 rotations each; `webos-bluetooth-service` has `maxSize 100000`). The theoretical ceiling is several GB. Real use is bounded by write volume, and PmLogDaemon even has a `"/bin/rm -rf /var/log/* /var/log/.*"` panic path for when "/var/log full". **[O]**
* **Debug-level contexts** include:
  * Ads and voice: ADMANAGER, ASSISTANT (Google), AMAZON-ALEXA-ADAPTER/VSK, THINQAI, NLPMANAGER, PERFORMER, VOICEFW, voiceinput, tts.
  * Remote diagnostics and EPG: REMOTEDIAG, PBS, IEPG.
  * acr and adoverlay-service (both also `logToConsole: true`), and CGL, LIVEPICK-PLUS, NDK2 (`logToConsole: true`).
  * hybridtv, CBOX, DRM (drmclient/controller/service), bluetooth, lginput2, webos-sddp, webos-preload-manager, videooutputd, jailer, plus the `legacy-log` and `devmode` defaults.
* **Identifiers end up in logs [O]:**
  * sdx (`info`) logs `"UDID: %s"`, `"macAddr: %s"`, `"pEncryptedMac: %s"`, `"response header: %s"`, `"host in header: %s"` and `"[HEADER: %s"`.
  * performer logs `"_g_udid = %s"`, iot-client logs `"deviceId : %s"` and `"macPayload : %s"`, and remotediag logs `"SystemCode (%s) / DeviceID (%s)"`.
  * The uploadd crash bundle tars all of `/var/log/*`, so these values can leave the device inside crash reports.
* **Performance [I]:** debug logging of media, DRM, video output and bluetooth on a CPU-constrained SoC, plus `logToConsole` for acr/adoverlay/CGL/NDK2/livepick, costs CPU and RAM continuously. Lowering levels on a rooted TV (`PmLogCtl set <context> warning`, or editing the pmlog.d overlay) should measurably reduce churn.
* **Developer flags left on [O]:** `WAM2_ENABLE_DEBUG_EVENT=1` and `QT_WEBKIT_LOG="Media"` (`etc/wam/plugins/conf.sh`). PmLogDaemon also supports `/mnt/lg/cmn_data/whitelist/enablePerfLog` and `/mnt/lg/cmn_data/pbs/pmlog_on.txt` toggles.

---

## 4. Local network exposure

| Port / proto | Service | Binding / auth | Gate |
|---|---|---|---|
| 3000/tcp | second-screen gateway HTTP/ws (`xinetd.d/ssg_http` → `nsl 3000 com.webos.service.secondscreen.gateway`) | **`only_from = 127.0.0.1`**, so localhost only **[O]** | |
| **3001/tcp** | second-screen gateway **wss (TLS)** (`xinetd.d/ssg_https`) | LAN-wide; pairing prompt (`"bypass-pairing": false`), origin and interface security on (`config.js`) **[O]** | `network.allowMobileDeviceAccess` (default true); `"force-start": false` honours it |
| 36866/tcp | DIAL REST (`xinetd.d/dial_http`, `com.webos.service.dial`) | unauthenticated LAN app launch (YouTube, Netflix etc.; CORS checks only) **[O]** | |
| 18181/tcp | DIAL tv-app (`xinetd.d/dial_tvapp`) | unauthenticated **[O]** | |
| 1900/udp | SSDP: `com.webos.service.dial.ssdpmanager` (advertises `:36866`), `ssdp-discovery-lgtv` (`urn:lge:device:tv:1`, friendlyName, modelName, persistent UUID in `/mnt/lg/cmn_data/ssdplgtv/uuid`), `upnpd`/`dmr` (DLNA renderer) | advertises model name and device name **[O]**; WoL MAC (DIAL WAKEUP) likely added when `wolwowlOnOff` is on **[I]** | |
| 5353/udp | `avahi-daemon` (`publish-hinfo=no`, `publish-workstation=no`, IPv4 only, `enable-wide-area=yes`) + `mdnsd` (AirPlay/HomeKit) | **[O]** | |
| AirPlay/HomeKit (7000 etc.) | `airplay-adaptor` (boot-done), `airplay`, `homekit` services | **[I]** listens only when AirPlay is enabled in Settings | |
| 9761/tcp | LG IP Control (`care365 config.json` targets `127.0.0.1:9761`) | default key `"828"` **[O]** | `option.enableIpControl` off |
| SDDP | `webos-sddp` | | `enableSDDP` off; job exits **[O]** |
| other xinetd services | chargen/echo/daytime/discard/time/tcpmux/ftp-sensor | **all `disable = yes`** **[O]** | |
| lighttpd | `usr/sbin/lighttpd` + `etc/lighttpd.conf` | **no upstart job starts it** **[O]**, so not running by default **[I]** | |
| SSH | devmode only (`etc/init/devmode.conf`, SDK key) | | Developer Mode app |

* There is **no host firewall**: no iptables rules are loaded by any init job **[O]**. All the listeners above are reachable by anything on the same L2 network.
* **Factory/test backdoor-ish scripts [O]:** `etc/connman/run_endpoint.sh` and `run_waveagent.sh` extract and execute binaries from **any attached USB stick as root** (IxChariot endpoint, WaveAgent). They are only invoked from the factory menu, `com.webos.app.factorywin/qml/TestOption.qml`. They are not network-reachable, but they are an insecure local path.

---

## 5. Mitigations

### 5.1 User settings (no root)

1. **Settings → General → System → Additional Settings → User Agreements** (or Support → Privacy & Terms):
   * Un-tick **Viewing Information**. This stops UCM history upload, the full analytics whitelist and remote-button telemetry, and also ACR.
   * Un-tick **Interest-Based Advertising** and **Voice Information**.
   * Optionally withdraw **Terms of Use/Privacy Policy**. That stops crash/analytics upload, ThinQ, nudges and the auto update check, but it disables most smart features (store, apps, voice, ThinQ). Network access itself (`networkAllowed`) stays true.
2. Turn on **Limit Ad Tracking** (`lmt`) and **Do Not Sell My Personal Information**, turn off **Ad Cookie**, and **reset the Advertising ID**.
3. Turn off **AI Recommendation / nudges** (`aiNudge`), **Home Auto Launch**, **Home Promotion**, **Live Plus** and **Quick Start+**. With Quick Start+ off, the TV fully shuts down instead of suspending with its daemons connected. **[I]**
4. Turn off **Mobile TV On / Wake-on-LAN** and **LG Connect Apps** (`allowMobileDeviceAccess`; closes 3001 behaviour), plus AirPlay/HomeKit if unused. Do not enable IP Control.
5. Leave **Auto Update** off if you want to control firmware. Manual checks will still contact `snu.lge.com`.
6. Do not link ThinQ, LG Account, Alexa or Google unless needed. iot-client does not even start without the `.iot` account files.

### 5.2 Rooted TV (e.g. via webOS homebrew)

Make changes persistent via a startup script, since rootfs is read-only squashfs. `stop` works on upstart jobs; luna services can be denied via an `ls-hubd` overlay or by killing them. Suggested order (low risk first):

```sh
# Crash/analytics pipeline
systemctl stop rdxd; systemctl stop crashd          # crashd also stops core collection
luna-send -n 1 luna://com.webos.rdxd/setLogSettings '{"analyticsLog":false,"crashLog":false}'   # [I] method name observed, payload from schema
rm -f /var/spool/uploadd/pending/*              # pending reports
# Usage-history / recommendations
systemctl stop user-context-manager; systemctl stop nudge; systemctl stop contentminer
# Remote support daemon (re-enable if you ever need LG support)
systemctl stop remotediag
# IoT (normally idle unless account linked)
systemctl stop iot-client
# LAN surface
systemctl stop ssdp-discovery-lgtv; systemctl stop avahi-daemon   # breaks phone discovery/casting/AirPlay
# Logging: reduce verbosity (saves RAM/CPU on ramfs /var/log)
for c in ADMANAGER PBS PERFORMER NLPMANAGER THINQAI VOICEFW REMOTEDIAG acr adoverlay-service CGL NDK2 LIVEPICK-PLUS hybridtv; do PmLogCtl set "$c" warning; done
```

* `admanager` and `sdx` can be stopped (`luna-send` to the service manager, or by killing them). **Stopping `sdx` breaks the app store, account, time sync and almost all smart features.**
* Disabling `update` stops OTA checks, including security updates.
* Do not stop `PmLogDaemon` or `ls-hubd`; that breaks the system.
* A local hosts or DNS override is cleaner than killing core daemons.
* An overlay copy of `etc/pmlog.d` with `warning` levels makes the logging change persistent. **[I]**

### 5.3 DNS blocklist candidates

| Domain(s) | Purpose | What breaks if blocked |
|---|---|---|
| `rdx2.lgtvsdp.com` (`*-rdx2.lgtvsdp.com` **[I]**) | crash and analytics upload | nothing user-visible |
| `ibsstat.lgappstv.com` | IBS stats | nothing visible **[I]** |
| `*.lgsmartad.com` (`info.lgsmartad.com`, `us.ad.lgsmartad.com`, `us.info.lgsmartad.com` **[I]**) | ads, IFA, impressions | home banner ads become blank (desired) |
| `nudge.lgtvcommon.com`, `recommend.lgtvcommon.com`, `homeprv.lgtvcommon.com`, `cpv.lgtvcommon.com` | usage-history upload, nudges, recommendations, home previews | AI recommendations, home preview rows |
| `wau.lgtvcommon.com`, `netflixvoice.lgtvcommon.com` | voice/NLP services | voice search/commands |
| `*.lgtviot.com`, `*.lgthinq.com`, `kr.lgeapi.com` | ThinQ IoT, sports alerts, home dashboard IoT | ThinQ, Home Dashboard IoT, sports alerts |
| `rone-*.lge.com`, `rone-tv-*.lge.com` | LG Remote Service | remote support sessions |
| `download.365care.lge.com`, `*.azure-devices.net` | store-mode agent | nothing in Home mode |
| `videoacr.lgtvcommon.com`, `*.alphonso.tv` | ACR (see ACR report) | Live Plus |
| `snu.lge.com`, `su.lge.com`, `su-ssl.lge.com`, `nsu.lge.com` | firmware check and download telemetry | **all OTA updates (security fixes)**; block only if you update manually via USB |
| `lgtvonline.lge.com` | connectivity probe | TV may show "no internet" and suppress online features (connman `TakeDnsIpResolutionAsOnline=true` may soften this **[I]**) |
| `*.lgtvsdp.com` (`us.lgtvsdp.com`, `aic-*`, `smartshare.`, `lgtvbrowser.`), `ibs.lgappstv.com`, `cdpsvc.lgtvcommon.com`, `service.lgtvcommon.com`, `lgappstv.com` | **core**: device auth, EULA, app store, EPG/channel logos, time sync, certificate updates, IAP | **most smart features: store, app installs/updates, LG Channels, program guide, network time.** Block only for a "dumb TV" setup |

Recommended "privacy but functional" set: `rdx2.lgtvsdp.com`, `ibsstat.lgappstv.com`, `*.lgsmartad.com`, `nudge.lgtvcommon.com`, `recommend.lgtvcommon.com`, `homeprv.lgtvcommon.com`, `videoacr.lgtvcommon.com`, `*.alphonso.tv`, `rone*.lge.com`, plus the `*.lgtviot.com`/`*.lgthinq.com` hosts if you don't use ThinQ. Combine this with the consent withdrawals in §5.1; that is the strongest single control because each daemon checks it locally.

---

## 6. Caveats

* Static analysis only. Runtime URLs supplied by the server (ad server, RDX URL, region prefixes, MQTT endpoint, upload interval) cannot be confirmed without traffic capture.
* The US UI names for consent groups are inferred from the KR titles in the eula app mock data and from public LG terminology.
* Which whitelist (basic vs full) applies under which consent is inferred from PmLogDaemon's log strings and the content difference between the two files.
