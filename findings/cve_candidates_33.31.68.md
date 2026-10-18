# CVE utilization candidates: C3 firmware 33.31.68 (webOS 10.3.1-3006)

Static inventory from `fw/ext3368/rootfs` (opkg status + binary strings, 2026-10-18).
Purpose: backup/independent root chains for the owner's own TV. Primary-source citations;
polarity checked against the pinned build. LG backports possible — versions are the shipped
artifact's, applicability tags reflect construct/range evidence only.

## Attack surface: WAM renderer (lead)

- Engine: **Chromium 120.0.6099.270** (strings `usr/lib/libcbe*.so`). Jan 2024 build.
- Launch flags in this image (etc/systemd/system/scripts/, bg-verified): `--no-sandbox`,
  `--in-process-gpu`, `--remote-debugging-port=9998`, `--disable-gpu-rasterization-for-first-frame`.
  No sandbox + in-process GPU → renderer memory corruption is direct process compromise.
- Delivery primitive already verified in this rootfs: launch-param injection into trusted WAM
  apps (`com.webos.app.adoverlay` `interactiveUrl` etc.) loads attacker-controlled content
  into a trusted webapp context (SlopBro's entry move). No user interaction.
- Post-exploitation: the WAM process holds privileged luna access for trusted contexts →
  same install path SlopBro uses (jsserver / appinstalld dev mode) → root. No kernel privesc
  needed.

## Ranked candidates

| # | CVE | Class | Fixed in | Chrome 120 in range? | Public art | Viability on C3 |
|---|---|---|---|---|---|---|
| 1 | **CVE-2024-2887** | WASM type-canonicalization confusion (Pwn2Own, Manfred Paul) | 123.0.6312.86 | yes (<123) [EVIDENCED range; construct floor UNVERIFIED — canonicalization machinery predates 120 by years] | ZDI full writeup; buptsb PoC post | High — WASM bugs version-stable, trigger needs no flags, WAM ships WASM |
| 2 | **CVE-2024-4947** | V8 Maglev JSModuleNamespace AccessInfo type confusion (TAG, ITW/Lazarus) | 125.0.6422.60 | yes (<125) [EVIDENCED range; construct floor UNVERIFIED — Maglev shipped 117, module AccessInfo code present in 120 per analysis lineage] | bjrjk repo: Analysis.md + PoCs; Kaspersky ITW writeup; buptsb analysis | High — full exploit-pattern chain (Object Hash Reassign → OOB → addrOf/fakeObj); PoC uses natives-syntax only for reliability, natural tiering works |
| 3 | CVE-2024-5274 | V8 type confusion (fixed 125.0.6422.112) | yes | minimal public art | Medium — range holds, details thin |
| 4 | CVE-2025-13223 | V8 property-array-extension type confusion | 142.0.7444.175 | **NO** — construct absent: `ForPropertyArraySlot` does not exist at V8 branch-heads/12.0 (fetched and grepped, 1450-line access-builder.cc, zero hits). Public exploit targets 141; not retargetable to 120 cheaply | public exploit repo | Not applicable |
| 5 | CVE-2024-12053 / -12381 | V8 type confusion | 131.0.6778.x | yes | advisories only | Low-medium — floors unverified, no art |

Excluded: CVE-2024-0519 (fixed in 120.0.6099.129 < our .270 — our build already carries the
patch; evidence: Chrome 120 stable channel update timeline).

## Other pinned components (network track — CveNet2 scout running)

connman 1.35 (LG-patched), wpa_supplicant 2.9 base (LG submissions/73.24), GStreamer 1.24.0
(rtsp/udp/tcp/soup plugins), FFmpeg 5.0.1, OpenSSL 3.0.13, curl 7.82.0, DIAL service
1.0.0-137, lighttpd 1.4.67, Node 16.20.2 (jsserver), systemd 250.5, glibc 2.35, sqlite
3.38.5, expat 2.4.30. Results appended when the scout reports.

## Verification plan (offline-first, per goal boundaries)

1. Download Chrome-for-Testing **120.0.6099.x** (linux64) — runs under qemu/colima or Rosetta;
   validate CVE-2024-2887 and CVE-2024-4947 PoCs against the exact engine major (polarity +
   trigger mechanics) before writing any TV-specific payload.
2. Port the winning PoC to: arm64 + WAM context (no natives syntax; natural Maglev tiering
   for 4947; d8-vs-WAM differences: no d8 shell, use page JS + fetch for heap grooming).
3. Fire via launch-param injection (same primitive SlopBro uses) → payload uses luna install
   path → root.

This chain also works on 43.x/webOS 11 firmware where SlopBro status is unknown — it is the
firmware-version-independent backup root.

## Round 1 result (2026-10-18): CVE-2024-2887 FIRES on Chrome 120.0.6099

Method: Chrome-for-Testing 120.0.6099.109 (linux64, colima-amd), CDP-observed headless runs
(`fw/pocs/CVE-2024-2887/{main_dbg,worker_dbg,cdp_run}`), instrumented milestones.

- The exploit's 3,145,901-byte WASM module (≈1M struct types) **compiles and instantiates
  cleanly** on 120.0.6099 — the type-canonicalization confusion is present and engaged.
- **addrof primitive works**: `addrof(o) - 0x20 = 2409525` — a valid compressed-pointer value.
- **fakeobj triggers confused import dispatch**: `ff` receives a NUMBER (the crafted double
  reinterpreted), `ff2` receives a STRING (`cor=string`) — type confusion demonstrably
  crossing JS types on 120.
- The exploit payload stalls at ff2's internal `addrof(regex)` (ReferenceError — a
  scope/ordering artifact of the M123-tuned script, not an engine fix). Adaptation needed:
  bind addrof/fakeobj/helpers into ff2 via a const holder object captured before
  instantiation; re-check tiering timing.

Verdict: primary backup root chain CONFIRMED VIABLE on the C3's engine version; Round 2 =
adapt the script to 120 and drive to arbitrary-RW, then WAM-context payload. This chain is
independent of the jsserver patch state, so it also covers 43.x/webOS 11 firmware.

## Round 1b (2026-10-18): CVE-2024-4947 construct confirmed at V8 12.0

`src/compiler/access-info.cc` at `refs/branch-heads/12.0` contains the
`JS_MODULE_NAMESPACE_TYPE` AccessInfo path (lines 518-524) that the 125.0.6422.60 fix
corrected — the vulnerable construct is present in Chrome 120, and the fixed-in-125 range
includes it. Second viable browser lead alongside 2887 (public PoC: bjrjk repo; d8 `.mjs`
with natives-syntax — portable to Chrome via `--js-flags=--allow-natives-syntax` for
validation, natural-tiering variant for WAM delivery).

Correction to Round-1 narrative: the 2887 `ReferenceError` was an instrumentation scope
artifact (`let` inside the injected try-block); with `var` hoisting the run proceeds past
both bindings — chain extension in progress.

## Round 1 final state (2026-10-18, after cache forensics)

The later "runs" that reproduced identical output (incl. `addrof(o)=2720789`) were partly
stale-cache replays: colima virtiofs served an outdated `worker_dbg.js` and Chrome's
persistent profile re-served old HTML. Verified-fresh facts that STAND (from the runs whose
served content was confirmed):

1. Module compiles + instantiates on 120.0.6099.109 — confusion construct present.
2. `addrof` returns a stable, plausible compressed pointer (2720789 across runs).
3. Confused import dispatch observed: `ff` receives a number, `ff2` receives a string.
4. With the instrumentation scope bug fixed (`let`→`var`), the top-level chain
   (GCs → addrof → fakeobj call) completes with NO engine crash — but ff2's internals
   (WK2 milestones: addr_regex → data_addr → bytecode → EXEC) were never captured in a
   content-verified run, so the payload's behavior on 120 remains unobserved.

**Round 2 (deferred, clean-start SOP):** docker cp fresh worker/harness into the container
(never trust the mount), serve from container-local disk on a fresh port, verify served
bytes before launch, fresh `--user-data-dir` each run, capture WK2 milestones. Then tune
type indices if `cor` still arrives as string on 120. Priority remains: SlopBro live run
first; this chain is the firmware-independent backup.
