# moodcast-ad-worker

Render worker for MoodCast Pro animated ad creatives: polls `adJobsClaim`,
renders a Ken Burns animated WebP (16:9, adaptive size ladder, ≤2.5 MB) with
ffmpeg, posts it to `adJobsComplete`. No LLM, no state — one pass per
invocation.

## Where it runs

- **GitHub Actions (primary):** `.github/workflows/render.yml`, every 15 min +
  manual dispatch. Config via env: `WORKER_TOKEN` (Actions secret, matches the
  Base44 `WORKER_TOKEN` secret) and optional `WORKER_BASE_URL`. Public repo =
  free minutes.
- **Locally / any VPS:** `config.json` (see `config.example.json`) next to the
  script; run `pwsh -File worker.ps1` via any scheduler. Needs PowerShell 7 +
  ffmpeg with `libwebp_anim`.

`worker.ps1 -TestRender photo.jpg` renders all four motion presets locally
without touching the API.

## Ops notes

- GitHub cron can lag 3–15 min at busy times; the customer promise is "usually
  within ~30–45 min".
- GitHub pauses scheduled workflows after ~60 days without repo activity — any
  commit revives them; touch the repo monthly.
- Never run two workers concurrently against the same app (the claim endpoint
  assumes one sequential worker). The workflow's `concurrency` group enforces
  this on Actions; don't also leave a local scheduler enabled.
- Jobs queue safely while no worker runs; stale `processing` jobs (>30 min)
  self-revert to `pending`.
