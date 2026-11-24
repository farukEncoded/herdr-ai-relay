# check-all.ps1 - every check before a commit or release, from the repo root:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-all.ps1
# node --check on every .js, a PowerShell parse + ASCII check on every .ps1, JSON validity, lib.js copies in sync,
# herdr-app check on every mod (if Herdr is installed), then both tests. Exits 1 if anything failed.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Ok([string]$t) { Write-Host "  OK   $t" -ForegroundColor Green }
function Bad([string]$t) { Write-Host "  FAIL $t" -ForegroundColor Red; $script:fail++ }
function Rel([string]$p) { return $p.Substring($root.Length + 1) }

Write-Host '== JavaScript (node --check)'
if (Get-Command node -ErrorAction SilentlyContinue) {
  Get-ChildItem (Join-Path $root 'mods') -Recurse -Filter *.js | Where-Object { $_.Name -notlike '*.d.ts' } | ForEach-Object {
    $out = & node --check $_.FullName 2>&1
    if ($LASTEXITCODE -eq 0) { Ok (Rel $_.FullName) } else { Bad "$(Rel $_.FullName): $out" }
  }
} else { Write-Host '  SKIP node not found' -ForegroundColor Yellow }

Write-Host '== PowerShell (parse, ASCII)'
Get-ChildItem $root -Recurse -Filter *.ps1 | ForEach-Object {
  $errs = $null
  [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
  $ascii = -not ([IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 } | Select-Object -First 1)
  if ($errs.Count -eq 0 -and $ascii) { Ok (Rel $_.FullName) } else { Bad "$(Rel $_.FullName): $($errs.Count) parse error(s), ascii=$ascii" }
}

Write-Host '== JSON'
$json = @(Get-ChildItem (Join-Path $root 'mods') -Recurse -Filter mod.json) + @(Get-Item (Join-Path $root 'keys.json')) +
        @(Get-Item (Join-Path $root 'mods\ai-relay-kit\payload\relay-defaults.json'))
foreach ($f in $json) { try { Get-Content $f.FullName -Raw | ConvertFrom-Json | Out-Null; Ok (Rel $f.FullName) } catch { Bad "$(Rel $f.FullName): $($_.Exception.Message)" } }

Write-Host '== Doc links (relative files and #anchors)'
# A heading's GitHub anchor: lower case, punctuation dropped, spaces to dashes.
function Slug([string]$h) { return (($h.Trim().ToLower() -replace '[^\p{L}\p{Nd} _-]', '') -replace ' ', '-') }
Get-ChildItem $root -Recurse -Filter *.md | Where-Object { $_.FullName -notmatch '\\payload\\' } | ForEach-Object {
  $file = $_
  $text = [IO.File]::ReadAllText($file.FullName)
  $anchors = @{}
  foreach ($m in [regex]::Matches($text, '(?m)^#{1,6}\s+(.+?)\s*$')) { $anchors[(Slug $m.Groups[1].Value)] = $true }
  $bad = @()
  foreach ($m in [regex]::Matches($text, '\]\(([^)\s]+)\)')) {
    $target = $m.Groups[1].Value
    if ($target -match '^(https?|mailto):') { continue }
    $path, $anchor = $target -split '#', 2
    if (-not $path) { if ($anchor -and -not $anchors.ContainsKey($anchor)) { $bad += $target }; continue }
    if (-not (Test-Path (Join-Path $file.DirectoryName $path))) { $bad += $target }
  }
  if ($bad) { Bad "$(Rel $file.FullName): $($bad -join ', ')" } else { Ok (Rel $file.FullName) }
}

Write-Host '== No local state or secrets'
$stateFiles = Get-ChildItem $root -Recurse -Force | Where-Object {
  $_.FullName -notmatch '\\\.git\\' -and ($_.Name -match '^\.env' -or $_.Name -match '\.(pem|key)$' -or
  ($_.PSIsContainer -and $_.Name -in @('usage', '.ai', 'node_modules')) -or $_.Name -in @('status.json', '.ai-relay-kit.json', 'plan.json')) }
if ($stateFiles) { Bad ("state files: " + (($stateFiles | ForEach-Object { Rel $_.FullName }) -join ', ')) } else { Ok 'no .env, keys, usage/, .ai/ or relay state' }
$secretRe = '(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|xox[bp]-[A-Za-z0-9-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY)'
$hits = Get-ChildItem $root -Recurse -File | Where-Object { $_.Extension -ne '.png' -and $_.FullName -notmatch '\\\.git\\' } |
  Select-String -Pattern $secretRe -List
if ($hits) { Bad ("token-like strings: " + (($hits | ForEach-Object { "$(Rel $_.Path):$($_.LineNumber)" }) -join ', ')) } else { Ok 'no token-like strings' }

Write-Host '== lib.js copies (edit mods/ai-relay-kit/lib.js, then run tools/sync-lib.ps1)'
$master = (Get-FileHash (Join-Path $root 'mods\ai-relay-kit\lib.js')).Hash
Get-ChildItem (Join-Path $root 'mods') -Directory | ForEach-Object {
  $l = Join-Path $_.FullName 'lib.js'
  if ((Test-Path $l) -and (Get-FileHash $l).Hash -eq $master) { Ok "$($_.Name)/lib.js" } else { Bad "$($_.Name)/lib.js differs or is missing" }
}

Write-Host '== herdr-app check'
if (Get-Command herdr-app -ErrorAction SilentlyContinue) {
  Get-ChildItem (Join-Path $root 'mods') -Directory | ForEach-Object {
    $out = cmd /c "herdr-app check `"$($_.FullName)`" 2>&1"
    if ($LASTEXITCODE -eq 0) { Ok $_.Name } else { Bad "$($_.Name)`n$out" }
    # herdr-app check writes its type files into the folder; they are not part of the repo.
    foreach ($g in @('gpui-kit.d.ts', 'herdr.d.ts', 'jsconfig.json')) { Remove-Item (Join-Path $_.FullName $g) -Force -ErrorAction SilentlyContinue }
  }
  Write-Host '== tests/check-setup-render.ps1'
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\check-setup-render.ps1')
  if ($LASTEXITCODE -ne 0) { $fail++ }
} else { Write-Host '  SKIP herdr-app not found (render checks need the Herdr app)' -ForegroundColor Yellow }

Write-Host '== tests/test-setup.ps1 (throwaway home)'
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\test-setup.ps1')
$out | Where-Object { $_ -match 'PASS|FAIL|checks passed|failed' } | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { $fail++ }

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed' -ForegroundColor Green
