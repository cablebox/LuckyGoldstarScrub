# Minimal Android LP (super.img) unpacker: python3 -I lpunpack.py super.img outdir
import struct, sys, os
img, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
f = open(img, 'rb')
f.seek(0x3000)  # reserved 4K + 2x geometry 4K -> primary metadata slot 0
h = f.read(256)
assert h[:4] == b'0PLA', h[:4]
hsize = struct.unpack_from('<I', h, 8)[0]
desc = lambda off: struct.unpack_from('<III', h, off)
pt, ex = desc(80), desc(92)  # after magic,major,minor,hsize,hcsum(32),tsize,tcsum(32)
f.seek(0x3000 + hsize)
tables = f.read(max(pt[0] + pt[1] * pt[2], ex[0] + ex[1] * ex[2]))
extents = [struct.unpack_from('<QIQI', tables, ex[0] + i * ex[2]) for i in range(ex[1])]
size = os.path.getsize(img)
for i in range(pt[1]):
    e = tables[pt[0] + i * pt[2]: pt[0] + (i + 1) * pt[2]]
    name = e[:36].split(b'\0')[0].decode()
    first, num = struct.unpack_from('<II', e, 40)
    total = 0
    with open(os.path.join(out, name + '.img'), 'wb') as o:
        for nsec, ttype, tdata, _ in extents[first:first + num]:
            if ttype != 0:  # zero extent
                o.write(b'\0' * nsec * 512); total += nsec * 512; continue
            f.seek(tdata * 512); left = nsec * 512
            if tdata * 512 + left > size: print(f'  warn: {name} extent past EOF')
            while left:
                chunk = f.read(min(left, 1 << 24))
                if not chunk: break
                o.write(chunk); left -= len(chunk); total += len(chunk)
    print(f'{name}: {total} bytes in {num} extent(s)')
