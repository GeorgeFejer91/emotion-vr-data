[CmdletBinding()]
param(
    [string]$StudyRepo = "C:\Users\gfeje\Documents\GitHub\study-6",
    [switch]$SkipValidation
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$source = Join-Path $StudyRepo "s6v\data-recorded\participant-datasets-by-catalog"
$target = Join-Path $repoRoot "data\participant-datasets-by-catalog"

if (-not (Test-Path $source)) {
    throw "Source OSF-facing data folder not found: $source"
}

New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null

$resolvedRepoRoot = (Resolve-Path $repoRoot).Path
$resolvedTargetParent = (Resolve-Path (Split-Path $target -Parent)).Path
if (-not $resolvedTargetParent.StartsWith($resolvedRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to mirror outside the data repository: $target"
}

robocopy $source $target /MIR /XD ".git" /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
$robocopyCode = $LASTEXITCODE
if ($robocopyCode -ge 8) {
    throw "robocopy failed with exit code $robocopyCode"
}

if (-not $SkipValidation) {
    $requiredFiles = @(
        "master_participant_psychometrics.csv",
        "participant_data_collection_catalog.xlsx"
    )

    foreach ($file in $requiredFiles) {
        $path = Join-Path $target $file
        if (-not (Test-Path $path)) {
            throw "Required file missing from data package: $path"
        }
    }

    $rootItems = Get-ChildItem -Force $target
    $unexpected = $rootItems | Where-Object {
        -not $_.PSIsContainer -and $_.Name -notin $requiredFiles
    }
    if ($unexpected) {
        throw "Unexpected root files in OSF package: $($unexpected.Name -join ', ')"
    }

    $participantFolders = $rootItems | Where-Object { $_.PSIsContainer -and $_.Name -match '^P\d{2}$' }
    if (-not $participantFolders) {
        throw "No participant folders found in mirrored OSF package."
    }

    $badFolders = $rootItems | Where-Object { $_.PSIsContainer -and $_.Name -notmatch '^P\d{2}$' }
    if ($badFolders) {
        throw "Unexpected folders in OSF package: $($badFolders.Name -join ', ')"
    }

    $forbidden = Get-ChildItem -Recurse -File $target | Where-Object {
        $_.Name -match 'name_lookup|private|source_manifest|Questionnaire_Data\.csv|Demographics_no_name\.json'
    }
    if ($forbidden) {
        throw "Forbidden private/intermediate files found: $($forbidden.FullName -join '; ')"
    }

    $masterCsv = Join-Path $target "master_participant_psychometrics.csv"
    $header = (Get-Content -Path $masterCsv -TotalCount 1)
    if ($header -match '(^|,)Name(,|$)') {
        throw "Master psychometrics CSV contains a Name column."
    }

    $ecgFiles = Get-ChildItem -Recurse -File $target -Filter "ECG_*.csv"
    $badEcg = $ecgFiles | Where-Object {
        $_.Name -notmatch '^ECG_\d{2}_P\d{2}_(Hand|Env)_[HL]C_[HL]E_.*_B\d{2}\.csv$'
    }
    if ($badEcg) {
        throw "Unexpected ECG filename format: $($badEcg.Name -join ', ')"
    }

    $rowCount = [Math]::Max(0, ((Get-Content -Path $masterCsv).Count - 1))
    Write-Host "Validated OSF-facing package:"
    Write-Host "  Participant folders: $($participantFolders.Count)"
    Write-Host "  ECG files: $($ecgFiles.Count)"
    Write-Host "  Psychometric rows: $rowCount"
}

Write-Host "Mirrored clean OSF-facing data package to:"
Write-Host "  $target"
