#Requires -Version 7
<#  MoodCast animated ad creative worker (concierge phase).
    One pass: claim -> render Ken Burns animated WebP -> complete.
    Cadence comes from Task Scheduler (every 10 min). No LLM, no state.
    Test mode: ./worker.ps1 -TestRender path\to\photo.jpg  (renders all presets locally)
#>
param([string]$TestRender)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Work = Join-Path $Root 'work'
New-Item -ItemType Directory -Force $Work | Out-Null

function Log([string]$msg) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
  Write-Host $line
  Add-Content -Path (Join-Path $Root 'worker.log') -Value $line
}

# ---- render contract (re-verified 2026-07-30: live embed slot is
# PublicWidget's aspect-video box = 16:9, NOT AdDisplay's 400x96 preview) ----
$DUR = 7
function Get-Filter([string]$preset, [int]$fps, [int]$w, [int]$h) {
  $frames = $DUR * $fps
  # center-crop to 16:9 at high res, then zoompan renders at target size
  $pre = "scale=4000:-2,crop=4000:2250:(in_w-4000)/2:(in_h-2250)/2"
  $zp = switch ($preset) {
    'zoom_in'   { "z='min(1+0.12*on/$frames,1.12)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'" }
    'zoom_out'  { "z='max(1.12-0.12*on/$frames,1.0)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'" }
    'pan_left'  { "z='1.12':x='(iw-iw/zoom)*(1-on/$frames)':y='ih/2-(ih/zoom/2)'" }
    'pan_right' { "z='1.12':x='(iw-iw/zoom)*on/$frames':y='ih/2-(ih/zoom/2)'" }
    default     { throw "Unknown preset $preset" }
  }
  "$pre,zoompan=$zp`:d=$frames`:s=${w}x${h}`:fps=$fps"
}

function Get-AnmfCount([string]$path) {
  $bytes = [IO.File]::ReadAllBytes($path)
  $text = [Text.Encoding]::ASCII.GetString($bytes)
  ([regex]::Matches($text, 'ANMF')).Count
}

function Invoke-Render([string]$inPath, [string]$preset, [string]$outPath) {
  # Adaptive ladder: 16:9 at 640x360 (1.6x of the 400x225 CSS slot) 16fps,
  # stepping down fps/quality/size until under the 1.5MB embed budget.
  # Ladder validated 2026-07-30 on a worst-case hard-upscaled portrait photo.
  $qBase = if ($preset -like 'pan*') { 55 } else { 60 }
  $ladder = @(
    @{ w = 640; h = 360; fps = 16; q = $qBase },
    @{ w = 640; h = 360; fps = 12; q = $qBase - 10 },
    @{ w = 560; h = 315; fps = 12; q = $qBase - 10 }
  )
  $size = 0
  foreach ($step in $ladder) {
    & ffmpeg -y -v error -i $inPath -filter_complex (Get-Filter $preset $step.fps $step.w $step.h) `
      -c:v libwebp_anim -q:v $step.q -loop 0 -t $DUR $outPath
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed (preset $preset, $($step.w)x$($step.h)@$($step.fps))" }
    $size = (Get-Item $outPath).Length
    if ($size -le 1500000) { break }
    Log "  $($step.w)x$($step.h)@$($step.fps)fps q$($step.q) = $size bytes, stepping down"
  }
  if ($size -gt 1500000) { throw "Output still exceeds 1.5MB ($size bytes) after full ladder" }
  if ((Get-AnmfCount $outPath) -lt 2) { throw "Output is not animated (ANMF<2)" }
  $size
}

function Assert-ValidInput([string]$path) {
  $dims = & ffprobe -v error -show_entries stream=width,height -of csv=p=0 $path 2>$null
  $wh = "$dims".Trim() -split ','
  $iw = [int]$wh[0]; $ih = [int]$wh[1]
  if ($iw -eq 0 -or $ih -eq 0) {
    # ffmpeg cannot decode animated WebP inputs; detect and reject with a clear message
    $head = [IO.File]::ReadAllBytes($path)[0..255]
    if ([Text.Encoding]::ASCII.GetString($head) -match 'ANIM') {
      throw "Input is an animated WebP — please provide a still photo (JPG/PNG)"
    }
    throw "Could not read image dimensions — unsupported or corrupt file"
  }
  if ($iw -lt 800 -or $ih -lt 300) { throw "Photo too small ($iw x $ih); need at least 800x300" }
}

function Select-Preset([string]$preset, [string]$jobId) {
  if ($preset -and $preset -ne 'auto') { return $preset }
  $presets = @('zoom_in', 'zoom_out', 'pan_left', 'pan_right')
  $hash = 0; foreach ($c in $jobId.ToCharArray()) { $hash = ($hash * 31 + [int]$c) % 2147483647 }
  $presets[$hash % 4]
}

# ---- test mode: render all presets from a local photo, no API ----
if ($TestRender) {
  Assert-ValidInput $TestRender
  foreach ($p in 'zoom_in', 'zoom_out', 'pan_left', 'pan_right') {
    $out = Join-Path $Work "test_$p.webp"
    $size = Invoke-Render $TestRender $p $out
    Log "TEST $p -> $out ($size bytes)"
  }
  exit 0
}

# ---- live mode ----
$cfg = Get-Content (Join-Path $Root 'config.json') | ConvertFrom-Json
$headers = @{ $cfg.authHeaderName = "$($cfg.authHeaderPrefix)$($cfg.adminToken)" }
$api = "$($cfg.baseUrl)/api/functions"

$resp = Invoke-RestMethod -Method Post -Uri "$api/adJobsClaim" -Headers $headers `
  -ContentType 'application/json' -Body (@{ max_jobs = $cfg.maxJobs } | ConvertTo-Json) -TimeoutSec 30
if (-not $resp.jobs -or $resp.jobs.Count -eq 0) { Log "no pending jobs"; exit 0 }
Log "claimed $($resp.jobs.Count) job(s)"

foreach ($job in $resp.jobs) {
  $id = $job.id
  try {
    $inPath = Join-Path $Work "$id-in"
    Invoke-WebRequest -Uri $job.source_image_url -OutFile $inPath -TimeoutSec 60
    Assert-ValidInput $inPath
    $preset = Select-Preset $job.motion_preset $id
    $outPath = Join-Path $Work "$id.webp"
    $size = Invoke-Render $inPath $preset $outPath
    Log "job $id rendered ($preset, $size bytes)"

    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($outPath))
    $done = Invoke-RestMethod -Method Post -Uri "$api/adJobsComplete" -Headers $headers `
      -ContentType 'application/json' `
      -Body (@{ job_id = $id; success = $true; webp_base64 = $b64 } | ConvertTo-Json) -TimeoutSec 120
    Log "job $id done -> template $($done.template_id)"
    Remove-Item $inPath, $outPath -Force -ErrorAction SilentlyContinue
  }
  catch {
    $msg = $_.Exception.Message
    Log "job $id FAILED: $msg"
    try {
      Invoke-RestMethod -Method Post -Uri "$api/adJobsComplete" -Headers $headers `
        -ContentType 'application/json' `
        -Body (@{ job_id = $id; success = $false; error = $msg } | ConvertTo-Json) -TimeoutSec 120 | Out-Null
    } catch { Log "job ${id}: could not report failure: $($_.Exception.Message)" }
  }
}
