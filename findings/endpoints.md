# Network endpoint inventory: LG OLED55CXPUA (webOS 5.6.2, firmware 04.64.00, US/ATSC)

This inventory comes from static analysis only. I ran `strings -a` over every file in rootfs, bsppart-atsc, otncabi-atsc, otycabi-atsc and swue, plus a URL/FQDN regex. I skipped the fonts and license partitions. I also read the config files the code points to (`usr/palm/sdx/server_addr_version.conf`, `etc/connman/main.conf`, `etc/palm/voice-framework.conf`, `usr/share/amazon-alexa-adapter/AlexaClientSDKConfig.json`, `etc/uploadd.conf`) and the code that builds hostnames at runtime (sdx, performer, overlaycontainer `app.js`, discovery `Loader.js`, admanager).

* Raw extraction: about 14,500 unique host-like strings. Most are noise from public-suffix lists (Qt, libsoup, tough-cookie), the Chromium HSTS and CT lists in `libcbe.so`, the browser's bookmark and history lists, TTS dictionaries, `.cc` source names, and CA CRL/OCSP URLs.
* After filtering by file and by host: 1,388 hosts with file references, in `findings/endpoints_raw.tsv`.
* After manual triage: about 120 endpoints the firmware itself can plausibly contact. They are listed below. 142 hostnames are in `findings/blocklist.txt`, 46 of them in "Safe" and 96 in "Optional". 41 of the Optional entries are Nuance per-locale voice gateways.

## How LG builds hostnames at runtime (templates)

| Template | Where | US expansion | Evidence |
|---|---|---|---|
| `<CC>.<domain>` for `domainType: "default"` sdx domains (lgtvsdp.com, ibs/ibsstat.lgappstv.com, smartshare/rdx2.lgtvsdp.com) | `usr/sbin/sdx` + `usr/palm/sdx/server_addr_version.conf` | `us.lgtvsdp.com`, `us.ibs.lgappstv.com`, `us.ibsstat.lgappstv.com`, `us.smartshare.lgtvsdp.com`, `us.rdx2.lgtvsdp.com` | Header sample `Host: KR.lgtvsdp.com` in apps; `pbs` has `.ibs.lgappstv.com/` and `.ibsstat.lgappstv.com/` with an empty prefix slot; `Loader.js`: `HOST.split(".")[0] + "." + host` |
| `<CC>.lgrecommends.lgappstv.com` | discovery, membership and facebooklogin apps (`Loader.js`) | `us.lgrecommends.lgappstv.com` | `Loader.host = Loader.q.HOST.split(".")[0] + "." + Loader.host` |
| `<CC>.info.lgsmartad.com` | `usr/sbin/admanager` (`getSDPServerPrefix`) | `us.info.lgsmartad.com` | Prefix comes from the sdx HOST header |
| `<env><ric>.<domain>` for `domainType: "ric"` sdx domains and the overlay apps | `overlaycontainer*/app.js`, `fooddelivery*/app.js`: `` `https://${env}aic.${baseHost}/` ``; `performer`: `"%s%s.%s%s"` | `aic.videoacr.lgtvcommon.com`, `aic.fooddelivery.lgtvcommon.com`, and by the same rule `aic.wau / aic.service / aic.homeprv / aic.recommend / aic.nudge / aic.cpv / aic.cdpsvc / aic.netflixvoice .lgtvcommon.com`, `aic.api / aic.push / aic.sports .lgtviot.com` | "aic" is hard-coded in the overlay apps. QA samples follow the same shape: `qt2-kic.service.lgtvcommon.com`, `kic.cdpsvc.lgtvcommon.com`, `qt2-kic.lgtviot.com`. The sdx-domain expansions rely on the RIC the server returns. It should be "aic" for the US but was not observed as a literal string. |
| `<ric>-<env>ngfts.lge.com` | livepick-plus, pbs, voice-framework | `aic-ngfts.lge.com` | Seen as a literal (`aic-ngfts`, `aic-qt2-ngfts`, `kic-qt2-ngfts`) |
| Environment prefixes `qt-`, `qt2-`…`qt5-`, `st-`, `st2-`, `dv-`, `dv2-`, `ek-` | sdx | (production = empty) | Strings in sdx |
| `rone-[tv-]<ric>.lge.com` | remotediag | `rone-aic.lge.com`, `rone-tv-aic.lge.com` | Literal list (aic/kic/eic/saic/cic) |
| `lgtv2020-ncs-<lang><country>-gwssl.nuancemobility.net` | `etc/palm/voice-framework.conf` | `...-engusa-...` (also `spaxla`, `fracan`) | 41 literal hosts |
| `<CC>.lgtvbrowser.lgtvsdp.com`? | `libcbe.so` ErrorReport (`%s://%s/%s`, `log/report.do`, `SetCountryGroup`) | unclear | The domain prefix is set at runtime. I only listed the literal host. |
| Ad server (`adServer`), ACR fingerprint servers (`acr_server_port_ssl`), Alphonso BusinessLogic server (`/bl/config`) | admanager, libas.so | not in the firmware | These come from provisioning responses (prov-lg.alphonso.tv, the sdx "check_acr" service). Block at the domain level (`*.lgsmartad.com`, `*.alphonso.tv`) if your resolver supports wildcards. |

Hard-coded IPs (DNS blocking does not stop these): `156.147.69.32:8080` (update, dev fallback for `*.laf` endpoints, LG Korea network), `165.244.62.249:6230/6240` (remotediag, kic/aic dev servers). RFC1918 IPs in remotediag and mock data are internal.

## Endpoint table

Block impact is my inference from the code paths. Verify on the TV.

### LG platform (SDP / "sdx" server-config driven)

| host | category | referencing components | notes / block impact |
|---|---|---|---|
| `lgtvsdp.com` → `us.lgtvsdp.com` | account/auth; app store; EULA/terms; country detection; ACR-consent check | `usr/sbin/sdx` (server_addr_version.conf services sdp, sdp_secure, sdp_devauth, sdp_terms, sdp_detect_country, **sdp_check_acr**, sdp_oss, sdp_apps*, iap, sns); `pbs` (`/rest/appstore/v11.0/key/hdcp`); browser; adapp | This is the hub for everything "smart". Blocking it breaks the LG Content Store, app installs and updates, LG account login, in-app purchases, the EULA/terms flow and country detection. Most other LG services also stop working because they need SDP device auth. The TV still works as a display, with Live TV and HDMI. |
| `smartshare.lgtvsdp.com` → `us.smartshare.lgtvsdp.com` | app store/content | sdx (smartshare) | Smartshare/media metadata. Low impact. |
| `rdx2.lgtvsdp.com` → `us.rdx2.lgtvsdp.com` | **crash/diagnostic upload + analytics** | sdx (rdx, rdx_secure); `uploadd` (`etc/uploadd.conf`: `[server=rdx] AnalyticsLogURL=log/normal`, `CrashLogURL=log/crash`); rdxd, rdx_reporter, crashd | Uploads crash dumps and "analytics" logs. **Safe to block.** Only LG's crash reporting is lost. |
| `lgtvbrowser.lgtvsdp.com` | crash/diagnostic upload | `usr/lib/libcbe.so` (crow browser ErrorReport → `log/report.do`, JSON with system info) | Browser error reports. **Safe to block.** |
| `ibs.lgappstv.com` → `us.ibs.lgappstv.com` | content (Live TV program/IBIS) | sdx (ibis, ibis_secure); `pbs` (`ibs/v3.1/`) | Program-based services and enhanced Live TV info. Blocking may degrade the guide or channel artwork and Live TV recommendations. |
| `ibsstat.lgappstv.com` → `us.ibsstat.lgappstv.com` | **analytics (viewing logs)** | sdx (ibis_stat_secure); `pbs` → `service/livetvwatch.json` | Live TV watch statistics. **Safe to block.** |
| `lgrecommends.lgappstv.com` → `us.lgrecommends.lgappstv.com` | app store/content; account | otncabi `com.webos.app.discovery` (discovery_2016/2020), `membership`, `facebooklogin` (membership-webapp_2019 google/facebook/amazon login), `/view/init2020` | Blocking breaks the LG Content Store "discovery" pages and LG account social login. |
| `www.lgappstv.com` | other (support) | self-diagnosis, tvuserguide, QR Q&A link | Support web links. Low impact. |
| `redirect.lgsmartplatform.com` | other | `webapphost/index.html`, apiadapter `webapp/index.js` | Redirect service for web apps and second screen. Low impact. |
| `info.lgsmartad.com` → `us.info.lgsmartad.com` | **advertising** | `usr/sbin/admanager` (MSG_AD_UPDATE_DNS: `?dns=&ifa=&ifa_type=`) | Sends the IFA (advertising ID). The ad server itself comes from this service. **Safe to block.** Home-screen and content-store ad tiles go away. |

### LG "ric" services (lgtvcommon.com / lgtviot.com)

| host | category | referencing components | notes / block impact |
|---|---|---|---|
| `videoacr.lgtvcommon.com` → `aic.videoacr.lgtvcommon.com` | **ACR + advertising** | `com.webos.app.overlaycontainer` (+ ex, hdmi1–4); appinfo `requiredEULA: "acrOn"`, window layer `videoAcrLayer` | Web app for commercial overlays on Live TV and HDMI, driven by ACR results. **Safe to block.** |
| `fooddelivery.lgtvcommon.com` → `aic.fooddelivery.lgtvcommon.com` | advertising/commerce (ACR-triggered) | `com.webos.app.fooddelivery` (+ ex, hdmi1–4) | Food-delivery overlay. **Safe to block.** |
| `nudge.lgtvcommon.com` | advertising/promotion | sdx (nudge_secure); Nudge QML, NudgeTriggerModel | Contextual promo and tip popups. **Safe to block.** |
| `recommend.lgtvcommon.com` | analytics/recommendation | sdx (recommend_secure) | Personalized recommendations, which use viewing history. **Safe to block.** Recommendation rows go empty. |
| `homeprv.lgtvcommon.com` | app store/content | sdx (homeprv_secure); home launcher previews | Home-row content previews. Blocking empties preview rows. |
| `service.lgtvcommon.com` | other (settings sync) | sdx (nlp_setting_secure, nudge_setting_secure, service_setting_secure) | Server-side settings for voice NLP and nudges. Optional. |
| `qt2-kic.service.lgtvcommon.com` | crash/diagnostic upload (**QA server**) | `usr/sbin/upnpd`: `curl -F file=@"%s" https://qt2-kic.service.lgtvcommon.com/service/uploadFile`, after tarring upnp logs and `top30` memory output | **Unexpected.** A debug log-upload path to a Korean QA host ships in the production binary. It is probably gated by a debug flag. **Safe to block.** |
| `cpv.lgtvcommon.com` | other (unknown, `rest/csi/`) | sdx (cpv_secure) | Purpose unclear ("CSI"). Optional. |
| `cdpsvc.lgtvcommon.com` | app store/content | sdx (cdp_service_secure); mock `https://kic.cdpsvc.lgtvcommon.com/launcher/index.html` | Content-discovery launcher. Optional. |
| `wau.lgtvcommon.com` | content recognition (on demand) | sdx (wau_secure); `usr/sbin/performer` → `/wau/v1.0/whoau/celebrities` | "Who are you": identifies actors on screen when the user asks. Blocking breaks that voice feature. |
| `netflixvoice.lgtvcommon.com` | voice assistant | sdx (voice_proxy_secure) | Voice-to-Netflix proxy. Blocking breaks voice search inside Netflix. |
| `imagesvc.lgtvcommon.com` (`qt2-kic.imagesvc…` in mocks) | content (image proxy) | fullhome mock data | Template only. Production host probably `aic.imagesvc.lgtvcommon.com`. Not added to the blocklist. |
| `api.lgtviot.com` → `aic.api.lgtviot.com` | IoT/ThinQ | sdx (iot); `iot-client` (`/v2.0/device/register`) | Home Dashboard / IoT device registration. Blocking breaks the ThinQ/IoT dashboard. |
| `aic.lgtviot.com` (`qt2-kic.lgtviot.com` in apps) | IoT/ThinQ auth | `iot-client` (`.lgtviot.com/hc_auth_uid`, `/hc_refresh_token`); homeconnect, partialview | Home Connect auth. Same impact. |
| `push.lgtviot.com`, `sports.lgtviot.com` | IoT push; third-party content (sports) | `sportsalarm`, sdx | Sports score alerts. Blocking breaks sports alerts. |
| `common.lgthinq.com` | IoT/ThinQ | `iot-client` (`/route`, x-country-code) | ThinQ routing. Breaks ThinQ appliance integration. |
| `lss.lgthinq.com` | IoT/ThinQ | `iot-client` (`/route`, LSSDomain, `-qa-` variant) | Same. |
| `kr.lgeapi.com` | account/auth (ThinQ OAuth) | `iot-client` (`/oauth/1.0/oauth2/token`) | Korean OAuth endpoint. Same impact. |
| `he-kr-qa-ai.lgthinq.com` | voice assistant (**QA server**) | `usr/sbin/lg.thinqai.adapter` | ThinQ AI QA host hard-coded in production. **Safe to block.** |

### LG update / connectivity / diagnostics / file servers (lge.com)

| host | category | referencing components | notes / block impact |
|---|---|---|---|
| `snu.lge.com` | **firmware update** | `usr/sbin/update` (`CheckSWAutoUpdate.laf`, `CheckSWManualUpdate.laf`, `SWDownloadStartLog.laf`, `SWDownloadEndLog.laf`, `DownloadResult.laf`) | Blocking stops automatic and manual update checks and the download start/end logging. USB updates still work. |
| `su.lge.com`, `su-ssl.lge.com`, `nsu.lge.com` (:5100) | firmware update (CDN/download) | `usr/sbin/update` (cdnUrl rewrite) | Blocking stops firmware downloads. |
| `snu-dev.lge.com` | firmware update (dev) | `usr/sbin/update` | Dev server. Harmless to block. |
| `lgtvonline.lge.com` | time/connectivity check | `etc/connman/main.conf` (`Ipv4StatusUrl`/`Ipv6StatusUrl`, `TakeDnsIpResolutionAsOnline=true`) | Captive-portal/online check. With a 0.0.0.0 answer, connman may still count the TV as online because DNS resolution alone counts. If you return NXDOMAIN instead, the TV may show "not connected to the internet" and turn off smart features. Test before keeping. |
| `aic-ngfts.lge.com` (+ `ngfts.lge.com`) | content/file server | `livepick-plus` (LGSHOPPING overlay JSON), `pbs` (TMS channel images, US), voice-framework NLP icons, sportsteamsettings | LG "global file transfer" CDN. Blocking breaks channel logos, voice UI icons and LG shopping overlay config. |
| `rone-aic.lge.com`, `rone-tv-aic.lge.com` (+ kic/eic/saic/cic) | crash/diagnostic (remote support) | `usr/sbin/remotediag` (`/remote/regist/remoteServiceTerms`) | LG remote support/diagnostics. The AIC endpoint is plain `http://`. **Safe to block** unless you want LG to diagnose the TV remotely. |
| `download.365care.lge.com` | crash/diagnostic + telemetry (commercial) | `care365.service/preman/remote/azure/info_service_handler.js` | LG 365 Care (business remote monitoring). Returns an `agentUrl` and uploads status to Azure IoT Hub and blob storage. Only active when an account number is enrolled. **Safe to block** for consumers. |
| `lsms.lge.com` | other (internal signing) | `usr/bin/linkemulator`, `liblinklgupdate.so` (scp to port 8001) | Factory/dev signing tool. Not contacted in normal operation. Not added to the blocklist. |
| `dlnadevicename.lge.com`, `webos.tv`, `opensource.lge.com`, `hlm.lge.com`, `collab.lge.com`, `gpro.lgsvl.com`, `wiki.lgsvl.com`, `source.lge.com` | noise | DLNA/WAM strings, licenses, code comments | Internal bug-tracker and wiki links or placeholders. Not endpoints. |

### ACR / advertising (third party)

| host | category | referencing components | notes / block impact |
|---|---|---|---|
| `prov-lg.alphonso.tv` | **ACR** | `usr/lib/libas.so.3.0.93` (Alphonso ACR SDK "git-lg-webos-5.0", loaded by `usr/sbin/acr2`) | Provisioning: returns the ACR fingerprint server, ports and business-logic server. acr2 restarts ACR when the IFA, `lmt` or `doNotSellMyPersonalInformation` settings change. **Safe to block.** |
| `eulacheck.alphonso.tv` | **ACR** | `libas.so` | ACR consent check. **Safe to block.** |
| `config-overlay-ads.alphonso.tv` | **advertising (ACR-driven overlays)** | `usr/lib/libaos.so.1.2.0` (overlay-ads-sdk; ConfigServe/OverlayServe with `?api_key=`) | **Safe to block.** |

### Voice assistants

| host | category | referencing components | notes / block impact |
|---|---|---|---|
| `lgtv2020-ncs-engusa-gwssl.nuancemobility.net` (+40 other locales) | voice assistant | `etc/palm/voice-framework.conf` | LG's own speech recognition, used by the Magic Remote mic button. Blocking breaks LG voice search. The other locales are unused in the US. |
| `alexa.na.gateway.devices.a2z.com` | voice assistant | `AlexaClientSDKConfig.json`, `libAVSGatewayManager.so` | Built-in Alexa. Blocking breaks Alexa. |
| `api.amazon.com` | account/auth (Login with Amazon) | `libCBLAuthDelegate.so`, `libdbwebsockets.so`, alexapr app | Needed for Alexa sign-in. Also used by many Amazon services, so I left it out of the blocklist. |
| `api.amazonalexa.com`, `uj1m60ida4.execute-api.us-east-1.amazonaws.com` (`/apiProxy/v1/alexaApiEndpoint`), `an5wuzatha.execute-api.us-east-1.amazonaws.com` (`/authorize`) | voice assistant | `amazon.alexapr` web app | Alexa app backends. |
| `qf56fmtf9e.execute-api.us-east-1.amazonaws.com` (`/prod/metrics`) | analytics/telemetry | `amazon.alexapr` (vendors bundle) | Alexa app metrics. **Safe to block.** |
| `device-metrics-us-2.amazon.com` (`/metricsBatch`) | analytics/telemetry | `usr/lib/libdcm.so.1.0.0` (Amazon Device Client Metrics) | **Safe to block.** |
| `a1xx3jgjdgpl39-ats.iot.us-east-1.amazonaws.com` (also eu-west-1, us-west-2) | voice assistant / IoT | `usr/sbin/amazon-alexa-vsk`, alexapr | Alexa Video Skill Kit (MQTT over AWS IoT). Blocking breaks "Alexa, turn on the TV" from Echo devices. |
| `d2na8397m465mh.cloudfront.net`, `piefs-pimms.amazonpmi.com`, `d14doz9…`, `d1gkjrhp…cloudfront.net` | voice assistant (APL assets) | amazon-alexa-adapter, libAPLClient, alexapr | Alexa visual cards and fonts. |
| `embeddedassistant.googleapis.com`, `oauth2.googleapis.com`, `accounts.google.com` | voice assistant; account | `usr/sbin/google-assistant-adapter` (OAuth client IDs `83514302522-…apps.googleusercontent.com`) | Built-in Google Assistant. Only `embeddedassistant` is in the blocklist. Blocking `accounts.google.com` or `oauth2` would break YouTube sign-in and other Google services. |
| `auth.dui.ai`, `tts.dui.ai`, `dds.dui.ai`, `lgjsapi.hezijia.com`, `lgvoiceweb.qun7.com` | voice assistant (China) | `libdangbeivoice.so`, `dangbei-adapter`, `com.webos.app.dangbei-overlay` | Dangbei/AISpeech stack for China models. Unused in the US, so safe to block. Notable: `auth.dui.ai/auth/device/register` uses plain HTTP. |
| `api.tv.duokanbox.com` | voice assistant / casting (China) | `liblblisten.so` (Xiaomi) | Unused in the US. Safe to block. |

### Third-party content, DRM, device recognition, misc

| host | category | referencing components | notes / block impact |
|---|---|---|---|
| `msolookup.quicksetcloud.com`, `rcl.ueiquickset.com` (`quicksetlite.svc`, plain HTTP) | IoT / device recognition | `usr/share/iconnectivity/UEIQSDB/cmd_bin.conf`, `cmd_zipir.conf`; homeconnect | UEI QuickSet: identifies connected set-top boxes and AV gear for universal control. This reveals your cable provider and devices. Blocking breaks automatic device setup for the Magic Remote. |
| `api.accuweather.com` | third-party content | AI board (fullhome `AIBoardInterfaces.qml`), partialview | Weather widget. |
| `images.sports.gracenote.com`, `akamai-b.cdn.cddbp.net` | third-party content | sportsteamsettings, sportsalarm mocks; voice `MusicSearchHandler.qml` | Gracenote images (team logos, album art). |
| `www.geoplugin.net` (`/json.gp`) | other (IP geolocation, **plain HTTP**) | `libcbe.so` (browser geolocation provider) | The browser's Geolocation API calls a third-party IP-geolocation service over HTTP. **Safe to block.** Sites lose geolocation in the LG browser. |
| `time.bora.net` | time | `libcbe.so` (`rdate -s time.bora.net`, open API service) | Korean RFC 868 time server. Harmless to block, because sdx also sets the clock from the SDP response. |
| `connectivitycheck.android.com` | time/connectivity check | `libdbwebsockets.so` (libwebsockets default captive-portal policy) | Probably the library default. Low impact. |
| `clients2.google.com` (`/cr/report`, `/service/update2/crx`), `safebrowsing.googleapis.com`, `clients3.google.com` | crash report / browser services | `libcbe.so` (Chromium 68) | Chromium's crash reporting, extension updates and Safe Browsing. Not added to the blocklist because these hosts are shared with other Google services. |
| `lge.perserv.seacert.com` | DRM/licensing | `usr/lib/mediadrm/libmarlin_plugin.so` | Marlin DRM personalization. Blocking may break Marlin-protected content, which is rare in the US. |
| `public-ott-nodrm.verimatrix.com` | DRM/licensing | `libViewRightWebClient.so` | Verimatrix VCAS provisioning (test keyfile URL). |
| `nemo.intertrust.com`, `www.octopus-drm.com`, `crl.marlin-tmo.com` | DRM (namespaces/CRL) | `libWasabi.so` | XML namespaces and CRLs. Not contacted as endpoints. |
| `tvoemstorage.blob.core.windows.net`, `image.xumo.com`, `w2te7br9-qvc-us.asset.cdn.remoco.tv`, `occ-0-…nflxso.net`, `lgad.cjpowercast.com.edgesuite.net`, `kic.cdpsvc…` | content (mock data) | `com.webos.app.fullhome/qml/AdaptationLayer/Dummy/Mockdata/*` | Mock responses. They show which CDNs the live home screen uses (LG Channels via Xumo, QVC, CJ ads). |
| `iris.actvila.tv`, `portal.actvila.tv`, `aitlauncher.10ft.itv.com` | content (other regions) | hybridtv-manager (Japan BML), iepg tests (UK) | Not used in the US. |
| Browser lists | content | otncabi `com.webos.app.browser/share/*.json` (default_history, recommended_sites, search_engines, spoof_urls, ads_block_list) | About 1,500 websites. They are only contacted if you browse to them. Excluded. |

## Notable / surprising findings

1. **Two ACR stacks.** The Alphonso SDK (`acr2` + `libas.so`, `prov-lg.alphonso.tv`) fingerprints what is on screen. LG's own overlay apps (`aic.videoacr.lgtvcommon.com`, `aic.fooddelivery.lgtvcommon.com`) need `acrOn` consent and draw on a dedicated `videoAcrLayer` over Live TV and every HDMI input. The SDP API also has a `sdp_check_acr` service. `acr2` watches the IFA, `lmt` (limit ad tracking) and `doNotSellMyPersonalInformation` settings and restarts ACR when they change.
2. **Viewing telemetry and crash logs**: `ibsstat.lgappstv.com/service/livetvwatch.json` (Live TV viewing), and `rdx2.lgtvsdp.com` for `log/normal` analytics and `log/crash`. Uploads are gated in code by the EULA and upload switches.
3. **The ad ID is sent to info.lgsmartad.com** (`?dns=&ifa=&ifa_type=`).
4. **QA and dev hosts hard-coded in production binaries**: `qt2-kic.service.lgtvcommon.com` (upnpd `curl` log upload), `he-kr-qa-ai.lgthinq.com`, `snu-dev.lge.com`, plus the IP `156.147.69.32:8080`.
5. **Plain HTTP** for `rone-aic.lge.com` (US remote diagnostics), `su.lge.com`, `nsu.lge.com:5100`, `lgtvonline.lge.com`, `www.geoplugin.net`, `rcl.ueiquickset.com` and `*.dui.ai`.
6. **Third-party IP geolocation** (geoplugin.net) is used by the built-in browser.
7. **The China voice stacks (Dangbei/AISpeech, Xiaomi) ship on the US image.** They are presumably inactive outside China.
