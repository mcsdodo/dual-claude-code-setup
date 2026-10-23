# claude-lite for Windows: Claude Code through the LiteLLM gateway.
# Same behaviour as claude-lite.sh. See that file for the rules.
#
# Install (once):
#   1. Copy litellm-settings.example.json to "$HOME\.claude\litellm-settings.json"
#      and fill in the gateway URL and key.
#   2. Copy this file to a folder on your PATH, for example "$HOME\bin".
#   3. Run `claude-lite` in PowerShell.

$ErrorActionPreference = 'Stop'

$settings = if ($env:CLAUDE_LITE_SETTINGS) { $env:CLAUDE_LITE_SETTINGS } else { Join-Path $HOME '.claude\litellm-settings.json' }
if (-not (Test-Path $settings)) {
    Write-Error "claude-lite: $settings is missing. Copy client\litellm-settings.example.json there first."
}

$claude = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $claude) {
    Write-Error 'claude-lite: no claude binary found. Install Claude Code first.'
}

& $claude.Source --settings $settings @args
exit $LASTEXITCODE
