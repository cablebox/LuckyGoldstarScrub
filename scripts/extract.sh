#!/bin/sh
# Reproduce the firmware extraction used for this analysis.
# Usage: scripts/extract.sh <workdir>
# Needs: git, cmake, gcc, libssl-dev, liblzo2-dev, zlib1g-dev, python3, curl (~6 GB free disk).
set -eu

WORK=${1:?usage: extract.sh <workdir>}
FW_URL='https://gscs-b2c.lge.com/downloadFile?fileId=dPKGwxTX8pwmBwslhYT3zA'  # OLED55CXPUA 04.64.00
mkdir -p "$WORK/dl" "$WORK/zip" "$WORK/ext" "$WORK/tools"

curl -sSL -o "$WORK/dl/fw.zip" "$FW_URL"
python3 -I -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
    "$WORK/dl/fw.zip" "$WORK/zip"

# epk2extract ships the public o20 AES key (keys/AES.key) and o20.pem.
git clone --depth 1 https://github.com/openlgtv/epk2extract.git "$WORK/tools/epk2extract"
mkdir -p "$WORK/tools/epk2extract/build"
(cd "$WORK/tools/epk2extract/build" && cmake .. && make -j"$(nproc)")
BIN="$WORK/tools/epk2extract/build/src"
cp "$WORK/tools/epk2extract/keys/AES.key" "$WORK/tools/epk2extract/keys/"*.pem "$BIN/"

# Decrypts every partition and unsquashes the filesystems (rootfs ~2.2 GB).
(cd "$WORK/ext" && "$BIN/epk2extract" -c "$WORK"/zip/*.epk)

# Optional: embedded kernel config (IKCFG) for the kernel analysis.
python3 -I - "$WORK"/ext/*/kernel.pak.unlz4 "$WORK/kconfig" <<'EOF'
import sys, gzip
d = open(sys.argv[1], 'rb').read()
i = d.find(b'IKCFG_ST')
if i >= 0:
    open(sys.argv[2], 'wb').write(gzip.decompress(d[i + 8:d.find(b'IKCFG_ED', i)]))
EOF
echo "Done: $WORK/ext"
