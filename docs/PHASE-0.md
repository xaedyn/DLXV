# Phase 0 — Validation (3 weeks)

Goal: validate the HDR rendering pipeline and gauge interest before committing
to the full build.

## Gate (end of week 3)

- **GO** — the HDR demo shows high-quality rendering on an XDR display, and
  email signups reach the target (~500 in 14 days)
- **ITERATE** — rendering quality is strong but signups fall short (revisit the pitch)
- **STOP** — rendering quality does not meet the bar

## Week 1 — HDR demo app

| Day | Deliverable |
|-----|-------------|
| 1 | Repo scaffold + minimal playback app |
| 2 | Metal renderer, zero-copy CVPixelBuffer → MTLTexture |
| 3 | YUV → linear → display color pipeline, 10-bit |
| 4 | HDR tone mapping (BT.2390), EDR — the critical day |
| 5 | Polish, tests, tag v0.0.1 |

## Week 2 — Demo video + landing page

Source reference HDR files, capture the HDR rendering output, edit a short
demo video, and build and deploy the landing page at dlxv.com.

## Week 3 — Soft launch + decision

Soft launch on personal channels, then broader community channels. Observe
signups for 14 days, then apply the gate criteria above.
