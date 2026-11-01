$commonPath = Join-Path $PSScriptRoot "common.ps1"
if (-not (Test-Path $commonPath)) {
    Write-Host "ERROR: common.ps1 not found ($commonPath)" -ForegroundColor Red
    Write-Host "Re-extract the archive so that scripts/common.ps1 exists." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}
. $commonPath
exit (Start-GameWithRadio "ets2")