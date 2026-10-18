# List firmware downloads found in saved LG US support pages (lg.com/us/support/product/lg-<MODEL>.AUS).
# Usage: python3 -I scripts/lg_fw_links.py <dir of saved .html pages>
# Prints the 3 newest (version, size KB, fileId) per page; download https://gscs-b2c.lge.com/downloadFile?fileId=<id>.
# Entries under ~100 MB are the PDF update guide, so they are skipped.
import sys,re,glob,os
pats=[r'"fileSize":"(?P<s>\d+)K","downloadLink":"https://gscs-b2c\.lge\.com/downloadFile\?fileId=(?P<id>[^"]+)"',
      r'(?P<v>\d\d\.\d\d\.\d\d)\)\.zip","fileName":"(?P<id>[^"]+)","fileSize":"(?P<s>\d+)K","releaseDate":"(?P<d>[^"]+)"']
for f in sorted(glob.glob(sys.argv[1]+'/*.html')):
    d=open(f,encoding='utf-8',errors='replace').read()
    rows={}
    for p in pats:
      for m in re.finditer(p,d):
        if int(m.group('s'))<100000: continue
        g=m.groupdict()
        v=g.get('v') or '/'.join(sorted(set(re.findall(r'Version (\d\d\.\d\d\.\d\d)',d[max(0,m.start()-3000):m.end()+3000]))))
        rows[g['id']]=(v,g['s'])
    print(os.path.basename(f)[:-5], *sorted(((v,s,i) for i,(v,s) in rows.items()),reverse=True)[:3],sep='\n   ')
