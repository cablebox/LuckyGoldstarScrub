# LG Content Store on webOS 10.3: where enforcement lives

Static analysis of the extracted C3 firmware 33.31.68 rootfs (`fw/ext3368/rootfs`), 2026-10-18.
Partially derived from a scout run that mapped the pipeline before being time-boxed. Every claim
tagged **[EVIDENCED]** (file/quote) or **[INFERRED]**.

## 1. Pipeline components

| Role | Component | Evidence |
|---|---|---|
| Store app (UI) | `com.webos.app.premium` ("LG Content Store") | `usr/palm/applications/com.webos.app.premium/` [EVIDENCED] |
| Purchase/billing | `com.webos.service.billing` (JS luna service) | `usr/palm/services/com.webos.service.billing/src/` [EVIDENCED] |
| App metadata | `sam` (`com.webos.sam`, ApplicationDescription schema) | `etc/palm/schemas/sam/ApplicationDescription.schema` (307 lines) [EVIDENCED] |
| Install | `appinstalld` (+ `pkginstalld`, `com.webos.service.downloadmanager`) | services.d units; install schemas [EVIDENCED] |
| Install-time signature check | `pkgverifier` (`com.webos.service.pkgverifier`) | services.d unit; binary decode: cert chain + RSA signature vs `/etc/ssl/certs/ca-certificates/pkg` [EVIDENCED] |

## 2. Catalog visibility

The store app queries LG's SDP backend for the app catalog; the device's profile (configd
`profile.json`: model-year, device family keys) is part of the query set. The model-year gate
that hides `com.lighting.huesync` from a C3 is applied on the server side of that query.
[INFERRED — consistent with `findings/models.md` §5 (profiles differ only in model-year fields)
and `huesync_c3_backport.md` §2; the exact server filter is not on-disk.]

## 3. Entitlement / payment

Paid apps go through the EBP2 billing platform, not the store's catalog:

- Endpoints: `*-core.ebp2.lgsmartplatform.com` (kic/aic/eic/ruc), production keys compiled in.
  [EVIDENCED: `src/defaultServerOption.js`]
- Purchase confirm API: `POST /ebp/v1/purchase/confirm`; request requires `userId`,
  `storReqNo`, `seq`. [EVIDENCED: `src/EBP.js:79`, `src/defaultServerOption.js` "requisite"]
- So entitlement is confirmed account+device-side at purchase time, server-side. [EVIDENCED for
  the API shape; what the server binds (account vs device) is NOT visible offline — NOT DETERMINED]

## 4. Download

The install call itself carries the server's authorization: `appInstallService.install` takes
an `appFile` object documented verbatim as **"SDP server response for A.001"**
[**EVIDENCED**: `etc/palm/schemas/appinstalld/appInstallService.install.schema:24`]. I.e. the
store app obtains a signed SDP payload for the app (post-catalog, post-entitlement) and hands
it to appinstalld; the download URL flows from that response through downloadmanager. The
binary is therefore not fetched by an anonymous URL: the URL arrives inside an authorized
server response. [EVIDENCED for the mechanism; whether the embedded URL alone works
unauthenticated is NOT TESTED and will not be — that is the paid-fetch line.]

## 5. Install-time verification

`pkgverifier` verifies the IPK's RSA signature against LG's package CA chain
(`/etc/ssl/certs/ca-certificates/pkg`), for every install path. The signature is vendor-side
and device-independent — it proves "LG/Signify signed this package", not "this account paid".
[EVIDENCED: pkgverifier decode; scout transcript] Dev-mode (`devmode_enabled`) or root
elevation (webosbrew sampatcher) is what allows installing a package outside the store flow —
that is how SlopBro's autoroot installs hbchannel. [EVIDENCED: slopbro `wwwroot/autoroot.sh`]

## 6. Runtime re-validation

Nothing in the firmware re-checks purchase state at app launch. [EVIDENCED by absence: no
purchase field in `ApplicationDescription.schema`, no billing hooks in sam/appinstalld launch
path] The official Hue app's own Signify-side check (subscription/activation) is inside the
app package, which is not on disk — NOT DETERMINED until the app runs.

## 7. Public sources

- webosbrew rooting/exploits overview (store gate + devmode jail history): webosbrew.org/rooting/exploits
- throwaway96/faultmanager-autoroot + slopbro READMEs (devmode install path mechanics)
- Repo's own `findings/models.md` §5, `findings/huesync_c3_backport.md` (catalog gate analysis)

## Executive answer

If the account owns the app, the C3 is blocked at **catalog visibility** (server-side model
filter) and, if bypassed, at nothing else in the firmware: payment is confirmed at purchase
time server-side, the download is authorized through the SDP A.001 response (already issued
for a purchased app), install verification is signature-only (vendor, not account), and there
is no runtime purchase re-check in webOS. **Installing a legitimately-obtained IPK** (vendor-
provided, or the copy from one's own purchased 2024+ set) on a rooted C3 therefore requires
only the standard elevated install path — `appinstalld` with `devmode_enabled`/hbchannel,
which SlopBro's autoroot already exercises. What may still refuse is Signify's in-app
entitlement check, which is unknowable until run.
