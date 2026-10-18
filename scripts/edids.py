import sys
HDR=b'\x00\xff\xff\xff\xff\xff\xff\x00\x1e\x6d'
def name(base):
    for i in range(54,126,18):
        d=base[i:i+18]
        if d[:3]==b'\0\0\0' and d[3]==0xfc: return d[5:].split(b'\n')[0].decode('ascii','replace').strip()
    return '?'
def hf_blocks(ext):
    if ext[0]!=0x02: return
    dtd=ext[2]; i=4
    while i<dtd:
        tag=ext[i]>>5; ln=ext[i]&31; blk=ext[i+1:i+1+ln]
        if tag==3 and blk[:3]==b'\xd8\x5d\xc4': yield 'HF-VSDB',blk[3:]
        if tag==7 and blk and blk[0]==0x79: yield 'HF-SCDB',blk[1:]
        i+=1+ln
for path in sys.argv[1:]:
    b=open(path,'rb').read(); off=0
    while True:
        off=b.find(HDR,off)
        if off<0: break
        n=b[off+126]; e=b[off:off+128*(n+1)]
        out=f'{path.split("/")[-1]} @0x{off:x} name={name(e[:128])} exts={n}'
        found=False
        for k in range(1,n+1):
            for kind,p in hf_blocks(e[128*k:128*(k+1)]):
                found=True
                # p[0]=version; HF body bytes per HDMI 2.1 table (p index = byte-4 of block payload)
                b11=p[4] if len(p)>4 else 0
                frl=(p[3]>>4) if len(p)>3 else 0
                vrr=(p[5]&0x3f, ((p[5]>>6)<<8)|p[6]) if len(p)>6 else None
                out+=f'\n   {kind} len={len(p)+3} maxFRL={frl} byte8=0x{b11:02x} ALLM={(b11>>1)&1} FVA={(b11>>2)&1} M_delta={(b11>>5)&1} QMS={(b11>>6)&1} FAPA_ext={(b11>>7)&1} VRR={vrr}'
                if len(p)>10: out+=f' QMS-TFR byte=0x{p[10]:02x}'
        if not found: out+='\n   (no HDMI Forum block: HDMI 2.0-class EDID)'
        print(out); off+=1
