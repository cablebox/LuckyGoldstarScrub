# LG OLED55CXPUA (webOS 5.6.2, 04.64.00, o20) – UI performance analysis

Static analysis only. Nothing from the firmware was executed. All paths are relative to
`rootfs.pak.unsquashfs/` unless prefixed otherwise. `bsp/` = `bsppart-atsc.pak.unsquashfs/bsp/`.

Tags used below:
- **[Observed]** means the config or file content was read directly.
- **[Inference]** means a conclusion drawn from the configs, not confirmed on a running TV.

---

## 0. Key correction: this image runs **systemd**, not upstart

- `sbin/init -> ../lib/systemd/systemd` **[Observed]**
- The 159 `etc/init/*.conf` upstart jobs are **legacy leftovers**. systemd does not read them. The real
  units are in `lib/systemd/system/` (346 entries), `etc/systemd/system/` (176 entries) and
  `bsp/etc/systemd/system/` **[Observed]**.
- `sbin/initctl` is a 34 KB LG shim that links `libsystemd` (`Systemd::startUnit` symbols)
  **[Observed]**. On a rooted TV, use `systemctl`. Do not rely on `initctl stop`.
- bootd (`usr/sbin/bootd`, `etc/palm/bootd.json`) drives boot stages as systemd targets
  **[Observed]**. The mapping of names to stages is **[Inference]**:

| bootd signal | systemd target | examples of units started (`*.target.wants`, lib + etc) |
|---|---|---|
| datastore-init-start | `webos-dis.target` | db8, db8-pre-config, settings-service, luna-sys-service, livemenu, multiview |
| core-boot-done | `webos-cbd.target` | fullhome, eim, audiod, BT stack (bluedroid, webos-bluetooth-service, btaudiosrc), lginput2, tts, voiceinput, kdump, tv-reservation-agent, emmcd, soundshare, apluspolicymanager, snapshot-boot-resume |
| init-boot-done | `webos-ibd.target` | **webapp-mgr**, connman, wpa-supplicant, pulseaudio, pm-klog-daemon, jail, gst-registry, certupdmgr.timer, eplmanager |
| minimal-boot-done | `webos-mbd.target` | umediaserver, notificationmgr, rdxd, crashreportd, securitymanager, contentminer, voiceconductor, devmode, ssc, update, maliit-server, airplay-adaptor, avahi, mdnsd |
| rest-boot-done | `webos-rbd.target` | activitymanager, appinstalld, dmr, iot-client, luna-download-mgr, memchute-ready, ssdp-discovery-lgtv, tvlinkcmdprocessor, bugreportd, dropbear, cpuchart |
| boot-done | `webos-bd.target` | **preload-manager**, aiservice, user-context-manager, nudge, miracast, second-screen-gateway, tvlink-network-proxy, webos-sddp, klog-formatter, bluetooth-dot-service, uploadd, criu_copy_img, dmost, lebo, partialview, iepg-ping-fepg |

Early targets (`default-webos`, `default-starfish`, `local-fs-pre-starfish`, `mount-rw`,
`pre-rw-mount-done`) start ls-hubd, configd, sam, surface-manager, booster, memchute, crashd,
PmLogDaemon, remotelogger, tvrm, gm, lginit-app/webos-tv (the LG tvservice), audio/video output
daemons, tvservicemock, factorymanager, iepg, sleepd, etc. **[Observed]**

Counted over all these targets: **178 wanted units: 117 long-running, 55 oneshot, 6 dangling**
(`leaktracer`, `livepick`, `musicrecognition`, `cis`, `event-device-creator`,
`broadcast-acas-downloader` have no unit file) **[Observed]**. Some are gated by
`ConditionKernelCommandLine` (factory, bluetooth vendor variant). On top of this, the bus starts
about 90 "dynamic" luna services on demand (`usr/share/luna-service2/services.d`,
`usr/share/dbus-1/system-services`) **[Observed]**.

Writable locations that matter for persistent tweaks **[Observed]**, from
`etc/systemd/system/scripts/webos-relocate-rootfs-writable-content-to-flash.sh`:
- `/var` is a bind mount of `/mnt/lg/cmn_data/var` (ext4, persistent). `/home` is a bind mount of `/mnt/lg/cmn_data/home` (persistent).
- `/tmp`, and `/tmp/var/log` (= `/var/log`, which is **ramfs**, see §6), are volatile.
- Almost every unit has `EnvironmentFile=-/var/systemd/system/env/<name>.env`, so that is a persistent per-service environment hook.

---

## 1. Boot and resume path

### 1.1 Snapshot boot / Quick Start+ / CRIU
- Kernel: `CONFIG_LG_SNAPSHOT_BOOT=y`, `CONFIG_LG_INSTANT_BOOT=y` (embedded kernel config) **[Observed]**.
- `etc/systemd/system/snapshot-boot-on.service` runs only if the kernel cmdline contains `snapshot`.
  It starts `snapshot-boot-components.service`, which brings up ls-hubd, dbus, configd,
  surface-manager, sam and memchute, then:
  ```
  ExecStart=/usr/bin/luna-send -n 1 -f luna://com.webos.applicationManager/launch '{"id": "com.webos.app.inputcommon", "params": { "snapshot": true } }'
  ExecStart=/usr/bin/luna-send -n 1 -f luna://com.webos.applicationManager/launch '{"id": "com.webos.app.home", "params": { "snapshot": true }, "preload":"full" }'
  ```
  Then `lib/systemd/system/scripts/com.webos.app.fullhome.sh` force-closes `com.webos.app.home` and
  launches `com.webos.app.fullhome` (the default home, from `"defaultApps": {"home": "com.webos.app.fullhome"}`
  in `etc/palm/defaultSettings.json`). Boot therefore starts two home apps and kills one
  **[Observed]**. This is wasted boot work **[Inference]**.
- `etc/systemd/system/snapshot-boot-off.service` (`|!snapshot`) does a normal cold boot **[Observed]**.
- Quick Start+ is the setting `quickStartMode` (category `option`). Its default is `"on"` when
  `"InstantBoot": "quickStartPlus"` (`etc/palm/defaultSettings.json`) **[Observed]**. With Quick Start+, power-off
  is a suspend ("instant boot"), so userspace is never restarted **[Inference]**.
- `etc/configd/layers/distro/hd2160-normal/com.webos.service.tvpower.json`: `"instantBootRefreshPeriod" : 24`
  (base layer: 12) **[Observed]**. This probably means the TV does a full refresh reboot while in standby every 24 h
  **[Inference: units and behaviour not confirmed]**.
- CRIU: `etc/palm/sam-conf-tv.json` `"CRIUSupportApps"` lists inputcommon, livetv, hdmi1-4, AV,
  component, scart, livemenu, home and fullhome. `lib/systemd/system/criu.service` uses
  `Environment=CRIU_IMAGE_DIR=/tmp/checkpoint`, which is tmpfs, so the images take up RAM/zram. `criu_copy_img.sh`
  copies them to `/mnt/lg/cmn_data/checkpoint` at boot-done (`nice 19`, `ionice -c 3`) **[Observed]**.
  The preload manager preloads home and fullhome with `"preloadMode" : "criu"` **[Observed]**.

### 1.2 What runs on resume (Quick Start+ wake)
- `etc/palm/bootd.json` raises priority during resume:
  ```
  "snapshot-resume-done" : [ {"process":"sam","value":-19}, {"process":"surface-manager","value":-19} ],
  "minimal-boot-done"   : [ {"process":"com.webos.app.i","value":-15} ],
  "boot-done"           : [ sam 0, surface-manager 0, WebAppMgr 0 ]
  ```
  This is good: the UI processes get CPU priority until boot-done **[Observed]**.
- `etc/systemd/system/instant-boot-done.path` / `.service` starts `aiservice`,
  `settings-service-recovery`, `com.webos.app.livemenu` and `com.webos.app.multiview` on every instant-boot wake **[Observed]**.
- Activities in `etc/palm/activities/*` fire on power-state and network events. Each wake or reconnect
  re-triggers: `membership` (`tvReboot` on "Prepare Resume"/"Prepare Power On"), `tvdataexchanger`
  (`startPowerOnDefault` on resume), `ledbarcontroller`, and everything keyed on
  `isInternetConnectionAvailable == true`: **admanager**, **sdx** (LG telemetry), **livepick-plus**,
  **care365**, **igallery.preview**, **sportsalert**, **membership** **[Observed]**. So right after
  wake, while the user is first moving through the UI, a burst of network services starts at the same moment
  **[Inference]**.
- `com.webos.service.acr.start` and `com.webos.service.adoverlay.start` fire on
  `rest-boot-done` (`luna://com.webos.service.acr/startAcr`, `.../adoverlay/startAdoverlay`) **[Observed]**.

---

## 2. Always-on, preloaded and keep-alive components

### 2.1 Preload manager (largest RAM consumer the user can control) **[Observed]**
`lib/systemd/system/preload-manager.service` (webos-bd.target) runs `/usr/bin/webos-preload-manager`.
The policy comes from `etc/configd/layers/distro/hd2160-normal/com.webos.service.preloadmanager.json`:
```
"maxPreloadApp": 6,
fullhome  requiredMemory 40 (ext 50) periodic criu/full
home      requiredMemory 40 (ext 50) periodic criu/full
netflix   100  periodic partial  isPinUp
youtube.leanback.v4 135 periodic semi-full
com.webos.app.browser 72 oneshot partial
com.webos.app.voice   55 oneshot partial
vudu 73, amazon 100, pooq 100 (Korean app, irrelevant in US)
livetv, hdmi1..hdmi4, livemenu, miracast, miracast-overlay  40 each, periodic
google.assistant 42 periodic partial isPinUp
amazon.alexapr   57 periodic partial
```
`etc/palm/webos-preload-manager-conf.json`: `"setting": {"interval": 5}`,
`"resourcemon": {"timeout":15,"startAfter":2,"waitCpuUnder":40}`.
The binary also reads `/var/preferences/webos-preload-manager-conf.json` and the configd key
`com.webos.service.preloadmanager.maxPreloadApp`. It contains the strings `"MaxPreloadApp is 0, Disabled"` and
`"Retry preloading ... (onRunning)"` **[Observed]**.

Effect **[Inference]**: up to 6 apps (roughly 300-450 MB by LG's own `requiredMemory` figures) are kept resident.
"periodic" apps are re-preloaded after memchute kills them under pressure, which can create a
kill→preload→kill cycle that runs during UI use (5 s interval, starts once CPU is below 40 %).

### 2.2 Keep-alive apps **[Observed]**
`etc/configd/layers/base/com.webos.applicationManager.json`:
```
"keepAliveApps": [ "com.webos.app.tvguidejpn","com.webos.app.voice","com.webos.app.voiceagent",
  "com.webos.app.livemenu","com.webos.app.tvhotkey","com.webos.app.dvrpopup","com.webos.app.home",
  "com.webos.app.fullhome","airplay","google.assistant","amazon.alexapr" ],
"supportQmlBooster":false
```
`etc/palm/memorymanager-conf.json`: `"KeepOnLaunchEx":["com.webos.app.home","com.webos.app.fullhome","google.assistant"]`,
`"KeepAlive":["com.webos.app.livehbbtv","com.webos.app.livedmost","com.webos.app.liveibb"]`.
`airplay`, `google.assistant` and `amazon.alexapr` are **web apps**. Each one keeps a Chromium-68 renderer alive
once launched or preloaded **[Inference]**.

### 2.3 Booster
`lib/systemd/system/scripts/booster.sh` execs `boosterd` only if configd
`supportQmlBooster` is true. It is `false`, so booster exits **[Observed]**. No cost.

### 2.4 WebAppManager (Chromium 68) **[Observed]**
`etc/systemd/system/scripts/webapp-mgr.sh` and `etc/wam/plugins/conf.sh`. `libcbe.so` reports `Chrome/68.0.3440.106`.
Relevant flags: `--in-process-gpu`, `--enable-threaded-compositing`, `--num-raster-threads=2`,
`--force-gpu-mem-available-mb=250`, `--enable-aggressive-release-policy`,
`--max-unused-resource-memory-usage-percentage=0`, `--decoded-image-working-set-budget-mb=96`.
Debug and production leftovers: `--remote-debugging-port=9998`, `export ENABLE_INSPECTOR=1`,
`--enable-devtools-experiments`, `--enable-watchdog` / `WATCHDOG_RENDERER_TIMEOUT=200`, and
`export WAM2_ENABLE_DEBUG_EVENT=1` / `export QT_WEBKIT_LOG="Media"` in conf.sh. The CPU cost of these is
small. The debug port is mainly a security concern **[Inference]**.
WAM starts at init-boot-done (`webos-ibd.target`, `Requires=... surface-manager.service`).

### 2.5 Ads / ACR / overlays (run while watching TV/HDMI) **[Observed]**
- `com.webos.service.acr` → `/usr/sbin/acr2` (554 KB), started on every boot by its activity. It gates
  itself on EULA and Live Plus: strings `LivePlusAllowed`, `GeneralTermsAllowed`, `"OnEulaStatus : generalTerms(%d) livePlus(%d)..."`,
  `/mnt/lg/cmn_data/acr/data/eula_allowed`.
- `com.webos.service.admanager` → `/usr/sbin/admanager`, started on network up. `com.webos.service.adoverlay` →
  `/usr/sbin/adoverlay-service`, started at rest-boot-done.
- Overlay web apps attached to the livetv window group: `com.webos.app.adoverlay`, `adoverlayex`,
  `acroverlay`, `acrcomponent`, `acrhdmi1-4`, `adhdmi1-4`, `overlaycontainer*` (`"requiredEULA":"acrOn"`),
  `fooddelivery*` (`"requiredEULA":"generalTerms"`), `dangbei-card/overlay` (China). That is 30 overlay web
  apps in total in `usr/palm/applications`.
- PmLog runs ACR at debug level: `etc/pmlog.d/acr.conf` → `{"name":"acr","level":"debug"}`, file `/var/log/acr.log`, `maxSize 10000`.
- Settings defaults: `eulaStatus.acrAllowed:false`, `acrOnAllowed:false`, `livePlus:"off"`, but
  `homePromotion:"on"`, `screenSaverAd:"on"`, `livePromotion:"on"`, `webOSPromotionVideo:"on"`,
  `homeAutoLaunch:"on"`, `aiNudge:"on"`, `sportsAlarm:"on"` (`etc/palm/defaultSettings.json`).
  Out-of-box setup asks the user to accept these.

### 2.6 Other background daemons worth noting **[Observed]**
| Component | How it starts | Notes |
|---|---|---|
| `iot-client` (ThinQ IoT, 1.1 MB) | webos-rbd. `iot-client.sh`: `elif grep -q -s -E "chip=E60\|chip=O20" /proc/cmdline; then /usr/sbin/iot-client` | runs on every o20 TV whether or not ThinQ is used |
| `sdx` (telemetry, 743 KB) | activity on internet up, and `bootmode-smarttv.service` pings it | |
| `contentminer` (947 KB, `OOMScoreAdjust=-1000`) | webos-mbd | content indexing for search/recommendations |
| `user-context-manager` + `nudge` | webos-bd; nudge `Requires=user-context-manager` | AI recommendation / "nudge" (`aiNudge`) |
| `aiservice`, `voiceconductor`, `voiceinput`, `nlpmanager`, google/alexa/thinqai adapter plugins | bd / mbd / cbd / dynamic | voice stack |
| `sportsalarm` + `sportsalert` (node) | activity after EULA (`continuous`) | |
| `care365` service (node, not unified) | activity on internet up (`continuous`) | remote-support |
| `webos-bluetooth-service` | cbd, **`Nice=-20`**, `OOMScoreAdjust=-1000` | a background daemon at the highest CPU priority (§5) |
| `miracast`, `dmr`, `airplay-adaptor`, `second-screen-gateway`, `tvlink*`, `webos-sddp`, `ssdp-discovery-lgtv`, `dial` | bd / rbd / mbd | casting and remote control. Keep the ones you use |
| `dropbear`, `bugreportd`, `crashreportd` | rbd / mbd | **binaries are missing** from the rootfs. The units fail with `Restart=on-failure` (systemd start-limit) |
| `tvservicemock` | `default-starfish.target` | **not test cruft**: provides `com.webos.service.tv.systemproperty`. Keep |

---

## 3. Test, example and debug cruft shipped in production

| Item | Evidence | Is it started? |
|---|---|---|
| `com.example.service.native{,2,3}` (9.7 KB each) | `etc/systemd/system/com.example.service.native*.service`. LS2 `Type=dynamic` | **No.** No target wants them; only started if something calls them **[Observed]** |
| `com.webos.service.appcts` (125 KB, app conformance test) | `etc/systemd/system/com.webos.service.appcts.service`. LS2 dynamic | No (on demand) **[Observed]** |
| `com.webos.db8.test.lunaservice` | LS2 `Type=static`, `Exec=/usr/lib/db8/tests/test_luna_service` | binary **absent**. Dead registration **[Observed]** |
| `com.webos.settingsservice.test.perf_basicApiTests` | LS2 static, `/usr/lib/SettingsService/tests/perf_basicApiTests` | binary **absent** **[Observed]** |
| `interactiveContentApiServer.test` / `interactivecontent.webserver.test` | LS2 dynamic → `/opt/webos/tests/...` | gtest binary absent. `opt/webos/tests` is 484 KB **[Observed]** |
| 14 `com.webos.exampleapp.*` apps | `usr/palm/applications`, all `visible:false` except `videocapture` | not started. Total about 450 KB **[Observed]** |
| `com.palm.app.enyo2sampler`, `com.webos.app.erossampler`, `com.palm.app.bugreport` | `etc/configd/layers/buildtype/PV/com.webos.applicationManager.json` `applications_append` | only if build type is PV **[Inference: retail probably not]** |
| `myservice{,2,3}` PmLog contexts at debug | `etc/pmlog.d/myservice*.conf` | log config only |
| ~30 test binaries (`tuner_test`, `test_micom_power`, `fipstest`, `vtCaptureTestSuite`, ...) | `usr/bin`, `usr/sbin` | not started **[Observed]** |
| `cpuchart` (Python `wmpChart.pyc` sampling `/proc` every 2 s) | `etc/systemd/system/webos-rbd.target.wants/cpuchart.service`. `wmpChart.sh`: `if [ $LOCAL_DL != 5 ]` | skipped when `debugMode=5`. `SetInitEnv.conf` comments say `# 5 : DEBUGSTATUS is RELEASE`, so it **should not run on retail** **[Inference]** |
| `leaktracer.service` | `etc/systemd/system/default-webos.target.wants/leaktracer.service` → missing unit | dangling **[Observed]** |
| `factorywin` (Nice=-20) | `ConditionKernelCommandLine=factory` | not on retail **[Observed]** |
| `factorymanager` | `mount-rw.target.wants` | yes, always (factory options service) **[Observed]** |
| `storedemo.conf`, `admanager.conf`, `sportsalarm.conf`, ... in `etc/init/` | upstart only | not executed by systemd (see §0) |

**Verdict:** the test cruft costs flash space and a little SAM/ls-hubd scanning, not runtime CPU or RAM.
Removing it would not speed anything up.

---

## 4. Memory management

**Kernel** (embedded config extracted from `kernel.pak.unlz4` at `IKCFG_ST`) **[Observed]**:
4.4.84, `CONFIG_NR_CPUS=4`, `CONFIG_ZRAM=y`, `CONFIG_ZSMALLOC=y`, `CONFIG_CRYPTO_ZACC=y` (LG hardware
compressor), `CONFIG_LOW_MEM_NOTIFY=y` (LG), `# CONFIG_ANDROID_LOW_MEMORY_KILLER is not set`,
`CONFIG_MEMCG=y`, `CONFIG_MEMCG_SWAP=y`, `CONFIG_PSI=y`, `CONFIG_KSM=y` (never enabled by any script),
`CONFIG_CMA=y`, `CONFIG_COMPACTION=y`. Userland is 32-bit ARM on an arm64 kernel (`lib32-*`).

**zram** (`etc/systemd/system/scripts/zram-on.sh`) **[Observed]**: disksize = 25 % of managed
Normal+HighMem (40 % if under 1536 MB), minimum 600 MB. Algorithm is the first available of `zacc lz4 lzo`.
`max_comp_streams = 2×NCPU`. Overrides come from `$HOME/zramswap.conf` = `/home/root/zramswap.conf` (persistent).
`swap-on.sh`: `swapon --discard`. EFS (eMMC-backed compressed swap, "apphib") exists but
`lib/systemd/system/scripts/swap-on.sh` has `USE_EFS_SWAP=NO` and `memorymanager-conf.json`
has `"EfsActivate" : false`, `"AppHibernationEnable": false`.

**VM tunables** (`etc/systemd/system/scripts/memchute-ready.sh`) **[Observed]**:
```
SWAPPINESS=100   MIN_FREE_KBYTES=8192   PAGE_CLUSTER=3
lowmem_reserve_ratio first field -> 64
/sys/kernel/mm/low_mem_notify/{freeze=1,ratio=0,workingset=80M}
ExecStartPost=-/home/root/memchute_debug.sh      <- persistent root hook (memchute-ready.service)
```
`etc/sysctl.conf` only holds network hardening (`log_martians = 1`, `kernel.sysrq=0`). In
release mode (`debugMode=5`), `lib/systemd/system/panic.service` sets `echo 1 > /proc/sys/vm/panic_on_oom`, so
**a real kernel OOM reboots the TV**. memchute has to act before that **[Observed]**.

**memchute** (LG memory manager, `com.webos.mm`, `OOMScoreAdjust=-1000`) **[Observed]**:
- `etc/palm/threshold.conf`: `enter=0;5956;20847;59563;-1` / `leave=0;2978;11913;26803;74453`. These are pages.
  `usr/sbin/GetLowMemoryThreshold.py` uses `enter[2]/256` = 81 MB as "low" and `leave[3]/256` = 291 MB.
  The binary also reads `/home/root/threshold.conf`, which is a persistent override **[Observed string; precedence Inference]**.
- `etc/palm/mri.conf` uses PSI triggers `psi_cpu=25;40;50`, `psi_mem=20;25;30`, plus zram ratio and zspage events.
- `etc/palm/memorymanager-conf.json`: `"DefaultRequiredMemory":120`, `"LaunchThreshold": 120`,
  `"GroupKillTimeout": 4500`, `"LowTimeout": 1300`, `"CriticalTimeout": 300`, and a priority-group
  kill order (preload < UMS < app < … < home < … < keep-alive). configd `com.webos.memorymanager.clearBackgroundApp: false`.
- `etc/palm/systrim-conf.json`: `libsystrim` (LD_PRELOADed into sam, WAM, surface-manager and others) trims the heap of
  whitelisted processes at "medium" pressure.

**RAM pinned by tmpfs/ramfs** **[Observed]**:
- `/tmp/var/log` is mounted with `mount -t ramfs ramfs /tmp/var/log` (`mount-readonly-volatile.sh`
  line 106). ramfs has **no size limit and cannot be swapped**. All PmLog files go there (§6).
- `/var/db/epg` is `tmpfs size=80M` and `/var/db/temp` is `tmpfs size=80M` (`mount-readwrite.sh`, `etc/fstab-db8temp`).
- `/tmp/checkpoint` holds the CRIU images on tmpfs.

**RAM size:** not stated in the image. 2.5 GB is commonly reported for the CX **[Inference]**. The UI is
composited at `1920x1080` (configd `compositorGeometry`) **[Observed]**.

---

## 5. CPU and GPU scheduling

- `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y`. No script changes the governor **[Observed]**. Correction: the LG1212
  device tree has no OPP table, and frequency and core hotplug are run by LG's PMS governor (`launch.md` §6), so
  whether the CPU is frequency-starved is unverified. Thermal limiting uses step_wise (`CONFIG_THERMAL_DEFAULT_GOV_STEP_WISE=y`).
- `CONFIG_HZ_100=y`, `CONFIG_HZ_PERIODIC=y`, `CONFIG_PREEMPT=y`, plus debug options
  `CONFIG_DEBUG_PREEMPT=y`, `CONFIG_SCHED_DEBUG=y`, `CONFIG_CGROUP_DEBUG=y`, `CONFIG_DEBUG_KERNEL=y`,
  `CONFIG_FTRACE=y`, `CONFIG_PAGE_OWNER=y`, `CONFIG_KALLSYMS_ALL=y` **[Observed]**. These add small
  constant overhead. The kernel is signed, so this cannot be changed **[Inference]**.
- **No CPU partitioning:** `CONFIG_CPUSETS=y` and `CONFIG_FAIR_GROUP_SCHED=y` are built, but no unit or script
  assigns a cpuset, cpu.shares or `CPUWeight=`. The only cgroup use is memory (`cgroup-mem-perf.sh`
  moves gibbs, lginput2 and nabs into `critical_perf`) **[Observed]**. The UI competes with background
  daemons on equal terms, apart from nice values.
- Nice values **[Observed]**: `bootd` `Nice=-20`. **`webos-bluetooth-service` `Nice=-20`**. sam and surface-manager
  get -19 only until boot-done. `com.webos.app.i*` gets -15 at minimal-boot-done.
- Compositor **[Observed]**: `usr/bin/surface-manager.sh`, Qt **5.6.3** (`libQt5WaylandClient.so.5.6.3`),
  eglfs/starfish QPA, Mali GPU (`bsp/.../gpu-libs.service`: `mali_kbase.ko`). `etc/surface-manager.d/product.env`:
  `WEBOS_COMPOSITOR_DISPLAYS=2`, `QT_QPA_EGLFS_FB=/dev/fb0:/dev/fb1`, plus a second QML window
  `StarfishSecondaryMain.qml` at `512x2160` on fb1, `QSG_ATLAS 1024x1024`, `QSG_TRANSIENT_IMAGES=1`.
- **All Wayland QML clients use the non-threaded render loop**: `etc/systemd/system.conf.d/30-webos-global.conf`
  `DefaultEnvironment=WEBOS_GL_DISABLE_THREADED_RENDERING=1`, consumed by `libQt5WaylandClient.so.5.6.3`
  **[Observed]**. Animations in home, livemenu and quick settings run on the GUI thread, so any JS/QML work stalls frames
  **[Inference]**. LG most likely set this for driver stability, so it is not recommended to flip.
- configd `com.webos.surfacemanager.animationQuality: "high"`. It only changes text styling in QuickSettings,
  so it has no real performance effect **[Observed]**.
- I/O scheduler: `CONFIG_DEFAULT_IOSCHED="cfq"` with `CONFIG_CFQ_GROUP_IOSCHED=y`. Deadline is not built (only noop/cfq)
  **[Observed]**.
- `/proc/cpu/alignment` is set to `3` (fixup+warn) by `starfish-global.service` **[Observed]**.

---

## 6. Logging and diagnostic overhead

- **PmLog**: `etc/pmlog.d/` has 93 configs and **101 distinct log files**, all under `/var/log` → **ramfs**.
  `maxSize` (KB) is mostly `10000` (67 files), some `20000` (ums, ndl, airplay, miracast-player, avahi,
  npapiplugins, fairplay, gst) and `100000` for `webos-bluetooth-service.log`, each with
  `rotations: 5`. PmLogDaemon runs `-z` (compresses rotated files) **[Observed]**.
  About 70 contexts are set to **debug**, among them `ls-hubd.debug` and `ls-hubd.distinct` (the system bus),
  `acr`, `ADMANAGER`, `adoverlay-service`, `IEPG`, `lginput2` (remote input), `gmwl.dbg`, `videooutputd`,
  `webos-preload-manager`, `NLPMANAGER`, `VOICEFW`, `ASSISTANT`, `AMAZON-ALEXA-*`, `THINQAI`, `CBOX.*`,
  `pr.dbg*`, `media.drm*`, `btmngr`, `webos-bluetooth-service`, `MIRACAST`, `tts`, `legacy-log`, `devmode`
  **[Observed]**.
  Debug logging in ls-hubd and lginput2 is in the hot path for every IPC message and key press, and
  all of it ends up as unswappable RAM **[Inference: actual volume depends on how much each binary logs at debug]**.
  `etc/pmlog.d/default.conf`: `<default>` level `info` → `/var/log/messages` (2 MB × 5).
- `bootd.json` `"logger": {"logType": ["file","pmlog"], "logLevel": "debug"}`. `configd.json` logger level 5 →
  `/var/log/configd.log` **[Observed]**.
- `remotelogger` (default-webos), `rdxd` (mbd, `/var/spool/rdxd`), `crashd`, `uploadd` (bd),
  `pm-klog-daemon` (`PmKLogDaemon -n -d 1`), `klog-formatter` (oneshot, uses `mmcoops=`), `qosm`, `remotediag`
  are all on by default **[Observed]**. journald is masked (`etc/systemd/system/systemd-journald.service -> /dev/null`).
- `kdump.sh` only loads a crash kernel if `crashkernel` is on the cmdline. Unknown for retail **[Observed script]**.
- `sysctl.conf`: `net.ipv4.conf.all.log_martians = 1` can flood klog on some networks **[Observed / Inference]**.
- PmLog backup to eMMC is off unless `/mnt/lg/cmn_data/log/backup_enabled` exists (`snapshot-boot-resume.sh`) **[Observed]**.

---

## 7. Storage and I/O

- db8 runs as **4 separate `mojodb-luna` (LevelDB) processes**: maindb `/var/db/main` (eMMC),
  mediadb `/media/cryptofs/...` (eMMC), tempdb `/var/db/temp` (tmpfs 80M), epgdb `/var/db/epg` (tmpfs 80M).
  All of them use `"ldb": {"cacheSize": 3145728, "sync": 1, "paranoid_checks": 1, ...}` (`etc/palm/db8/*.conf`), so every
  write to maindb/mediadb is fsync'd on eMMC (ext4 `data=ordered`, `etc/systemd/system/mount-readwrite.d/00-partinfo.ext4.fstab`)
  **[Observed]**. Settings and launch-point writes can stall behind eMMC flushes **[Inference]**.
- Periodic jobs (`etc/palm/activities`) **[Observed]**: `scheduledSpaceCheck` every **5 min** ×4 DBs
  (cheap statvfs), `scheduledPurge` daily ×4, `appUpdateService/check` daily.
- `emmcd` (bd, actually also cbd): `usr/share/emmcd/emmcd_config.json` `"isLogEnabled" : true`,
  `"ProfileTimeout": 21600`. The binary references `/proc/sys/vm/block_dump`, `/proc/block_dump_msg/*`
  and walks `/proc/%d/task`. Override file: `/home/root/emmcd_config.json` **[Observed]**. Per-I/O
  accounting cost **[Inference]**.
- filecache: `etc/palm/FileCache.conf` `totalCacheSpace 104857600` (100 MB) **[Observed]**.
- WAM disk cache is 50 MB and appcache is 50 MB (`webapp-mgr.sh`) **[Observed]**.

---

## (a) Summary of contributors to slowness, ranked

1. **Memory pressure from preloading and keep-alive.** maxPreloadApp=6 with "periodic" re-preload. Keep-alive web apps
   (airplay, google.assistant, alexa) and two home apps. This drives zram swapping (swappiness 100,
   page-cluster 3) and memchute kills, and lag appears when a foreground app needs memory. **[Observed config / Inference effect]**
2. **ACR, ad and overlay stack while watching TV/HDMI.** acr2 fingerprinting, admanager, adoverlay, and up to 30 overlay
   web apps, gated by Live Plus and EULA. **[Observed]**
3. **Debug-level logging into unswappable ramfs.** About 70 contexts, including the bus (ls-hubd) and the remote input
   daemon. **[Observed config / Inference cost]**
4. **Resume and network burst.** On wake or reconnect: sdx, admanager, livepick-plus, care365, sportsalert,
   membership, igallery preview, aiservice, multiview and livemenu all start at once. **[Observed triggers / Inference effect]**
5. **Always-on optional daemons.** iot-client (forced on o20), contentminer, user-context-manager + nudge, voice
   stack, sportsalarm, miracast, dmr, sddp, tvlink and others. About 117 long-running units at boot. **[Observed]**
6. **No CPU isolation for the UI.** Only nice values, and the BT daemon runs at nice -20. **[Observed]**
7. **Non-threaded Qt render loop and Chromium 68 on a 32-bit userland.** Built into the platform, not tunable. **[Observed]**
8. **eMMC fsync and CFQ.** db8 sync=1 and paranoid checks, plus CFQ idling on eMMC. **[Observed config / Inference effect]**
9. **Long uptime under Quick Start+.** Fragmentation and leaks build up. memchute has `"FragmentationProfile": true` and a
   `Reboot system by LowMemory!` path. **[Inference]**

Test and example cruft (§3) is **not** a meaningful runtime contributor.

---

## (b) Prioritized concrete changes

### Tier 1: no root (TV menu, webOS 5 / 2020 menu layout; exact labels can vary slightly by firmware)

| # | Change | Menu path | Expected benefit | Risk / what breaks |
|---|---|---|---|---|
| U1 | **Turn Live Plus off** (`livePlus`, category `option`) | Settings ⚙ → All Settings → General → Additional Settings → Live Plus → Off | acr2 stops fingerprinting. ACR/ad/overlay web apps (overlaycontainer `requiredEULA:"acrOn"`, acroverlay, adoverlay) stop loading over live TV/HDMI. Smoother TV/HDMI menus and less RAM use **[Inference]** | lose "Live Plus" interactive content and content-aware recommendations |
| U2 | **Decline optional User Agreements**: Viewing Information, Interest-Based Advertising, Voice Information (if voice is unused) | All Settings → General → About This TV → User Agreements | ACR and ads gate on these flags (`OnEulaStatus: generalTerms livePlus IBA DPA`). Fewer background services **[Observed gating / Inference effect]** | lose personalised recommendations and ads. Declining Voice Information disables the voice assistant |
| U3 | **Home Auto Launch Off, Home Promotion Off** (`homeAutoLaunch`, `homePromotion`) | All Settings → General → Home Settings | Home is not rendered with promo content at every power-on, so less web fetching and rendering at startup **[Inference]** | cosmetic. Home no longer opens automatically |
| U4 | **AI Recommendation off** (`aiNudge`) and **Sports Alert off** (`sportsAlarm`) | All Settings → General → AI Service → AI Recommendation. Sports Alert in the Sports Alert / notifications settings | Less nudge/user-context-manager and sportsalarm/sportsalert activity **[Inference]** | lose tips and sports pop-ups |
| U5 | **Screen-saver promotion off** (`screenSaverAd`) | All Settings → General → Additional Settings → Screen Saver Promotion (label varies) | less promo video and ad content **[Inference]** | none |
| U6 | **Don't sign in to Google Assistant / Alexa** if unused (`requiredEULA:"voice2"`) | First-use or AI Service menus | Inference only: may reduce use of the keep-alive voice web apps. preloadmanager still lists google.assistant with `isPinUp` | voice assistants unavailable |
| U7 | **Do a full cold restart periodically**, e.g. weekly: unplug for about 1 minute, or turn Quick Start+ off and power-cycle | All Settings → General → Quick Start+ (`quickStartMode`) | Clears memory fragmentation, zram contents and leaked state that build up under instant-boot **[Inference]** | keeping Quick Start+ **off** permanently makes power-on slower but gives a fresh userspace every time. Recommendation: keep it on and reboot weekly |

### Tier 2: rooted TV (webosbrew / Homebrew Channel)

How to persist (the rootfs is read-only squashfs):
- **`/var/lib/webosbrew/init.d/<name>`** runs at boot through the Homebrew Channel's `run-parts`.
  The file must be executable and its **name must have no dot** (busybox run-parts skips names like `x.sh`)
  **[Inference from HBC behaviour]**.
- Firmware-native hooks that need no HBC **[Observed in units/binaries]**:
  `/home/root/memchute_debug.sh` (ExecStartPost of memchute-ready.service, at rest-boot-done, as root),
  `/home/root/zramswap.conf`, `/home/root/threshold.conf`, `/home/root/emmcd_config.json`,
  `/var/preferences/webos-preload-manager-conf.json`, `/var/systemd/system/env/<unit>.env`.
  All of these sit on persistent ext4 (`/home` → `/mnt/lg/cmn_data/home`, `/var` → `/mnt/lg/cmn_data/var`).
- To disable a unit without writing to /etc: `systemctl stop X.service; systemctl mask --runtime X.service`.
  The mask is written to `/run/systemd/system` (tmpfs) and is gone after reboot, so the init.d script re-applies it.

| # | Change (exact mechanism) | Expected benefit | Risk / what breaks |
|---|---|---|---|
| R1 | **Superseded for launch speed by `launch.md` §3** (preload only the apps you use, all pinned). **Cut preloading.** `luna-send -n 1 luna://com.webos.service.config/setConfigs '{"configs":{"com.webos.service.preloadmanager.maxPreloadApp":2}}'`, then `systemctl restart preload-manager.service`. The key name comes from the binary string `com.webos.service.preloadmanager.maxPreloadApp`. To disable preloading entirely, use `0` ("MaxPreloadApp is 0, Disabled") or `systemctl stop preload-manager.service; systemctl mask --runtime preload-manager.service`. | Frees roughly 150-400 MB of resident apps and stops kill/re-preload churn. This is the biggest RAM win **[Inference]** | Netflix, YouTube, Prime, browser and inputs cold-start 2-8 s slower on first launch. With 0, the first press of Home is slower too. It is unverified whether configd persists `setConfigs` in `/var/preferences/configd_db.json`, so re-apply it in init.d. Set back to 6 to revert |
| R2 | **Trim keep-alive** (experimental): `luna-send -n 1 luna://com.webos.service.config/setConfigs '{"configs":{"com.webos.applicationManager.keepAliveApps":["com.webos.app.fullhome","com.webos.app.livemenu","com.webos.app.tvhotkey","com.webos.app.voice"]}}'`, then close the apps you dropped: `luna-send -n 1 luna://com.webos.applicationManager/closeByAppId '{"id":"google.assistant"}'` (and `amazon.alexapr`, `airplay`) | Frees one Chromium renderer per web app dropped (tens of MB each) **[Inference]** | SAM may read this only at startup **[Inference]**. Voice and AirPlay open more slowly the first time |
| R3 | **Drop debug logging to warning at runtime**: `for c in ls-hubd.debug ls-hubd.distinct acr ADMANAGER adoverlay-service IEPG lginput2 gmwl.dbg videooutputd webos-preload-manager NLPMANAGER VOICEFW ASSISTANT AMAZON-ALEXA-ADAPTER AMAZON-ALEXA-VSK THINQAI CBOX.COMMON CBOX.DB CBOX.XPA pr.dbg btmngr webos-bluetooth-service MIRACAST tts legacy-log devmode EIM PBS MSS ICS; do PmLogCtl set "$c" warning; done`. Then free ramfs: `rm -f /var/log/*.gz /var/log/*.[0-9]` | Less IPC and input-path overhead, and the unswappable ramfs stays small **[Inference]** | Less diagnostic data for LG support. `PmLogCtl reconf` (run on resume by `snapshot-boot-resume.sh`) may restore the defaults, so re-apply on wake if needed |
| R4 | **Stop optional daemons** (`systemctl stop … ; systemctl mask --runtime …`), choosing only what you don't use: `iot-client` (ThinQ app/IoT), `sportsalarm` (no systemd unit: it is started on demand by ls-hubd, so blank its luna service file instead, as in `scripts/50scrub`), `user-context-manager` + `nudge` (AI recommendations), `miracast` (screen mirroring), `dmr` (DLNA renderer), `webos-sddp` (Control4), `tvlink-network-proxy` and `tvlinkcmdprocessor`, `bluetooth-dot-service`, `soundshare`, `uploadd`, `emmcd`, `qosm`. For the missing-binary units: `systemctl mask --runtime dropbear.service bugreportd.service crashreportd.service` | Fewer resident processes and wake-ups (each 2-20 MB) **[Inference]** | Each one removes its feature. Do **not** stop `second-screen-gateway` (the ThinQ/remote apps and LG "TV remote" use it), `tvservicemock` (provides `com.webos.service.tv.systemproperty`), `memchute`, `configd`, `sam`, `surface-manager`, `WebAppMgr`, `umediaserver`, `activitymanager`, `db8*`, `settings-service`, or any audio/video/power daemon |
| R5 | **ACR and ad services**, if U1/U2 are not enough: kill and block on-demand relaunch for this boot with `mount --bind /dev/null /usr/share/dbus-1/system-services/com.webos.service.acr.service` (same for `com.webos.service.admanager.service`, `com.webos.service.adoverlay.service`, `com.webos.service.sdx.service`), then `ls-control scan-services; pkill -f acr2; pkill admanager; pkill adoverlay-service; pkill -x sdx` | Removes ACR/ads/telemetry completely **[Inference]** | Callers log errors. Some apps may wait on a missing service. sdx also handles some LG server config, so test carefully. The bind mounts are gone after reboot |
| R6 | **VM tuning for zram** (in `/home/root/memchute_debug.sh` or init.d): `echo 0 > /proc/sys/vm/page-cluster` (stock is 3, so swap-in reads 8 pages, all decompressed), `echo 16384 > /proc/sys/vm/min_free_kbytes` (stock 8192), and optionally `sysctl -w net.ipv4.conf.all.log_martians=0` | Lower swap-in latency and fewer direct-reclaim stalls during UI bursts **[Inference]** | min_free_kbytes reserves 8 MB more. Too high can trigger memchute earlier. Keep swappiness=100 because zram is cheap. `memchute-ready.sh` does not overwrite these on respawn (`if [ -e $MEMCHUTE_READY ]; then exit 0`) |
| R7 | **eMMC I/O scheduler**: `echo 0 > /sys/block/mmcblk0/queue/iosched/slice_idle` (or `echo noop > /sys/block/mmcblk0/queue/scheduler`) | Avoids CFQ idling, so reads don't wait behind db8 fsyncs and CRIU/log copies **[Inference]** | With noop you lose `ionice` priorities (criu_copy_img uses `ionice -c 3`). Measure before and after |
| R8 | **Lower webos-bluetooth-service priority**: `renice 0 -p $(pidof webos-bluetooth-service)` (stock `Nice=-20`) | BT activity can no longer preempt the UI **[Inference]** | possible BT audio dropouts. Revert if that happens |
| R9 | **Turn off emmcd logging**: `/home/root/emmcd_config.json` = stock file with `"isLogEnabled": false` (keep the other keys), then `systemctl restart emmcd` | Less per-I/O profiling **[Inference]** | lose eMMC wear telemetry. The eMMC lifetime fault check stays active |
| R10 | Optional zram tuning: `/home/root/zramswap.conf` lines `disksize:<MB>` and `comp_algorithm:zacc` | Default is already reasonable. Only enlarge zram after R1 if memchute kills apps too often | Bigger zram means more CPU spent compressing. Takes effect at next boot (zram-on runs before init.d) |

**Do not do these** (high risk or no benefit):
- Disabling memchute. With `panic_on_oom=1` in release mode, an OOM then reboots the TV.
- Flipping `WEBOS_GL_DISABLE_THREADED_RENDERING` (needs a sam restart and probably exists to work around driver issues).
- Editing WAM flags by bind-mounting a modified `webapp-mgr.sh` (small gain, closes all web apps, easy to break).
- Removing the example/test apps (no runtime gain).
- Changing the cpufreq governor (already `performance`).

### Sample init.d script (rooted)
`/var/lib/webosbrew/init.d/50perf` (chmod 755, no dot in the name). Each block is optional.
```sh
#!/bin/sh
exec >>/tmp/50perf.log 2>&1
sleep 45   # let boot-done / preload settle
# R1 preload
luna-send -n 1 luna://com.webos.service.config/setConfigs '{"configs":{"com.webos.service.preloadmanager.maxPreloadApp":2}}'
systemctl restart preload-manager.service
# R3 logging
for c in ls-hubd.debug ls-hubd.distinct acr ADMANAGER adoverlay-service IEPG lginput2 gmwl.dbg \
         videooutputd webos-preload-manager NLPMANAGER VOICEFW ASSISTANT THINQAI CBOX.COMMON CBOX.DB \
         CBOX.XPA btmngr webos-bluetooth-service MIRACAST legacy-log devmode; do PmLogCtl set "$c" warning; done
# R4 optional daemons (edit to taste)
for u in iot-client nudge user-context-manager webos-sddp dropbear bugreportd crashreportd; do
  systemctl stop "$u.service"; systemctl mask --runtime "$u.service"; done
# sportsalarm has no systemd unit (ls-hubd starts it on demand), so blank its luna service file
mount --bind /dev/null /usr/share/luna-service2/services.d/com.webos.service.sportsalarm.service
ls-control scan-services; pkill -x sportsalarm
# R6 vm
echo 0 > /proc/sys/vm/page-cluster
echo 16384 > /proc/sys/vm/min_free_kbytes
```
To revert: delete the file and reboot. All runtime masks and settings are volatile, except whatever configd may persist.
In that case run `setConfigs` with `maxPreloadApp: 6`.

---

### Evidence index (main files)
`sbin/init`, `sbin/initctl`, `etc/palm/bootd.json`, `lib/systemd/system/*.target.wants/`, `etc/systemd/system/*.target.wants/`,
`etc/systemd/system.conf.d/30-webos-global.conf`, `etc/systemd/system/scripts/{webapp-mgr.sh,memchute-ready.sh,zram-on.sh,swap-on.sh,mount-readonly-volatile.sh,mount-readwrite.sh,webos-relocate-rootfs-writable-content-to-flash.sh,wmpChart.sh,snapshot-boot-*.sh}`,
`etc/systemd/system/{snapshot-boot-*,instant-boot-done,cpuchart,memchute-ready,preload-manager,webapp-mgr,sam}.service`,
`lib/systemd/system/{surface-manager*,booster,criu*,panic,webos-bluetooth-service,iot-client,tvservicemock,pm-log-daemon}.service`,
`usr/bin/surface-manager.sh`, `etc/surface-manager.d/product.env`, `etc/wam/plugins/conf.sh`,
`etc/palm/{sam-conf*.json,memorymanager-conf.json,threshold.conf,mri.conf,systrim-conf.json,webos-preload-manager-conf.json,defaultSettings.json,FileCache.conf,db8/*.conf}`,
`etc/configd/layers/{base/com.webos.applicationManager.json,base/com.webos.surfacemanager.json,distro/hd2160-normal/com.webos.service.preloadmanager.json,distro/hd2160-normal/com.webos.service.tvpower.json}`,
`etc/palm/activities/*`, `etc/pmlog.d/*`, `usr/share/emmcd/emmcd_config.json`, `usr/share/luna-service2/services.d/*`,
`usr/share/dbus-1/system-services/*`, the embedded kernel config (extract with `scripts/extract.sh`), and `bsp/etc/systemd/system/*`.
