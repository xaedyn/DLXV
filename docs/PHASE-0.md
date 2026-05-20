# Phase 0 — Validation (3 weeks)

Goal: prove the HDR wedge is real before committing to the full ~9-month build.

## Gate (go/no-go, end of week 3)

- **GO** — HDR demo visibly beats IINA on an XDR display AND ≥500 email signups in 14 days
- **ITERATE** — demo wins but signups < 500 (wedge real, pitch wrong)
- **STOP** — demo does not visibly beat IINA (technical premise wrong)

## Week 1 — HDR demo app

| Day | Deliverable |
|-----|-------------|
| 1 | Repo scaffold + minimal AVKit playback app |
| 2 | Metal renderer, zero-copy CVPixelBuffer → MTLTexture |
| 3 | YUV → linear → display color pipeline, 10-bit |
| 4 | HDR tone mapping (BT.2390), EDR — the critical day |
| 5 | Polish, tests, tag v0.0.1 |

## Week 2 — Comparison video + landing page

Source reference HDR files, capture DLXV vs IINA side-by-side on XDR, edit a
60–90s comparison video, build and deploy the landing page at dlxv.com.

## Week 3 — Soft launch + decision

Soft launch on personal channels, then /r/macapps + Mastodon + Show HN.
Observe signups for 14 days. Apply the gate criteria above.
