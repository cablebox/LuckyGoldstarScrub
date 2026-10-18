#!/bin/sh
# Summarize one extracted LG webOS firmware image into small text files, so images can be compared
# (diff -r) after the multi-GB extraction is deleted.
# Usage: scripts/factsheet.sh <epk2extract output dir> <out dir>
# The ext dir holds rootfs*.unsquashfs, kernel.pak*, and on 2024+ images bsppart.unsquashfs.
set -u
E=${1:?usage: factsheet.sh <ext dir> <out dir>}; O=${2:?}
mkdir -p "$O"
R=$(ls -d "$E"/rootfs*.unsquashfs 2>/dev/null | head -1)
B=$(ls -d "$E"/bsppart*.unsquashfs "$E"/bsp*.unsquashfs 2>/dev/null | head -1)
K=""; for k in "$E"/kernel*.unlz4 "$E"/kernel.pak "$E"/kernel*; do [ -f "$k" ] && { K=$k; break; }; done
[ -d "$R" ] || { echo "no rootfs in $E" >&2; exit 1; }
# MediaTek boards ship a gzip-compressed kernel Image; unpack it so strings and IKCFG are readable
if [ -n "$K" ] && [ "$(head -c 2 "$K" | od -An -tx1 | tr -d ' ')" = "1f8b" ]; then
  python3 -I -c 'import sys, zlib; open(sys.argv[2], "wb").write(zlib.decompressobj(31).decompress(open(sys.argv[1], "rb").read()))' \
      "$K" "$O/.kimg" && K=$O/.kimg
fi
cd "$R" || exit 1
s() { strings -a -n 6 "$@" 2>/dev/null; }

# --- identity ---
{
  echo "dir: $(basename "$E")"
  cat etc/starfish-release etc/os-release 2>/dev/null
  [ -n "$K" ] && s "$K" | grep -m1 -E '^Linux version '
  grep -h -E '"(webosVersion|platformName|chipType|boardType)"' etc/configd/layers/*/*.json 2>/dev/null | sort -u | head
  ls "$E" | tr '\n' ' '; echo
} > "$O/meta.txt"
cat "$E/partinfo.txt" > "$O/partinfo.txt" 2>/dev/null

# --- inventories (for diffing between images) ---
ls usr/sbin usr/bin 2>/dev/null | sort -u > "$O/bins.txt"
ls usr/palm/applications 2>/dev/null > "$O/apps.txt"
ls usr/palm/services 2>/dev/null > "$O/palm_services.txt"
ls usr/share/luna-service2/services.d 2>/dev/null > "$O/luna_services.txt"
( ls lib/systemd/system etc/systemd/system 2>/dev/null; ls etc/init 2>/dev/null | sed 's/^/upstart:/' ) | sort -u > "$O/units.txt"
find usr/lib lib -maxdepth 1 -name '*.so*' 2>/dev/null | sed 's#.*/##' | sort > "$O/libs.txt"
du -sk usr/palm/applications/* 2>/dev/null | sort -rn | head -40 > "$O/app_sizes.txt"
find . -xdev -type f -size +4M -printf '%s %p\n' 2>/dev/null | sort -rn | head -60 > "$O/big_files.txt"

# --- privacy: ACR, ads, telemetry daemons ---
{
  for f in usr/sbin/acr2 usr/sbin/acr usr/sbin/admanager usr/sbin/adoverlay-service usr/sbin/livepick-plus \
           usr/sbin/user-context-manager usr/sbin/nudge usr/sbin/rdxd usr/sbin/uploadd usr/sbin/sdx \
           usr/sbin/iot-client usr/sbin/remotediag usr/sbin/dmost usr/sbin/upnpd usr/sbin/sportsalarm \
           usr/sbin/secretagent usr/sbin/color-info-miner usr/sbin/livetvwatch usr/sbin/webos-sddp; do
    [ -e "$f" ] && echo "present $f $(stat -c %s "$f")" || echo "absent  $f"
  done
  echo "--- ACR / fingerprint libraries"
  find . -xdev \( -iname 'acr*' -o -iname 'libacr*' -o -iname '*.acr*' -o -iname 'libas.so*' -o -iname '*alphonso*' -o -iname '*samba*' \
       -o -iname '*gracenote*' -o -iname '*inscape*' -o -iname '*vizio*' -o -iname '*fingerprint*' \) \
       -not -path './proc/*' 2>/dev/null | sort
  echo "--- ACR audio/video capture"
  for f in usr/sbin/acr2 usr/lib/libas.so*; do [ -e "$f" ] && s "$f" | grep -E 'dsnoop|hw:[0-9]|plughw|vtCapture|capture' | sort -u | head -20; done
  echo "--- ACR version strings"
  for f in usr/sbin/acr2 usr/lib/libas.so*; do [ -e "$f" ] && s "$f" | grep -iE 'alphonso|sdk.?version|[0-9]+\.[0-9]+\.[0-9]+' | grep -iE 'alphonso|version' | sort -u | head -10; done
} > "$O/privacy.txt"

# EULA / privacy / ad settings defaults
python3 -I - etc/palm/defaultSettings.json > "$O/defaults.txt" 2>&1 <<'EOF'
import sys, json, re
d = open(sys.argv[1], encoding='utf-8', errors='replace').read()
dec, i, out = json.JSONDecoder(), 0, {}
while True:
    m = re.compile(r'\S').search(d, i)
    if not m: break
    try: o, i = dec.raw_decode(d, m.start())
    except Exception: break
    cat = o.get('category', '') if isinstance(o, dict) else ''
    if '$' in cat or cat.startswith(('picture', 'sound', 'aspectRatio', 'aiPicture')): continue
    for k, v in (o.get('value', {}) if isinstance(o, dict) else {}).items():
        out[f'{cat}.{k}'] = v
pat = re.compile(r'acr|live(plus|promotion)|eula|additional|adcookie|^lmt$|donotsell|promotion|autolaunch|'
                 r'nudge|qms|vrr|allm|hue|colorinfo|^ai[A-Z]|thinq|homeeffect|screensaverad|instantboot|'
                 r'quickstart|preload|recommend|^ad[A-Z]|tracking|personaliz|privacy|diagnos|crash|statistic', re.I)
for k in sorted(out):
    if pat.search(k.split('.', 1)[1]): print(k, json.dumps(out[k])[:2000 if 'eulaStatus' in k else 160])
EOF

# hostnames referenced anywhere in the rootfs (and BSP)
for d in "$R" ${B:+"$B"}; do
  grep -rahoE '[a-zA-Z0-9][a-zA-Z0-9.-]{1,80}\.(lge\.com|lgtvcommon\.com|lgappstv\.com|lgsmartad\.com|lgtviot\.com|lgthinq\.com|lgeapi\.com|alphonso\.tv|samba\.tv|gracenote\.com|amazonaws\.com|google-analytics\.com|doubleclick\.net|crashlytics\.com|branch\.io|appsflyer\.com|adjust\.com|sentry\.io|nielsen\.com|tvinteractive\.tv|lgtvsdp\.com|webostv\.lge\.com|lgads\.tv|lgadvertising\.com)' "$d" 2>/dev/null
done | tr 'A-Z' 'a-z' | sed 's/^[.-]*//' | sort | uniq -c | sort -k2 > "$O/hosts.txt"

# --- performance ---
{
  echo "--- preloadmanager"
  for f in etc/configd/layers/*/*/com.webos.service.preloadmanager.json etc/configd/layers/*/com.webos.service.preloadmanager.json; do
    [ -e "$f" ] && echo "$f: $(tr -d ' \n' < "$f" | grep -oE '"maxPreloadApp[^,}]*' | head -3 | tr '\n' ' ')"
  done
  echo "--- distro variant (configd.service)"
  grep -hs 'WEBOS_TARGET_DISTRO_VARIANT=' lib/systemd/system/configd.service etc/systemd/system/configd.service | sort -u
  echo "--- memchute / memory configd"
  for f in $(ls etc/configd/layers/base/*mem* etc/configd/layers/distro/hd2160-*/*mem* 2>/dev/null); do
    echo "## $f: $(tr -d ' \n' < "$f" | head -c 600)"; done
  echo "--- memory manager"
  for f in etc/palm/memorymanager-conf.json etc/memchute*/* etc/palm/memchute*; do [ -f "$f" ] && { echo "## $f"; head -c 1500 "$f"; echo; }; done
  echo "--- zram / sysctl"
  grep -rhsE 'zram|disksize|comp_algorithm|swappiness|page-cluster|min_free_kbytes|panic_on_oom|vfs_cache' \
       etc/sysctl.conf etc/sysctl.d lib/systemd/system/*zram* usr/sbin/*zram* etc/init.d 2>/dev/null | sort -u | head -30
  echo "--- Nice/CPU settings in units"
  grep -rHsE '^(Nice|CPUSchedulingPolicy|CPUSchedulingPriority|IOSchedulingClass|OOMScoreAdjust)=' lib/systemd/system etc/systemd/system 2>/dev/null \
       | sed 's#.*/##' | sort | head -60
  echo "--- PmLog default levels"
  cat etc/PmLogDaemon/*.conf etc/pmlog.d/*.conf 2>/dev/null | grep -ciE 'debug'
  grep -rhsiE '^\s*[A-Za-z0-9._-]+\s*=\s*debug' etc/pmlog.d etc/PmLogDaemon 2>/dev/null | head -40
  echo "--- WAM / Chromium flags"
  grep -rhsoE -- '--(remote-debugging-port|js-flags|renderer-process-limit|disk-cache-size|enable-[a-z-]+|disable-[a-z-]+)[=a-zA-Z0-9,_-]*' \
       etc/wam usr/bin/*.sh etc/surface-manager.d 2>/dev/null | sort -u | head -60
  echo "--- kernel"
  [ -n "$K" ] && python3 -I - "$K" <<'EOF'
import sys, gzip
d = open(sys.argv[1], 'rb').read(); i = d.find(b'IKCFG_ST')
if i >= 0:
    import zlib
    c = zlib.decompressobj(31).decompress(d[i + 8:d.find(b'IKCFG_ED', i)]).decode(errors='replace')
    for l in c.splitlines():
        if any(k in l for k in ('CONFIG_HZ=', 'PREEMPT', 'CONFIG_ZRAM', 'CONFIG_ZSMALLOC', 'CONFIG_CMA_SIZE',
                                'CONFIG_SCHED_', 'CONFIG_CPU_FREQ_DEFAULT', 'CONFIG_NR_CPUS', 'CONFIG_ARM64=',
                                'CONFIG_ANDROID_LOW_MEMORY', 'CONFIG_PSI=', 'CONFIG_LRU_GEN')):
            if not l.startswith('# '): print(l)
else: print('no IKCFG')
EOF
} > "$O/perf.txt"

# --- debug / remote access surface ---
{
  grep -rlsE 'remote-debugging-port|9998' etc usr/bin 2>/dev/null | head
  ls usr/palm/services/com.palm.service.devmode* etc/init/remotediag.conf usr/share/remotediag 2>/dev/null
  grep -rlsE 'run_waveagent|/tmp/usb|/mnt/usb|usb.*\.sh' etc/connman etc/init etc/udev 2>/dev/null | head
} > "$O/debug.txt"

# --- QMS-VRR ---
{
  grep -rhoE '"supportQmsVrr"\s*:\s*(true|false)' etc ${B:+"$B/etc"} 2>/dev/null | sort | uniq -c
  for f in usr/sbin/eim usr/sbin/extinput-integration usr/lib/libhdmi-conn-protocol.so*; do
    [ -e "$f" ] && echo "$f: $(s "$f" | grep -ciE 'qms')"
  done
  if [ -n "$K" ]; then
    s "$K" > "$O/.kstr"
    for p in 'QMS_FSM' 'qms_handler' 'EM QMS' 'QMS BaseRate' 'Next TFR' 'MConst_Zero' 'FORCE_QMS_MODE' 'QMS_EM_TIMEOUT' 'EM VrrRcvTime' 'ALLM' 'FRL'; do
      echo "kernel '$p': $(grep -c "$p" "$O/.kstr")"
    done
    rm -f "$O/.kstr"
  fi
} > "$O/qms.txt"

# --- Hue Sync prerequisites ---
{
  for d in "$R" ${B:+"$B"}; do
    for f in $(find "$d/usr/lib" -maxdepth 1 -name 'libvtcapture.so*' -o -maxdepth 1 -name 'libpqeca.so*' 2>/dev/null); do
      echo "## ${f#$d/}"
      readelf -Ws --dyn-syms "$f" 2>/dev/null | grep -oE '(vtCapture_[A-Za-z]*Histogram|HAL_[A-Za-z]*Histogram)' | sort | uniq -c
      readelf -Ws --dyn-syms "$f" 2>/dev/null | grep -E 'UND .*HAL_[A-Za-z]*Histogram' | grep -oE 'HAL_[A-Za-z]*' | sed 's/^/imports /'
      s "$f" | grep -E 'huesync|whitelist|REFUSED' | sort -u
    done
  done
  [ -e usr/sbin/color-info-miner ] && echo "color-info-miner present" || echo "color-info-miner absent"
  grep -rlsE 'huesync|hueSync' etc usr/share 2>/dev/null | head
} > "$O/hue.txt"
rm -f "$O/.kimg"
echo "factsheet: $O"
