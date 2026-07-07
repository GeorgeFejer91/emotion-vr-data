[CmdletBinding()]
param(
    [string]$StudyRepo = "C:\Users\gfeje\Documents\GitHub\study-6",
    [string]$Message = "",
    [switch]$NoPush
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

& (Join-Path $PSScriptRoot "sync_from_study6.ps1") -StudyRepo $StudyRepo

Push-Location $repoRoot
try {
    $status = git status --short
    if (-not $status) {
        Write-Host "No data repository changes to publish."
        exit 0
    }

    if (-not $Message) {
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
        $Message = "Refresh OSF-ready data package ($stamp)"
    }

    git add README.md .gitattributes .gitignore .env.example for-ai scripts data
    git commit -m $Message

    if (-not $NoPush) {
        git push -u origin main
    }
} finally {
    Pop-Location
}
