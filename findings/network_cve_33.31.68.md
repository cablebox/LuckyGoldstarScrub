# Network-facing CVE sweep — LG C3, firmware 33.31.68 (webOS 10.3.1-3006, June 2026 build)

By scout `CveNet2` (2026-10-18), verified against CVE Services/MITRE JSON APIs and vendor
trackers. Threat model: owner/authorized researcher on the same LAN. Version pins are
artifact-derived (opkg status in `fw/ext3368/rootfs`).

## 1. Pinned versions (file evidence)

| Component | Pinned version | Evidence |
|---|---|---|
| connman | 1.35-223.72.ptl4tv.24 | `usr/lib/opkg/status:2802-2804` |
| wpa_supplicant | 2.6-73.24.ptl4tv.12 (strings show 2.9-submissions base mix) | `status:12612-12614` |
| GStreamer core+good/bad/base | 1.24.0-1240.27.ptl4tv.33 (soup, tcp, rtsp present) | `status:8507-8508` |
| FFmpeg libs | 5.0.1 (libavformat59, libswscale6) | `status:1387-1389` |
| OpenSSL | 3.0.13 | `status:9679-9680` |
| curl | 7.82.0 | `status:5377-5379` |
| lighttpd | 1.4.67 (port 80) | `status:15710-15711` |
| uriparser | 0.9.6 (linked by umediaserver, hbbtv2) | `status:233-234` |
| expat | 2.5.0 | `status:11906-11907` |
| DIAL service | 1.0.0-137 (Node) | `status:2038-2039` |
| umediaserver (DLNA/UPnP) | 1.0.0-161.113.ptl4tv.4 | `status:12361-12363` |

Listener surface (from image): DIAL HTTP **36866** (mobile-app, same-subnet gate,
`discovery-server.js:239-252`) and **18181** (tvApp, origin check only, third-party always
201, `discovery-server.js:104-160`); SSDP managers; umediaserver DLNA/UPnP; connman
dnsproxy/gweb/gdhcp; wpa P2P (Miracast); SSAP wss (secondscreen.gateway); lighttpd :80.

## 2. Ranked candidates

| # | CVE | Class | Range vs pinned | LAN path | PoC | Verdict |
|---|---|---|---|---|---|---|
| 1 | **CVE-2025-32743** | connman dnsproxy ns_resolv bad memcpy (DoS or ACE) | ≤1.44 ⊃ 1.35 | 0-click DNS answer w/ TC bit; owner = own resolver | public, CISA Exploitation=poc, CVSS 9.0 | APPLIES-DEFAULT |
| 2 | **CVE-2024-47607** | GStreamer opusdec header stack smash (channels>64, EIP overwrite) | <1.24.10 ⊃ 1.24.0 | DIAL 36866 launch w/ media URL; DLNA push | public PoC, CVSS4 8.6 | APPLIES-DEFAULT |
| 3 | **CVE-2026-5056** | GStreamer qtdemux cmpd/cpat/uncC int-overflow OOB | <1.28.2 ⊃ 1.24.0 | same media path; MP4 | ZDI-CAN-29392 | APPLIES-DEFAULT |
| 4 | CVE-2022-32292 | connman gweb received_data heap overflow → code exec | ≤1.41 ⊃ 1.35 | answer the TV's WISPr/conn probe | — | APPLIES-DEFAULT (older fix: backport likely, marker-test) |
| 5 | CVE-2021-33833 | connman dnsproxy uncompress stack overflow (A/AAAA) | 1.30–1.39 ⊃ 1.35 | be/MITM upstream DNS | — | APPLIES-DEFAULT (marker-test) |

Citations: cveawg.mitre.org/api/cve/CVE-2025-32743 (≤1.44; dnsproxy.c#n1688 region);
gstreamer SA-2024-0024 (47607); gstreamer SA-2026-0016 (5056); RH/DSA-5416-1 (32292);
RH CVE-2021-33833 (1.30–1.39).

## 3. Notes

- **CVE-2023-6317/8/9** (Bitdefender SSAP chain, webOS 4–7): probably fixed on webOS 10;
  marker-test secondscreen.gateway before ruling out — it was a pre-auth SSAP bypass→root.
- Useful pairing: CVE-2025-32366 (connman parse_rr OOB **read** → stack bytes leak, ≤1.44)
  as ASLR-defeat companion to #1.
- Conditional: CVE-2021-27803 (wpa P2P, Miracast active only, RCE unproven);
  CVE-2023-38545 (curl SOCKS5, owner-set proxy only); CVE-2024-34402/03 (uriparser compose
  API — consumer UNVERIFIED); CVE-2024-5535 (OpenSSL low).
- LG-backport caveat applies to all: run fix-presence marker tests on the shipped
  `connmand` + gstreamer plugins binaries before exploit development.

## 4. Executive

Best remote: **CVE-2025-32743** — 0-click connman dnsproxy corruption from the resolver
position. Second: GStreamer **47607/5056** via DIAL/DLNA pre-auth media parse. Both need
binary marker tests against LG backports first.


## Marker-test status (2026-10-18)

- CVE-2025-32743 fix marker: upstream diff obtained (1.44→1.45 ns_resolv adds
  `if (!lookup || strlen(lookup) == 0) return -EINVAL;`). Static check against the shipped
  32-bit ARM connmand: **statically undetermined** — the binary is stripped, release-built
  (no debug strings), likely Thumb-2; byte-pattern scans for ARM-mode `mvn rX,#21`,
  literal-pool `-22`, and `bl strlen@plt` all found nothing, which pins nothing either way
  without a Thumb-aware RE pass. Live PoC test (crafted DNS answer → benign connmand crash,
  restartable) supersedes static analysis; defer to the live phase.
- Authoritative full scout output: agent session `CveNet2` (10.7 KB); this file is a
  condensation — per-candidate reachability notes and exclusions live there.
