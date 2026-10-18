# LG OLED55CXPUA (webOS 5.6.2, fw 04.64.00, US) - UI app analysis ("why is it laggy")

Scope: com.webos.app.home, fullhome, livemenu, livetv, inputcommon, hdmi1-4, tvhotkey, notificationcenter, com.palm.app.settings, premium, voice.
Method: static reading only. Nothing executed. Labels: **[OBS]** = read directly in a file, **[INF]** = my inference.

Paths are relative to the extracted `rootfs.pak.unsquashfs/` (see `scripts/extract.sh`).
`A=$R/usr/palm/applications`

---------------------------------------------------------------------------
## 0. Headline findings

1. **The default home on this firmware is `com.webos.app.fullhome` ("New Home"), a 77 MB QML app** [OBS].
   `$R/etc/palm/defaultSettings.json` (~line 41300): `"defaultApps": {"home": "com.webos.app.fullhome"}`.
   The old launcher bar `com.webos.app.home` (2.9 MB) is still shipped and selectable ("Basic Home"). Both are in `BootTimeApps` and `CRIUSupportApps` (`$R/etc/palm/sam-conf-tv.json`), and both are preloaded in `criu` mode (`$R/etc/configd/layers/base/com.webos.service.preloadmanager.json`).
2. **Fullhome fires a burst of network work every time Home is shown**: shelf-config (3 s timeout), recommendation shelf POST, AI-board (weather + server cards), 4+ ad-slot requests (one with a streaming video ad via `MediaPlayer`), cp-list, IoT/ThinQ resource check, home-effect check, CMP consent-app launch. All go through `com.webos.service.sdx` / `com.webos.service.admanager`. See section 2.
3. **`homePromotion=off` is the only switch that cuts the ad slots in both homes**, but it does not stop the recommendation/shelf/AI-board fetches (those are gated by `refreshCPList` = network && generalTermsAllowed && provisioned) [OBS].
4. **Home Auto Launch can be flipped remotely by LG's server** unless the user has toggled it once in the menu: `checkHomeAutoLaunchValue` default = `"default"` makes `editableHomeAutoLaunchByServer=true`; inputcommon polls `sdp_secure/services` and writes `homeAutoLaunch` from the server item `auto_home_launch` [OBS].
5. **Live TV / HDMI inputs all run the same binary and QML (`com.webos.app.inputcommon`)**; it hosts channel banner, input banner, "nudge" triggers, Live Pick, the personal watch-log sender, and the ACR/ad-overlay/live-pick+ app-status subscriptions [OBS]. It is not itself a source of UI jank, but it is the component that reports channel/input to servers.
6. Heavy GPU/memory assets: fullhome ships 70.9 MB of PNG (4K set = 52.5 MB); single 4K PNGs of 3840x2160 and 3840x1320 are used as fallback banners with `cache:false` (decode cost 20-33 MB RGBA each) [OBS sizes, INF memory].

---------------------------------------------------------------------------
## 1. Per-app inventory

| App | Type / framework | Size (dir / main code) | Prelaunch / keepAlive / noWindow |
|---|---|---|---|
| home | `native`, QML host `/usr/bin/com.webos.app.home` (46 KB ELF, links libQt5Quick, libsnapshot-boot) loading `qml/main.qml`; Qt 5.9.6, QtQuick 2.7, interpreted (no .qmlc) | 2.9 MB dir; 132 QML + 4 JS = 1.25 MB source; 217 PNG = 0.78 MB | `visible:false`, `noSplashOnLaunch:true`, `supportQuickStart:false`; preload `criu` (extPolicy `full` if >=50 MB free); `KeepOnLaunchEx` list; `delayCloseWindowTimeout=2000` ms |
| fullhome | `native`, same host pattern `/usr/bin/com.webos.app.fullhome` (50 KB) | **77.4 MB**; 192 QML + 48 JS = 2.54 MB source (incl. 0.5 MB mock data); 640 PNG = 70.9 MB | same; launched at boot by `$R/lib/systemd/system/scripts/com.webos.app.fullhome.sh` with `{"snapshot":true},"preload":"full"` when `defaultApps.home==fullhome`, and it first `closeByAppId com.webos.app.home forceMode` |
| livemenu (Guide) | native QML | 5.3 MB; 123 QML + 1 JS = 1.45 MB; 257 PNG; 219 locale JSON | preload `periodic`/`partial`; in `CRIUSupportApps`; `hasPromotion:true` in appinfo [OBS] |
| livetv | native; `main` = `/usr/bin/com.webos.app.inputcommon` | 460 KB (assets and locale resources only; splash PNGs are ~18 KB each) | `bootLaunchParams {"boot":true}`, `supportQuickStart:true`, window-group owner with 14 layers incl. `acrLayer`, `videoAcrLayer`, `foodLayer`, `dmostLayer` [OBS] |
| hdmi1-4 | native; `main` = inputcommon | 188 KB each | same as livetv; hdmi1 is a BootTimeApp |
| inputcommon | native QML | 12.2 MB; 264 QML + 8 JS = 2.75 MB; 314 PNG; 3.5 MB EWS wav; 2.3 MB `screenBlocker/splashimage.png` | `supportQuickStart:true`, `noSplashOnLaunch:true`; BootTimeApp; CRIU |
| tvhotkey | native QML ("Local Control Panel") | 2.0 MB; 86 QML = 0.55 MB; 210 PNG | `defaultWindowType:"popup"`, `spinnerOnLaunch:false`; self-exits via 30 s `bgTimer` / 10 s `shortTimer` (`qml/main.qml:191-205`) |
| notificationcenter | **web (Enact/Moonstone, React 16.8.6)** | 8.6 MB (mostly 60+ `index.<locale>.html`); `main.js` 680 KB; `main.css` 135 KB; `snapshot_blob.bin` 2.9 MB | `usePrerendering:true`, `v8SnapshotFile` |
| com.palm.app.settings | **web (Enact/Moonstone, React 16.8.6)** | 28 MB; `main.js` **2.45 MB**; `main.css` 369 KB; `snapshot_blob.bin` 5.9 MB; 3.8 MB Korean font in assets | `usePrerendering:true`, v8 snapshot, `defaultWindowType:overlay`, `noSplashOnLaunch` |
| premium | web, thin loader (3 JS files, 44 KB) | 1.1 MB | `handlesRelaunch`, `visible:true`. **Not in US smart-service list** (see 1.3) |
| voice | native QML | 4.4 MB; 132 QML = 1.28 MB; 78 JSON | preload `oneshot`/`partial` 55 MB (`webos-preload-manager`); `KeepOnLaunch` list in `memorymanager-conf.json` |

### 1.1 Preload / keep policy [OBS] (cross-check only; other analysts own memory tuning)
- `$R/etc/configd/layers/distro/hd2160-normal/com.webos.service.preloadmanager.json`: `maxPreloadApp: 6`; home+fullhome `staticPriority 1`, `preloadMode criu`; netflix/youtube/browser/voice/vudu/amazon/livetv/hdmi1-4/livemenu/miracast/google.assistant/alexa preloaded `partial` or `semi-full`.
- `memorymanager-conf.json`: `KeepOnLaunch ["com.webos.app.systemmusic","com.webos.app.voice"]`, `KeepOnLaunchEx ["com.webos.app.home","com.webos.app.fullhome","google.assistant"]`, `KeepAlive ["...livehbbtv","...livedmost","...liveibb"]`.
- appinfo files contain no `keepAlive`/`noWindow` flags. "noWindow"-style behaviour is provided by `visible:false` + CRIU/preload `snapshot` (home: `lifeCycleController.preload = parsedParams.hasOwnProperty('preload') || parsedParams.parameters.snapshot === true`, `$A/com.webos.app.home/qml/main.qml`).

### 1.2 Key press routing [OBS]
`$R/usr/lib/qml/KeyFilters/systemUi.js:88-100`: Home short-press => `applicationManager.launch(defaultApps.home, {"launchType":"homeKey"})`; long-press with fullhome => launch most-recent app.

### 1.3 Premium (LG "Premium" discovery page)
- `$A/com.webos.app.premium/js/Loader.js`: calls `luna://com.palm.connectionmanager/getstatus`, then `luna://com.webos.service.sdx/getHttpHeaderForServiceRequest`, builds host `<region>.lgrecommends.lgappstv.com/discovery_2016/discovery.html`, and **auto-submits a form with the sdx device-header JSON** (X-Authentication / X-Device-ID / X-Login-Session / cookie deleted first). Retries with 1 s `setInterval` up to 5x. Only runs when opened.
- US smart-service list (`$R/etc/configd/layers/smartservicecountry/USA/com.webos.applicationManager.json`) = `com.webos.app.today, netflix, hulu, vudu, amazon.html, youtube.leanback.v4, skype`: no premium. Premium appears in ~160 other country lists (e.g. XAC). So it is irrelevant for a US set [OBS]. `com.webos.app.today` has no directory in this image [OBS].

---------------------------------------------------------------------------
## 2. Launch/show behaviour and network activity

### 2.1 com.webos.app.fullhome (default Home) - [OBS unless marked]
Lifecycle: `registerApp` + `getAppLifeStatus` subscribe; each show triggers `uiController` intro (`AIBoardIntro.qml: global_duration 2400`), 8000 ms `dismissTimer` (`UIController.qml:758`), 5 s error-check timer while not ready (`AppInitializer.qml:119`).

Luna/network on launch (files under `$A/com.webos.app.fullhome/qml/`):

| What | Call | Gate / timing |
|---|---|---|
| Shelf layout from LG | `sdx/send {serviceName:"service_setting_secure", url:"getConfig", bodyData:{"requester":"ai_home"}}` (`Interfaces/AppInterfaces/AppInterfaces.qml:195-225`) | if no cached `shelfListDataSDX`; **3 s timeout** `shelfListResponseTimer` then falls back to `Model/Constants.js` defaults. `ShelfList.init` also waits `uiController.introRan` via `doDelayAction(...,100)` |
| Recommended shelf | `sdx/send {serviceName:"tlamp_secure", url:"v1.0/recommendShelf", bodyData:"shelfId=HOME_SH_RECOMMENDED&epgCodeList=$epgCodeList&domain=tvshow,movie,epg"}` (`Model/Constants.js`, `Interfaces/RecommendInterfaces/AppServices.js`) | `epgCodeList` = user's channel-code list minus current channel (`RecommendInterfaces.qml getRecommendParam`) => **leaks the user's channel lineup and last channel** |
| CP list | `sdx/send sdp_secure content_discovery/cp-list` | on `refreshCPList` |
| Other shelf providers | `sdp_secure editorsPick`, `tlamp_secure ... HOME_SH_LGRECOMMEND_1/2` | only if server shelf list includes them |
| Hero/sponsored/inline ads | `admanager requestBannerInfoWithoutContextIndex` for slots `Portal/HomeBigCarousel@Main` (hero, `Hero.qml:27`), `Portal/HomeRecommend@Main`, `Portal/HomeRecommend1@Main`, `Portal/HomeSecondLine@Main` (inline), WEE variants `HomeRecommend{1..4}Wee2`, `HomeTopRowWee2`, `HomeBigCarouselWee2`; then `sendImpressionTracker` (`creativeView`, `hovering`, video `complete`), `requestAssetClickInfo`, `launchCMPApp` (`Interfaces/PromotionInterfaces/*`, `Interfaces/AdvertisementInterfaces`) | `showPromotionTile = homePromotionOn && networkConnected && eulaStatus.generalTermsAllowed` (`AppInitializer/SystemProperties.qml:64`). **Retry timers: 4x `retrySponsoredAdTimer` every 1 s, up to 9 retries each** on "not ready"-type errors (`PromotionInterfaces.qml:86-150, 247-290`). Hero ad can be a video: `MediaPlayer`+`VideoOutput` (`Hero.qml:354-461`), 5 s slide timer, 5 s `checkAdRequestStatus` |
| AI board / weather | `sdx/send service_setting_secure getAiBoard {"requester":"ai_board"}`; AccuWeather over XHR: `https://api.accuweather.com/currentconditions/v1/<key>.json`, `/forecasts/v1/daily/5day/<key>`, `/locations/v1/cities/autocomplete` (`Interfaces/AIBoardInterfaces/AIBoardInterfaces.qml:520-700`; API key comes from the server card `optionParam.apiKey`). `setSystemSettings other.weatherAllowed=true` after the user allows weather | Location is only the user-picked `locationKey` (`com.palm.preferences getAppProperty key:"location"`). `getLocationInfo(clientIP)` (IP-based lookup) is **defined but never called** [OBS grep]. Board rotation `refreshInterval` from server; `AIBoard.qml loadingTimer 10 s` then default board |
| Home Dashboard / ThinQ / IoT | `sdx/send sdp_apps_secure app/appResource body "app_info=homeconnect20mr.resource.2nd"` (version check, may download `AppRes.json` via downloadmanager); `iotclient discover/getConnectedDevices`; ThinQ status refresh `Timer interval: thinQRefreshTime` = **20000 ms, repeat:true** (`AppRes.js` setting `"thinQRefreshTime":20000`; `IotInterfaces.qml:900`) [timer only meaningful if ThinQ devices exist - INF] | on launch if `mustDownloadAppRes` |
| App preview rows | `applicationManager getContents/getAllContents` (apps push "recommended content" rows via SAM), remote preview images cached to `/tmp/launcher/cache/` (`ImageCacheInterfaces.qml:23`), cache **deleted on power-off request** (`watchPowerStatus ... "Request Power Off"`) so rows re-download after every boot | on hover/preview |
| User behaviour ranking | `usercontextmanager getRank/getSubRank/getChannelRanking` (local UCM) | home + shelves |
| Home effect | see 2.2 | `homeEffect==on` |

Normal-log (PmLog) events emitted by Home: `NL_HOME_SHOWN {foregroundId, launch_type}`, `NL_APP_LAUNCH`, `NL_PREVIEW_ENTERED`, `NL_PREVIEW_CONTENT_LAUNCH {app_id, content_id, category, title}`, `NL_PROMOTION_FOCUSED {asset_id}`, `NL_SHELF_HOMEDASHBOARD_CLICKED`, YouTube-channel events (`Debug/UserLogger.qml`). `foregroundId` = the app you were in when you pressed Home [OBS]. These land in the log pipeline other analysts cover.

Shelf composition [OBS `Model/Constants.js`]: `HOME_SH_TOP`(hero/ads) , `HOME_SH_RECOMMENDED` (with `adSlotData` slots + `slotIndex [3]`/`[3,4]` = sponsored tiles injected at positions 3-4), `HOME_SH_APPS`, `HOME_SH_HOMEDASHBOARD` (`com.webos.app.homeconnect`), `HOME_SH_INLINEADBANNER`. `uneditableShelfList` (`SystemProperties.qml:85`) = EDITORSPICK, LGRECOMMEND_1/2, **RECOMMENDED, TOP, APPS, INLINEADBANNER**: user cannot remove the recommendation, hero or inline-ad shelves with the Edit mode; HOME_DASHBOARD is editable [OBS].

Fallback when promotion is off or no ad: `MainView.qml:196-206` loads `banner_image_02.png` (3840x1320) / `bg_network.png`; `Hero.qml:686 banner_image_03.png` (3258x840); both `cache:false`, `sourceSize: Qt.size(width,height)` set on the first [OBS]. Biggest assets (4K set): `home_network_bg.png` 3840x2160 10.6 MB (unreferenced in QML by grep - INF dead asset), `banner_image_03.png` 4.1 MB, `bg_banner_img*.png` ~3.3-3.7 MB, `banner_image_02*.png` 3.5 MB, `bg_network.png` 3.4 MB, weather backgrounds `AIBoard/W_*.png` 1354x762 ~1 MB each.

Animations/timers [OBS]: shelf/ribbon move `duration: 1200` InOutCubic (`MainRibbon.qml:314,329`), sub-ribbon translate 400, show 300, pop-out 240, remove 250 (`GlobalStyle.qml:248-273`), most others 50-200 ms. Hero slide 5 s, `TimeManager` 1 s tick, `Selectable` 30 ms timer, 10 s `thinq/OCF` timers. Intro 2.4 s. The 1.2 s ribbon move is the longest user-visible motion; only runs when add/remove/edit.

### 2.2 Home Effect (seasonal effect resources) [OBS]
`$A/com.webos.app.home/qml/Controllers/EffectInterfaces/Interfaces.qml` (same pattern in fullhome): on every launch if `general.homeEffect=="on"`: `sdx/send sdp_secure services` -> if `home_effect` switch on -> `sdx/send service_setting_secure getConfig {"requester":"home_effect"}` -> **synchronous** `XMLHttpRequest HEAD` on `/mnt/lg/cmn_data/effect/home_effect/...` (`checkUrlExists`, `xhr.open('HEAD', url, false)`) -> possibly `deleteEffectFiles` + `downloadmanager download` of main/sub/images/particles into `/mnt/lg/cmn_data/effect/home_effect/`, 5 s settle timer. Key has **no menu entry** (`homeEffect` absent from settings `main.js`) => luna-only.

### 2.3 com.webos.app.home (Basic Home / launcher bar) [OBS]
- One ad: `Controllers/PromotionInterfaces/Interfaces.qml`: on `uiController.onAppLaunched` -> `requestBannerInfoWithoutContextIndex {slotName:"Portal/HomeCompanion@Main", width:300,height:250, autoSend:false}`; 5 s timeout; impression trackers `creativeView`/`hovering`; plus per-app-preview ads (`AdvertisementController.qml`, `autoSend:true`, slot = `previewData.promotionId`) when an app's second-level row contains `type=="advertisement"`.
- `showPromotionTile = homePromotionOn && networkConnected && generalTermsAllowed && supportsPromotion` (`SystemProperties.qml:48`); `supportsPromotion` = `getSystemSettingDesc general.homePromotion ui.visible`.
- Settings subscribed (`AppInitializer/SystemServices.qml:143-151`): option{audioGuidance, smartServiceCountryCode2/3, country, countryGroup, **zipcode, addressInfo**, menuTransparency, channelplus}, channel.recommended, eulaStatus, general{lastInputApp, homePromotion, launchEulaByHome, homeEffect}, other{simplinkEnable, homelegalPopup}, hotelMode.
- Also: Effect check (2.2), IoT resource check (`mustDownloadAppRes`, `sdp_apps_secure app/appResource`), `uiController.cmpAppLaunch()` => `admanager launchCMPApp {forceStatus:false}` whenever Home is shown (not boot) with network and no pending EULA (`UIController.qml:444-449`).
- Imaging: 217 small PNGs (0.78 MB total); remote preview images through same `/tmp/launcher/cache`.
- Animations: sub-ribbon translate 400 ms, main hide 400 InOutCirc, pop-out 240, MainRibbon move/displaced 1200; `ThinQ` refresh 20 s timer (`thinQRefreshTime`).
- Net assessment [INF]: Basic Home is far lighter than fullhome: no hero/video ad, no weather/AI-board, 1 ad slot instead of 5-6, 2.9 MB vs 77 MB.

### 2.4 com.webos.app.inputcommon (= livetv, hdmi1-4 UI) [OBS]
Luna surface: ~170 distinct service/method pairs (channel/iepg/dvr/ci/eim/cec/audio/surfacemanager...). Items relevant to leakage/UX:
1. **Home Auto Launch controller** (`Model/HomeAutoLaunchModel.qml`): after power-on-by-key and banner ready, if `isHomeAutoLaunch && !hasHomeConstraint(avmsd) && !storeMode && !eula && !ews` => `applicationManager launch defaultHomeApp {"activateType":"powerOn"}`. Also, when `appActivate && networkConnection`, it checks `sdx/send sdp_secure services (REQ_SSL_GET_METHOD)` and **applies server items `auto_home_launch` and `avmsd`** (writes `general.homeAutoLaunch`, `general.avmsd`, and `setSystemSettingDesc homeAutoLaunch ui.visible`). `SettingPropertyService.qml:881-885`: `checkHomeAutoLaunchValue === "default"` => `editableHomeAutoLaunchByServer = true`; any other value (the menu writes `"user"` when you toggle it: settings `main.js` `"homeAutoLaunch"===e.key && (o.settings.checkHomeAutoLaunchValue="user")`) => server cannot change it. Default file value: `"checkHomeAutoLaunchValue": "default"`, `homeAutoLaunch "on"` (`defaultSettings.json`; country block `"default": aiNudge on/homeAutoLaunch on`, `JPN: off/off`).
2. **Personal watch log** (`Model/PersonalDataLogModel.qml`, `Service/PersonalDataService.qml`): after each channel change (random delay 10-20 s: `minTime 10000 + rand(10000)`), `sdx/send {serviceName:"ibis_stat_secure", url:"sdp/livetvwatch.json", POST}` body `chan_name, chan_code, device_src_idx, dtv_standard_type, accept_flag, zipcode, timezone, user_id (pbsw deviceUniqueId), channel_change, prev_chan_code`. STB variant adds `content_id`, `from_where` (ACR/SCD/UEI detected) and is **enabled for USA and KOR** (`_getEnableCountryForStb`). Gated by pbsw flags `watchFlag/ipWatchFlag/stbAcrWatchFlag/stbScdWatchFlag/stbUeiWatchFlag` + `livetvwatchEula` (the "Viewing Information" agreement) and server `*_activation_flag` replies.
3. **Nudge / "Content Recommendations"** (`Model/NudgeTriggerModel.qml`, `Service/NudgeTriggerService.qml`): `com.webos.service.nudge getNudgeState/requestNudge`, `usercontextmanager getRankFromServer/getHistory` for nudges `nu_ch_zapping`, `nu_ch_watch_tv_n_times`, `nu_watch_tv_live_ott`, `nu_watch_tv_end_1`, `nu_input_STB`, `nu_input_game`, `nu_object_audio`, `nu_sport_alarm`, `nu_livepick`. Triggers on channel zapping (10 changes/30 min), 10 s dwell (`zappingValidTime`), program end (2 min before end, 56-day history query). US blacklist (`$R/etc/configd/layers/country/USA/com.webos.service.nudge.json`): `nu_amazon_entry, nu_tv_on_1, nu_ch_zapping, nu_watch_tv_end_1, nu_tv_on_magic, nu_watch_tv_live_ott, nu_object_audio` - so in the US the remaining active ones are `nu_ch_watch_tv_n_times`, `nu_input_STB`, `nu_input_game`, `nu_sport_alarm`, `nu_livepick` [OBS list diff; INF which actually fire]. Setting key: `general.aiNudge` (default on).
4. **Live Pick / ACR-adjacent**: `LivePickService.qml` (`com.webos.service.livepick isSupport/isPickable/checkInformation/channelChanged`, `com.webos.service.capture executeOneShot` = screen capture), `AppManagerService.qml` `acr launchApplication {multiview, liveZoom, source:"liveTV"|<inputType>, broadcastId}`, subscriptions to `com.webos.service.adoverlay getAppStatus` and `com.webos.service.livepickplus getAppStatus` when app is activated (`ForegroundAppInfoModel.qml:176-195`). **So the current input name ("liveTV", "HDMI1"...) is handed to the ACR service by this UI** (ACR pipeline itself is another analyst's area).
5. EPG-guide recommend (`Service/SdpService.qml`): `sdx/send sdp onnow2/live_menu/recommend/` and `search/livemenu/retrieval.json` with the full channel `ibis_valuelist` - helper defined; I did not find a caller on the normal path (INF; not verified).
6. Timers: channel/input banner auto-hide 5 s, mini banner 5 s with OLED burn-in refresh 2 min (`ChannelBannerMini.qml:150`), DVR bar 1 s, `LivePickContents` 1 s. No HTTP URLs in code except one CP-logo URL in a comment; no `XMLHttpRequest` to the internet (the 5 XHR in `NudgeTriggerModel` read local `/usr/share/nudge/*.json` and `/mnt/lg/cmn_data/nudge/`) [OBS].
7. Heavy assets: `Images/screenBlocker/splashimage.png` 1920x1080 2.3 MB; `TvComponent/Ews/resources/2Khz_Mute5_400ms_New_audacity.wav` 3.5 MB; otherwise small.

### 2.5 com.webos.app.livemenu (Guide) [OBS]
- Local EPG only: `iepg getChannelList/getEventList/getCurrentNextEventList`, `utp.channel`, `tvReservationAgent`, `cbox`/`reclistmgr` for recordings; `fepg` (Freeview Play, UK only).
- Only network call: `sdx/send sdp_secure content_discovery/item-detail` when a program Detail popup is opened (`Controllers/ProgramInfoInterfaces/Interfaces.qml:744-766`): body `item_type=EVENT&item_id=<id>&item_detail_type=exec_full&ibis_device_source_type=1&ibis_valuelist=<your channel list>&ibis_timezone=<GMT+x>&ibis_max_hours=24&z_client_type=com.webos.app.livemenu`. That discloses the programme you open plus your lineup.
- Launch: `uiController.transitionDuration` = 150 ms (`UIController.qml:41`), `directGuideLaunch ? 1 ms`; `ChannelList` highlight move 1 ms; `TabMenu` hide 5 s, select 1200 ms; `main.qml:140` 5 s error-check; `TimeManager` 1 s. Fast.
- `livemenu.service` (systemd) only resets `option.liveMenuLaunched=false` at boot.

### 2.6 com.webos.app.tvhotkey [OBS]
On-demand popup (Q-menu-like panels: customer support, sleep timer, subtitle, multi-audio, FreeSync info, energy saving). Network: `sdx/send service_setting_secure getRemoteConfig {"broad_country":"..."}` only when the Customer Support panel opens (`customersupport/CustomerSupportServices.qml:347`) to learn whether "remote service" is available. Timers: exit after 30 s/10 s, 50 ms repeat only while a list is scrolling. Animations 50-300 ms. Not a lag source.

### 2.7 com.webos.app.notificationcenter [OBS]
Only `com.palm.db find/search/watch/del/putKind`, `applicationManager getAppInfo/launch`, `settingsservice getSystemSettings`. No http URLs. Prerendered + snapshot. Not a lag source (cost = 680 KB JS parse, mitigated by snapshot).

### 2.8 com.palm.app.settings [OBS]
Enact/Moonstone 16.8.6, 2.45 MB bundle; opens with large `settingsservice batch` subscriptions (general keys: lastInputApp, adCookie, screenSaver*, personalRecommend, aiNudge, homePromotion, alwaysOn*, tvOnScreen, tvOnSound, welcomeFeature, blueToothSpeakerMode, homeAutoLaunch, defaultApps, lmt, doNotSellMyPersonalInformation, avmsd, nativeConsentAd). Luna targets include admanager (`updateDNS`, `resetIFA`, `launchCMPApp {forceStatus:true}`), `sm/deviceid getIDs` (IFA), update, wifi, bthid. No third-party http URLs. Settings is not a network-on-launch app; its sluggishness is JS/React + large snapshot (INF).
Home Style handler (`main.js`, `generalData`): `latestHome` => `general.defaultApps.home=com.webos.app.fullhome`; `basicHome` => `com.webos.app.home`; then `closeByAppId` forceMode for the other [OBS].

### 2.9 com.webos.app.voice [OBS]
Voice key / "Hi LG" launch only (`params {"activateType":"home","launchMode":"vkb"}`, `handlesRelaunch:true`, preload oneshot partial 55 MB). Server calls on query: `sdx/send sdp_secure content_discovery/amuguna/LIVE`, `content_discovery/item-detail` (body includes `ibis_valuelist=<channel code list>`, `z_client_type=WTV_NLP`), app detail/recommend, search popular keywords (`Services/SdxService.qml`); plus `voiceconductor`, `nlpmanager`, `musicrecognition`, `voiceinput` (long-distance mic activation `setting/getActivation`, key `general.voiceLongDistance` default `on`). Timers short (<=4 s); no polling. Not a lag source; privacy relevant only when used or when long-distance voice is on.

### 2.10 ScreenCover (compositor component, outside the requested list but affects power-on) [OBS/INF]
`$R/usr/lib/qml/ScreenCover/Containers/PowerOnWithEffect.qml`: intro of ~18 s of animation (7000 ms pause, 2500+2000+2500+2500+3000 ms, logo at 13000 ms, 3000 ms fade-out) with `setInputBlock(true)` when `general.tvOnScreen=="effect"` (default) and `reason=="powerOn"`; power-off effect up to 5000 ms. The images (`signature_r_logo*.png`) suggest a SIGNATURE-series feature; I did not confirm it is active on a CX [INF]. `powerOnScreen` has no consumer anywhere in the image (grep), only in settings DB/description [OBS].

---------------------------------------------------------------------------
## 3. Setting keys that control all of this

All via `luna://com.webos.settingsservice/setSystemSettings {"category":"general","settings":{...}}` unless stated. Defaults from `$R/etc/palm/defaultSettings.json` (general block ~L41280-41331).

| Key | Default | What it gates | Menu |
|---|---|---|---|
| `homePromotion` | on | home `showPromotionTile` (all ad slots, hero, sponsored tiles, inline banner, impression trackers) | General > Home Settings > Home Promotion |
| `homeAutoLaunch` | on (JPN off) | open Home automatically at power-on (inputcommon) | General > Home Settings > Home Auto Launch |
| `checkHomeAutoLaunchValue` | "default" | `"default"` lets server override `homeAutoLaunch`; `"user"` pins it | set automatically when you toggle Home Auto Launch |
| `defaultApps.home` | com.webos.app.fullhome | which home is used | General > Home Settings > Home Style (New Home / Basic Home) |
| `homeEffect` | on | seasonal-effect download/check at each Home launch | none (luna only) |
| `aiNudge` | on | nudge toasts / UCM server rank queries | General > AI Service > AI Recommendation > Content Recommendations |
| `personalRecommend` | off (`changedByUser:false`) | "Network-Based Personalization Recommendations" | General > AI Service > AI Recommendation |
| `adCookie` | on (desc ui visible:false, active:false) | ad cookie; settings page titled "Advertisement" | General > Additional Settings > Advertisement (visibility depends on runtime desc - not verified) |
| `lmt`, `doNotSellMyPersonalInformation` | off, off | Limit AD tracking; DNS (admanager `updateDNS`) | Advertisement page |
| `customizedAd` | off | customised ads | none seen |
| `screenSaverAd` | on | ads on screen saver from LG Channels / Content Store | General > Additional Settings > Screen Saver Promotion |
| `sportsAlarm` | on | sports alert + sports preview row | Sports Alert (not traced) |
| `welcomeFeature` | on | welcome sound/feature | General > Additional Settings |
| `tvOnScreen` / `tvOnSound` | effect / low | ScreenCover power-on effect | uncertain on CX |
| `voiceLongDistance` | on | far-field voice listening | Voice settings |
| `option.livePlus` | (not in defaultSettings general) | ACR/"Live Plus" consent | General > Additional Settings > Live Plus |
| `option.livePromotion` | - | Live Promotion (ad overlay on live content; "available when Live Plus is on") | General > Additional Settings > Live Promotion |
| `option.quickStartMode` | - | Quick Start+: standby resume | General > Additional Settings > Quick Start+ |
| `other.weatherAllowed` | - | weather card consent | Weather card on Home |

Menu paths are derived from the settings bundle's `titleMap`/component names and are **[INF] for exact breadcrumb order**; setting keys and labels are [OBS].

---------------------------------------------------------------------------
## 4. Prioritised recommendations

Ordered by (UI-lag benefit x certainty) / risk.

### P1 - Switch Home Style to "Basic Home" (`defaultApps.home=com.webos.app.home`)
- Menu: Settings > All Settings > General > Home Settings > Home Style > Basic Home [INF path; label OBS]. Rooted: `luna-send -n 1 luna://com.webos.settingsservice/setSystemSettings '{"category":"general","settings":{"defaultApps":{"home":"com.webos.app.home"}}}'` then `luna-send -n 1 luna://com.webos.applicationManager/closeByAppId '{"id":"com.webos.app.fullhome","forceMode":true}'` (the menu does the same).
- Benefit: removes the 77 MB / 2.5 MB-source app, the hero video-ad player, 4-6 ad slots, AccuWeather/AI-board/recommend/shelf-config fetches, and the 4K fallback PNGs. Basic Home does one promotion tile + preview rows. Expected: the largest reduction in Home open time/stutter and in per-show network chatter [INF on timing; OBS on content].
- Risk: lose full-screen shelves/weather/AI board; Basic Home still has one ad tile (turn off with P2). Reversible. Option is only shown if `defaultApps` desc `ui.visible` (settings code `a=...defaultApps.ui.visible`).

### P2 - Home Promotion = Off
- Menu: General > Home Settings > Home Promotion. Rooted: `... '{"category":"general","settings":{"homePromotion":"off"}}'`.
- Benefit: stops every `admanager requestBanner*`/`sendImpressionTracker`/`requestAssetClickInfo` in both homes; removes the 3 retry loops of 1 s x 9 per slot; no hero video. [OBS gating]. Cuts the "what you hovered/clicked" impression leakage.
- Risk: none functionally. On fullhome the hero is replaced by a static 3840x1320 PNG (`banner_image_02.png`, `cache:false`) which is a one-off decode; acceptable. Does not stop recommendation shelf POSTs (see P6).

### P3 - Home Auto Launch = Off (toggle it in the menu, do not just set the value via luna)
- Menu: General > Home Settings > Home Auto Launch. Rooted: `'{"category":"general","settings":{"homeAutoLaunch":"off","checkHomeAutoLaunchValue":"user"}}'`.
- Benefit: no home launch + ad burst at every power-on; TV goes straight to last input; prevents LG's server flipping it back on [OBS `HomeAutoLaunchModel.qml`, `SettingPropertyService.qml:881`]. Also avoids the `nu_tv_on_1` nudge that proposes enabling it (already blacklisted in US).
- Risk: need Home key to reach apps; low.

### P4 - Home Effect off (rooted only)
- `'{"category":"general","settings":{"homeEffect":"off"}}'`.
- Benefit: removes at each Home launch two sdx round-trips, a **synchronous** `XHR HEAD`, and possible file download/delete in `/mnt/lg/cmn_data/effect/home_effect/` [OBS]. Low gain but zero downside.
- Risk: lose seasonal effects.

### P5 - AI Recommendation: Content Recommendations off (+ keep Network-Based Personalization off)
- Menu: General > AI Service > AI Recommendation. Rooted: `'{"category":"general","settings":{"aiNudge":"off"}}'`.
- Benefit: stops nudge evaluation on every channel change/dwell, `usercontextmanager getRankFromServer`, and nudge toasts/popups over the picture (`NudgeTriggerModel`). Reduces inputcommon work on zapping [OBS triggers; INF effect size].
- Risk: lose "suggested channel/app" toasts. Low.

### P6 - Reduce server-facing recommendation traffic (needs rooted/network layer, no menu)
- The recommendation shelf (`tlamp_secure/v1.0/recommendShelf` with `epgCodeList`), shelf config, cp-list and AI-board are gated only by `refreshCPList`. Menu-only users cannot disable them except via P1. Rooted options: block the hosts behind sdx `tlamp_secure`/`service_setting_secure`/`sdp_secure` (hostnames are another analyst's inventory) at the router/DNS. Fullhome degrades to its built-in defaults after the 3 s shelf timeout (`shelfListResponseTimer`) - so **blocking makes each Home open wait up to 3 s once** unless the response fails fast [OBS timer; INF behaviour]. Prefer P1 instead (Basic Home does not do these fetches).
- Risk: medium (blocking can add a 3 s wait, break app-resource/IoT updates and weather).

### P7 - Ad/ID privacy toggles
- Advertisement page: Limit AD Tracking = on (`lmt`), Reset AD ID (`admanager resetIFA`), Do Not Sell My Personal Information = on (`admanager updateDNS`). Screen Saver Promotion = off (`screenSaverAd`). Live Promotion = off (`option.livePromotion`). Live Plus = off (`option.livePlus`) - also revoke "Viewing Information" agreement to stop the personal watch log (pbsw flags `watchFlag`, `livetvwatchEula`, `stbAcrWatchFlag` ...) [INF that revoking turns off `livetvwatch.json` POSTs; OBS that they are gated by those flags].
- Benefit: reduces ad requests and reporting of channel/zip/timezone/last-channel to `ibis_stat_secure`; secondary effect on UI lag is small.
- Risk: Live Plus off disables features (Live Pick, personalised services). Low-medium.

### P8 - Quick Start+ (optional)
- General > Additional Settings > Quick Start+ (`option.quickStartMode`). `supportQuickStart:true` on livetv/hdmi/inputcommon means those apps can resume. Benefit: faster power-on; cost: standby energy (help text in settings: "Energy consumption may increase"). Risk: low but affects "power off" semantics.

### P9 - Do not touch / low value
- livemenu, tvhotkey, notificationcenter, voice, premium (not in US), hdmi/livetv shells: no network-on-launch or polling beyond short timers [OBS]. Nothing worth changing for lag.
- Image cache lives in `/tmp/launcher/cache` and is wiped on power off, so first Home open after boot always re-downloads preview/ad images [OBS]. Basic Home reduces but does not remove this.

---------------------------------------------------------------------------
## 5. Limits of this analysis
- Server responses are not in the image, so which shelves/slots/nudges are actually delivered to a US CX is unknown (INF).
- "Laggy" cost estimates (decode MB, wait times) are inferred from file sizes/timers, not measured.
- Menu breadcrumb order is reconstructed from the bundle; labels and setting keys are verbatim.
- I did not analyse homeconnect (Home Dashboard back-end app), igallery, firstuse, eula, or the settingsui Node service beyond reading key names.
