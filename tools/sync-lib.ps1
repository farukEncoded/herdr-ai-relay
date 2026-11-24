# sync-lib.ps1 - copies the shared helpers (mods/ai-relay-kit/lib.js) into every kit mod.
# Herdr mods can't import across folders, so each one carries its own copy. Edit only the panel's lib.js.
$mods = Join-Path $PSScriptRoot '..\mods'
$src = Join-Path $mods 'ai-relay-kit\lib.js'
foreach ($m in @('ai-relay-kit-launcher', 'ai-relay-kit-commands', 'ai-relay-kit-handoff', 'ai-relay-kit-drawer', 'ai-relay-kit-overnight')) {
  Copy-Item -LiteralPath $src -Destination (Join-Path $mods "$m\lib.js") -Force
}
Write-Host 'lib.js synced.'
