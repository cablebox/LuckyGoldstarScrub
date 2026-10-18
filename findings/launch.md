# LG OLED55CXPUA (webOS 5.6.2, 04.64.00, o20) – app launch time on a rooted TV

Goal: app launches under 3 s. Static analysis only; nothing was run on a TV, so every saving below is an
estimate to be confirmed with `scripts/launchtime`. Paths are relative to `rootfs.pak.unsquashfs/`.
`bsp/` = `bsppart-atsc.pak.unsquashfs/bsp/`. Tags as in `performance.md`: **[Observed]** = read in a file,
string table or disassembly; **[Inference]** = conclusion, not measured.

The changes are implemented in `scripts/60launch` (install next to `50scrub`).

**Hardware:** LG1212 SoC, 4× Arm Cortex-A55 (device tree `LG Electronics, DTV SoC LG1212 (AArch64)` in
`lxboot.pak`), arm64 kernel 4.4.84, 32-bit ARMv7 userland **[Observed]**.

---

## 0. Summary

Where a launch's time goes, in order of size, and what can be done about each part:

| # | Cost | When it hits | Fix (60launch block) | Est. saving |
|---|---|---|---|---|
| 1 | Cold start of a store app: process spawn, Chromium 68 page load, JS parse/compile, network bootstrap | every launch of an app that isn't running or preloaded | **L4** preload the 2–3 apps you use; keep `clearBackgroundApp` false | cold 5–10 s → warm ≈0.5–1.5 s **[Inference]** |
| 2 | memchute memory gate: kill apps, re-check every 500 ms, up to 7 times | every launch while usable RAM < 120 MB | **L1** cap the wait at ≈0.6 s; free RAM (50scrub) so the gate passes at once | up to 2.9 s (worst case 6.4 s) |
| 3 | Shared 50 MB web disk cache evicts JS bundles and V8 code cache | cold launch of a hosted web app (YouTube, Hulu, Disney+…) | **L3** 150 MB disk cache | 1–3 s when the app was evicted **[Inference]** |
| 4 | QML disk cache forced off | every cold start of Home, Live TV/HDMI, livemenu, voice | **L2** turn it back on | 0.3–1.5 s **[Inference]** |
| 5 | 500 ms wipe before the splash can close; 500 ms wipe on every switch | every launch and switch | **L6** (opt-in) 150 ms wipes | ≈350 ms |
| 6 | Screenshot of the outgoing app on the compositor's render thread | every Home press | **L5** `disableCapture` (as on LG's lite/mini models) | 50–300 ms **[Inference]** |
| 7 | Background daemons compete for CPU; 108 programs wake on each foreground change | every launch, worst after resume or reconnect | **L7** `ui`/`bg` cpu cgroups; 50scrub stops the optional subscribers | removes multi-hundred-ms stalls **[Inference]** |
| 8 | Evicted pages re-read from LZO squashfs / eCryptfs; db8 fsyncs block reads | cold launches after the TV has been up a while | **L8** `vfs_cache_pressure` 50, CFQ `slice_idle` 0, idle I/O class for writers | 0–500 ms **[Inference]** |

**Can every launch get under 3 s?** Not as a guarantee, by inference:
- **Preloaded or backgrounded apps:** very likely. The launch is a window raise, plus #5 and #6.
- **Built-in LG apps (Home, inputs, Settings):** likely, with L2, L5 and L6 on top of CRIU and LG's own
  V8 snapshots.
- **Cold start of a hosted web app that isn't preloaded:** probably not reliably. It is bound by the network
  and by V8 6.8 compiling on 32-bit ARM. L3 and L7 shorten it but can't make it instant.

The practical target is therefore "the 3 apps you use are always warm, and nothing waits on the memory gate."

**This reverses one earlier recommendation.** `performance.md` R1 and the old `50scrub` capped preloading at 2 apps
to save RAM, which forces YouTube and Prime to cold-start every time. `50scrub` no longer does this. The RAM
the preloads need comes from 50scrub's other cuts instead (§3).

---

## 1. Launch sequence **[Observed strings in `usr/sbin/sam`, order Inference]**

1. **Request.** SAM logs `{"app_id","caller_id","launch_reason","preload_mode","show_splash",…}`.
2. **Prelaunch stages, run in sequence, each at least one luna round trip:**
   - power state
   - "first app" gate (*"One moment please. Smart service will be available shortly."*)
   - out-of-service / cross-border policy (sdx `getCacheStatus`)
   - `appInstallService/status` update check
   - DRM status (`sm/license/apps/getDrmStatus`)
   - app signing (`sm/verifyAppSigning`, which hashes the app directory in `securitymanager`)
   - EULA (from cache)
   - app lock
3. **squashfs/overlay mount** for apps packaged that way.
4. **memchute memory gate** (§2).
5. **Spawn:**
   - web app → `com.palm.webappmanager/launchApp`
   - native app → `/usr/bin/jailer` (the jail is persistent under `/var/palm/jail`)
   - QML app → qml-runner
   - If an app is preloaded, this step is just `showWindow` (WAM strings "Not hidden window, preload, call showWindow").
6. **Splash** (`StarfishImageSplash`) closes when the app's first surface opens. surface-manager logs
   `performanceLog.timeEnd("APP_LAUNCH")` at that point (`controllers/StarfishViewStateController.qml`).

**Don't break step 2.** Stopping or blackholing `sdx`, `appinstalld` or `securitymanager`, or DNS-blackholing LG's
server-sync hosts so they hang instead of failing fast, can stall launches by seconds or produce
"One moment please" refusals. A blocklist that answers `0.0.0.0` (as `blocklist.txt` does) or NXDOMAIN fails fast and is fine; one that silently drops traffic is not
**[Inference]**. This is why `60launch` keeps `appinstalld` out of the low-priority CPU group, and it argues
against `performance.md` R5's sdx kill.

---

## 2. memchute's pre-launch memory gate **[Observed config + strings; control flow Inference]**

`etc/palm/memorymanager-conf.json`: `DefaultRequiredMemory 120`, `LaunchThreshold 120`, `LaunchTimeout 500`,
`LaunchTimeoutCount 7`, `MaxTimeout 7000`, `GroupKillTimeout 4500`, `SortByModeledList true`.

- Required memory is the app's appinfo `requiredMemory`, or 120 MB otherwise. It is compared with
  `/sys/kernel/mm/low_mem_notify/usable_pages`.
- If enough is free: `launch by required memory`, with no delay.
- Otherwise memchute walks `PriorityGroup` upward (preload → UMS → app → …), sends `closeByAppId` for each victim
  (`request close by required`), and re-checks every 500 ms. After 7 tries it launches anyway (`launch by timeout`).
  So a launch under memory pressure **waits about 3.5 s before the app process is even started**, and up to 7 s.
- With `SortByModeledList`, memchute ranks victims through user-context-manager. If that service is masked (50scrub does
  this for privacy), memchute logs `retry getModeledList from UCM(timeout 5 secs)`.
- Apps in `NoLaunchThreshold` skip the gate (`launch without memory check`).
- **Override:** memchute reads `/home/root/memorymanager-conf.json` (and `threshold.conf`, `mri.conf`,
  `systrim-conf.json`) next to the log line `Early load conf file from : %s`. The /home copy most likely wins
  **[Inference]**. It is read when memchute starts, so changes apply from the next boot.
- memchute also calls `dropCaches(3)` on low-memory level changes (Thumb disassembly of `MemNotifier::levelChanged`).
  Running low on memory therefore costs the page cache as well, and the next launch re-reads everything (§5).

**L1** sets `LaunchTimeout 200`, `LaunchTimeoutCount 3`, `MaxTimeout 2000` and `SortByModeledList false`.
- **Risk:** the app starts with less headroom, so memchute's kills run while it starts. Release builds set
  `panic_on_oom=1`, so a real OOM reboots the TV. If you see OOM reboots, delete `/home/root/memorymanager-conf.json`.
- **More aggressive, not in the script:** add your main apps to `NoLaunchThreshold` in the same file.
- **The better fix** is to make the gate pass straight away by keeping usable RAM above about 120 MB: the RAM cuts in
  50scrub, plus preloading only the apps you use.

---

## 3. Preloading **[Observed config + strings; timings Inference]**

`usr/bin/webos-preload-manager`, started at boot-done.
- **Inputs:** configd `com.webos.service.preloadmanager.{maxPreloadApp,supportAppList}`
  (`etc/configd/layers/distro/hd2160-normal/com.webos.service.preloadmanager.json`), an allow-list in
  `/etc/palm/webos-preload-manager-conf.json` overridable at `/var/preferences/webos-preload-manager-conf.json`, launch
  history from db8, and `usercontextmanager/getModeledRank`.
- **Gates:** CPU < 40 % (`waitCpuUnder`), free memory, and accepted Terms of Use (`do not preload without eula`).
  All store stubs carry `"requiredEULA":"generalTerms"`.
- **Modes,** as implemented in `libWebAppMgrCore`: `full` / `semi-full` = loaded and running hidden; `partial` = loaded,
  then JS and painting suspended; `criu` = restored from a checkpoint (home only).
- **Kill order:** preloaded apps sit in `PG_TYPE_BASE`, the first group memchute kills, so they never take memory away from the
  foreground app. "periodic" apps are re-preloaded after a kill once the CPU is idle.
- **Stock list (6 slots):** fullhome and home, Netflix (pinned), YouTube, browser, voice, Vudu, Amazon (oneshot), pooq (Korea),
  livetv, hdmi1–4, livemenu, miracast, google.assistant, alexa.

**L4** replaces the stock list with home + `PRELOAD_APPS` (default Netflix, YouTube, Prime), all pinned and periodic, keeping
LG's per-app modes. Pinning makes the choice independent of user-context-manager's ranking, which 50scrub masks.
RAM, by LG's `requiredMemory` figures: 40–50 + 100 + 135 + 100 ≈ **380 MB**, about the same as stock. Compared with the old
`maxPreloadApp: 2`, that is about 230 MB more, paid for by 50scrub's cuts (logging, daemons, ACR stack).
Check with `luna-send -n 1 luna://com.webos.applicationManager/running '{}'` a minute after boot.

**Background apps:** `com.webos.memorymanager.clearBackgroundApp` is `false` on this model (it is `true` on lite/mini), so an app you
leave stays suspended and resumes quickly. Leave it as is.

**Store apps aren't in the firmware.** The image ships `"type":"stub"` placeholders for Netflix, YouTube, Prime, Hulu, Disney+ and the
rest (`otncabi-atsc.pak.unsquashfs/usr/palm/applications/`). The real apps live in `/media/cryptofs/apps`. Check each one's type on
the TV with `grep '"type"' /media/cryptofs/apps/usr/palm/applications/<id>/appinfo.json`. Usually Netflix and Prime are native, and YouTube,
Hulu, Disney+ and Sling are web apps **[Inference]**.

---

## 4. Web apps (WebAppMgr, Chromium 68) **[Observed]**

- **Caches persist across power-off.** `WAM_DATA_PATH=/var/lib/wam` sits on ext4 (`/var` → `/mnt/lg/cmn_data/var`, 750 MB data
  partition), and the HTTP cache, V8 code cache, shader cache and Service Worker storage are all there. SAM discards the code cache
  only when a package changes.
- **The cache is small.** `--disk-cache-size=52428800` is one 50 MB LRU shared by every web app. In Chromium 68, the V8 code cache for
  network scripts is stored with their HTTP cache entries, so 3–4 hosted apps in rotation evict each other's bundles and compiled
  code **[Inference]**.
- **Override path:** `webapp-mgr.sh` re-exports nearly every variable, so `/var/systemd/system/env/webapp-mgr.env` can't override
  the flags. However, the script sources `/etc/wam/plugins/conf.sh` after building `WAM_SWITCHES` and right before
  `exec … $WAM_EXTRA_FLAGS …` (lines 273–285). A bind-mounted copy can therefore append switches, and Chromium uses the last value
  of a repeated switch.
- **L3** adds `--disk-cache-size=157286400` (150 MB) and `--gpu-program-cache-size-kb=8192` (stock 2048), plus `LAUNCH_TIME_CHECK=1`.
  The last one makes WAM log `APP_LAUNCHTIME_CHECK_ALL_FRAMES_DONE [appId:%s time:%d]`. Check `df /mnt/lg/cmn_data` first.
- **Not used:**
  - The container-app path is inert: no `com.webos.app.container` and no `container.json` ship.
  - `usePrerendering` + `v8SnapshotFile` are already used by LG's 34 built-in apps and don't apply to store apps.
  - `--single-process`, `--no-zygote`, `--js-flags` and the process-model config were left alone.
- **Optional, not in the script** (measure first): drop `--enable-aggressive-release-policy` so a backgrounded web app keeps its tiles.
  This costs RAM and makes memchute kill sooner.

---

## 5. Native and QML apps **[Observed]**

- **QML disk cache disabled globally:** `etc/systemd/system.conf.d/80-starfish-global.conf:54`
  `DefaultEnvironment=QML_DISABLE_DISK_CACHE=1`.
  - Qt is 5.9.6, which supports the cache.
  - LG's native apps load raw `.qml` from squashfs: inputcommon (Live TV/HDMI) 264 files, fullhome 192, voice 132, home 132, livemenu
    123. No `.qmlc` exists for them, and the 128 shipped Qt Quick Controls `.qmlc` files are skipped too **[Inference]**.
  - **L2** writes `QML_DISABLE_DISK_CACHE=` (empty, which Qt treats as unset) and `QML_FORCE_DISK_CACHE=1` to
    `/var/systemd/system/env/sam.env`. SAM-launched apps inherit it **[Inference]**, and the cache goes to `/home/root/.cache`
    (persistent ext4). Applies from the next boot.
  - Check with `find /home/root/.cache -name '*.qmlc' | head`.
  - LG may have disabled it on purpose, for example over cache corruption after a power cut. If a built-in app misbehaves, delete the
    lines and `rm -rf /home/root/.cache/*qmlcache*`.
- **Booster:** `boosterd` keeps pre-forked `qml-runner`s for `type:"qml"` apps only. In this firmware those are the screensaver and
  example apps, so enabling it would gain nothing.
- **CRIU:** used for home, inputs and livemenu, gated on `criu_enabled` in the kernel cmdline. Images are copied to eMMC by
  `criu_copy_img.sh`, so they survive power-off. Web apps can't use it, because they share WAM's processes. 60launch logs whether it
  is on.
- **No real lever here:**
  - fontconfig's cache is prebuilt and mtime-ignored.
  - `ld.so.cache` is present.
  - BIND_NOW is fixed at build time.
  - The Qt shader cache is already persistent (`/var/cache/qsg-shader-cache`).
  - Disabling the jailer (`/var/luna/preferences/jailer_disabled`) saves little and removes the sandbox.

---

## 6. Compositor, CPU and I/O

- **Recents capture:** `StarfishViewStateController.qml` `prepareToGoHome()` calls `createSnapshot()` unless configd
  `com.webos.surfacemanager.disableCapture` is true.
  - `layers/base` sets it false; all four `hd*-lite` / `hd*-mini` distro layers set it true. The compositor renders on its GUI thread
    (`WEBOS_GL_DISABLE_THREADED_RENDERING=1`).
  - **L5** sets it true. The QML subscribes to the key, so it should apply live **[Inference]**.
- **Wipes:** `StarfishDefaultSettings.qml` sets `fullscreen.wiperTime 500` and `imageSplash.wiperTime 500`. The splash close is
  queued until its wipe finishes.
  - Settings are deep-merged from `usr/lib/qml/WebOSCompositor/settings.json`, which ships as an empty object.
  - **L6** (opt-in, `FAST_WIPE=1`) bind-mounts a copy with 150 ms wipes and restarts surface-manager once at boot.
- **CPU priority:**
  - The kernel has `FAIR_GROUP_SCHED` and `CPUSETS`, but no unit uses CPU shares. bootd raises sam and surface-manager only until
    boot-done.
  - ls-hubd launches each on-demand service through `/usr/sbin/setcpushares-ls2`, which is a stub (`exec "$@"`).
  - 108 binaries and QML files subscribe to foreground-app changes (`getForegroundAppInfo` / `getAppLifeEvents`), so each launch
    wakes sdx, qosm, contentminer, acr2, admanager, iot-client and others.
  - **L7** creates a `ui` cgroup (4096 shares) for sam, surface-manager and WebAppMgr, whose children inherit it, and a `bg` cgroup
    (128 shares) for optional daemons. AV, input, memory, log and install daemons stay out of `bg`: LG forces SCHED_NORMAL
    (`ATTR_FORCE_SCHEDNORMAL=YES`), so they have no RT priority to fall back on.
  - Without a cpu cgroup mount, L7 falls back to per-thread renice. Plain `renice -p` changes only the main thread.
- **CPU frequency is unverified.** The LG1212 device tree has no OPP table. Frequency, voltage and hotplug are run by LG's
  PMS governor (`CONFIG_LG1K_PMS`, `o20_pm_task_hotplug`, `/dev/lg/pm0`). The "governor already `performance`" claim in
  `performance.md` §5 rests on `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE`, which may not bind here. 60launch logs
  `/sys/devices/system/cpu/online`. If cores are parked at idle, each launch pays a ramp-up. Do not write to `/dev/lg/pm0`.
- **I/O:**
  - rootfs is LZO squashfs with 32 KiB blocks and `SQUASHFS_FRAGMENT_CACHE_SIZE=3`; store apps sit on eCryptfs. Every evicted page
    costs a decompress or decrypt on the next launch.
  - The scheduler is CFQ, with db8 `sync=1`.
  - **L8** sets `vfs_cache_pressure` 50, `slice_idle` 0 and `low_latency` 1, and moves mojodb-luna, PmLogDaemon, emmcd, uploadd and
    rdxd to the idle I/O class.

---

## 7. Measuring

`scripts/launchtime <appId> [cold]` launches an app and prints:
- the time from the launch request to SAM's `foreground` life event;
- WAM's `APP_LAUNCHTIME_CHECK_ALL_FRAMES_DONE` time (needs L3);
- memchute's `launch by timeout` / `launch by required memory` lines.

Each `launch by timeout` is a launch that sat in the memory gate. Take 10 runs per app, cold and warm, before installing
60launch and after its second boot. Note that `luna-send …/launch` skips the remote's key handling and the Home animation, so
real presses take slightly longer.

Other markers:
- SAM: `NL_APP_LAUNCH_BEGIN`, `APP_LAUNCHED`
- surface-manager: `APP_LAUNCH` timeEnd
- WAM: `firstFrameVisuallyCommitted`

All of them go to `/var/log/messages`.

---

## 8. Open questions to settle on the TV

1. Does memchute log `Early load conf file from : /home/root/memorymanager-conf.json`, meaning L1 is active?
2. Do the preloads survive? Check `running` after an hour of normal use, and look for `request close by` lines.
3. Are cores hot-unplugged at idle (`cat /sys/devices/system/cpu/online` during and between launches)?
4. Does `QML_FORCE_DISK_CACHE` reach the apps? Check `cat /proc/$(pidof com.webos.app.livemenu)/environ | tr '\0' '\n' | grep QML`.
5. Which store apps are web and which native, and does the 150 MB cache fill (`du -sh /var/lib/wam`)?
