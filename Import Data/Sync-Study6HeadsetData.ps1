param(
    [string]$Serial = $env:RUSTY_QUEST_SERIAL,
    [string]$HzdbPath = $(if ($env:HZDB_PATH) { $env:HZDB_PATH } else { "hzdb" }),
    [string]$RepoRoot = "",
    [string]$SourcePullDir = "",
    [string[]]$PackageName = @(
        "io.github.mesmerprism.rustyquest.study6.statichandsdynamicicosphere",
        "io.github.mesmerprism.rustyquest.study6.dynamichandsstaticicosphere",
        "io.github.mesmerprism.rustyquest.study6backup.statichandsdynamicico",
        "io.github.mesmerprism.rustyquest.study6backup.dynamichandsstaticico"
    ),
    [switch]$ForceStop,
    [switch]$AllowOverwrite,
    [switch]$SkipWorkbookUpdate,
    [string]$ParticipantCorrectionPath = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        return (Resolve-Path -LiteralPath $RepoRoot).Path
    }
    $scriptDir = Split-Path -Parent $PSCommandPath
    return (Resolve-Path -LiteralPath (Join-Path $scriptDir "..")).Path
}

function Resolve-HzdbExecutable {
    param([Parameter(Mandatory=$true)][string]$Value)
    if (Test-Path -LiteralPath $Value -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Value).Path
    }
    $command = Get-Command $Value -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    throw "hzdb was not found. Install Meta Horizon Debug Bridge or pass -HzdbPath."
}

function New-SafeName {
    param([Parameter(Mandatory=$true)][string]$Value)
    return ($Value -replace '[^A-Za-z0-9_.-]+', '_')
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Value,
        [int]$Depth = 12
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-HzdbAdb {
    param(
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $fullArgs = @("adb")
    if (-not [string]::IsNullOrWhiteSpace($script:Serial)) {
        $fullArgs += @("--device", $script:Serial)
    }
    $fullArgs += $Arguments
    $output = & $script:HzdbResolved @fullArgs 2>&1
    $code = $LASTEXITCODE
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "hzdb $($fullArgs -join ' ') failed with exit code $code.`n$text"
    }
    return [pscustomobject]@{
        exit_code = $code
        output = $text
    }
}

function New-HeadsetPull {
    param([Parameter(Mandatory=$true)][string]$Root)

    if ([string]::IsNullOrWhiteSpace($script:Serial)) {
        throw "Device serial is required when pulling from a headset. Pass -Serial or set RUSTY_QUEST_SERIAL."
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $pullRoot = Join-Path $Root ("private\headset-sync\study6-headset-pull-{0}-{1}" -f $stamp, (New-SafeName $script:Serial))
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path $pullRoot | Out-Null
    }

    $summary = [ordered]@{
        schema = "emotion_vr.study6_headset_pull.v1"
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        serial = $script:Serial
        force_stop = [bool]$ForceStop
        dry_run = [bool]$DryRun
        out_dir = $pullRoot
        packages = @()
    }

    foreach ($package in $PackageName) {
        $packageDir = Join-Path $pullRoot (New-SafeName $package)
        if (-not $DryRun) {
            New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
        }

        $packageSummary = [ordered]@{
            package_name = $package
            status = "started"
            installed = $false
            app_private_tar_path = ""
            app_private_extract_dir = ""
            app_private_roots = @()
            failures = @()
        }

        try {
            $pmPath = Invoke-HzdbAdb -Arguments @("shell", "pm", "path", $package) -AllowFailure
            if ($pmPath.exit_code -ne 0 -or [string]::IsNullOrWhiteSpace($pmPath.output)) {
                $packageSummary.status = "not_installed"
                $summary.packages += $packageSummary
                continue
            }
            $packageSummary.installed = $true

            if ($ForceStop) {
                Invoke-HzdbAdb -Arguments @("shell", "am", "force-stop", $package) -AllowFailure | Out-Null
            }

            $roots = @()
            foreach ($rootName in @("study6-dev", "study6-workspaces", "study6-participant-profiles")) {
                $probe = Invoke-HzdbAdb -Arguments @("shell", "run-as", $package, "ls", "-d", "files/$rootName") -AllowFailure
                if ($probe.exit_code -eq 0) {
                    $roots += $rootName
                }
            }

            if ($roots.Count -eq 0) {
                $packageSummary.status = "no_app_private_study6_roots"
                $summary.packages += $packageSummary
                continue
            }

            $packageSummary.app_private_roots = $roots
            if (-not $DryRun) {
                Invoke-HzdbAdb -Arguments @("shell", "run-as", $package, "mkdir", "-p", "cache") | Out-Null
                $tarArgs = @("shell", "run-as", $package, "tar", "-C", "files", "-cf", "cache/study6-app-private-host-pull.tar") + $roots
                Invoke-HzdbAdb -Arguments $tarArgs | Out-Null

                $localTar = Join-Path $packageDir "study6-app-private-host-pull.tar"
                $encoded = Invoke-HzdbAdb -Arguments @("shell", "run-as", $package, "base64", "cache/study6-app-private-host-pull.tar")
                $base64 = $encoded.output -replace '\s', ''
                if ([string]::IsNullOrWhiteSpace($base64)) {
                    throw "run-as base64 transfer returned an empty app-private tar for $package."
                }
                [System.IO.File]::WriteAllBytes($localTar, [Convert]::FromBase64String($base64))
                Invoke-HzdbAdb -Arguments @("shell", "run-as", $package, "rm", "-f", "cache/study6-app-private-host-pull.tar") -AllowFailure | Out-Null

                $extractDir = Join-Path $packageDir "app-private-files"
                New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
                & tar -xf $localTar -C $extractDir
                if ($LASTEXITCODE -ne 0) {
                    throw "Local tar extraction failed for $localTar."
                }
                $packageSummary.app_private_tar_path = $localTar
                $packageSummary.app_private_extract_dir = $extractDir
            }

            $packageSummary.status = "pulled"
        } catch {
            $packageSummary.status = "failed"
            $packageSummary.failures += $_.Exception.Message
        }

        $summary.packages += $packageSummary
    }

    $summary.status = if (@($summary.packages | Where-Object { $_.status -eq "failed" }).Count -eq 0) { "pass" } else { "fail" }
    if (-not $DryRun) {
        Write-JsonFile -Path (Join-Path $pullRoot "study6-headset-pull-summary.json") -Value $summary
    }
    return $pullRoot
}

function Convert-ParticipantId {
    param([Parameter(Mandatory=$true)][string]$RawParticipantId)
    if ($RawParticipantId -notmatch '(\d+)$') {
        throw "Cannot convert participant id '$RawParticipantId' to public P## form."
    }
    return ("P{0:D2}" -f [int]$Matches[1])
}

function Get-ConditionInfo {
    param([Parameter(Mandatory=$true)][string]$ConditionId)
    switch ($ConditionId) {
        "HC_HE" { return @{ coherence = "high"; energy = "high"; descriptor = "high_coherence_high_energy" } }
        "HC_LE" { return @{ coherence = "high"; energy = "low"; descriptor = "high_coherence_low_energy" } }
        "LC_HE" { return @{ coherence = "low"; energy = "high"; descriptor = "low_coherence_high_energy" } }
        "LC_LE" { return @{ coherence = "low"; energy = "low"; descriptor = "low_coherence_low_energy" } }
        default { return @{ coherence = ""; energy = ""; descriptor = (New-SafeName $ConditionId) } }
    }
}

function Get-MappingInfo {
    param(
        [string]$ApkVariantId,
        [string]$ApkFileCode
    )
    $needle = ("$ApkVariantId $ApkFileCode").ToUpperInvariant()
    if ($needle -match "DYN_HANDS|DYNAMIC_HANDS") {
        return @{
            mapping = "Hand"
            condition_label = "Dynamic Hands + Static Icosphere"
            condition_sequence = "Hand-mapping first"
        }
    }
    if ($needle -match "STAT_HANDS|STATIC_HANDS") {
        return @{
            mapping = "Env"
            condition_label = "Static Hands + Dynamic Icosphere"
            condition_sequence = "Env-mapping first"
        }
    }
    return @{
        mapping = "Unknown"
        condition_label = "Unknown"
        condition_sequence = "Unknown"
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Copy-SanitizedTextFile {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination,
        [Parameter(Mandatory=$true)]$Replacements
    )
    $destinationDir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $reader = [System.IO.StreamReader]::new($Source)
    $writer = [System.IO.StreamWriter]::new($Destination, $false, $encoding)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            foreach ($key in $Replacements.Keys) {
                if (-not [string]::IsNullOrEmpty($key)) {
                    $line = $line.Replace([string]$key, [string]$Replacements[$key])
                }
            }
            $writer.WriteLine($line)
        }
    } finally {
        $reader.Dispose()
        $writer.Dispose()
    }
}

function Get-ExistingMaxEcgIndex {
    param(
        [Parameter(Mandatory=$true)][string]$DataRoot,
        [Parameter(Mandatory=$true)][string]$PublicParticipantId
    )
    $max = 0
    $participantDir = Join-Path $DataRoot $PublicParticipantId
    if (Test-Path -LiteralPath $participantDir -PathType Container) {
        Get-ChildItem -LiteralPath $participantDir -File -Filter ("ECG_*_{0}_*.csv" -f $PublicParticipantId) | ForEach-Object {
            if ($_.Name -match '^ECG_(\d+)_') {
                $max = [Math]::Max($max, [int]$Matches[1])
            }
        }
    }
    return $max
}

function Get-DemographicsIndex {
    param([Parameter(Mandatory=$true)][string]$StudyDataRoot)
    $index = @{}
    $demoDir = Join-Path $StudyDataRoot "demographics"
    if (Test-Path -LiteralPath $demoDir -PathType Container) {
        Get-ChildItem -LiteralPath $demoDir -File -Filter "*_demographics.json" | ForEach-Object {
            $demo = Read-JsonFile -Path $_.FullName
            if ($demo.participant_id) {
                $index[[string]$demo.participant_id] = $demo
            }
        }
    }
    return $index
}

function Add-NameDenyListEntries {
    param($Demographics)
    foreach ($field in @("participant_name", "participant_first_name", "participant_last_name")) {
        $value = [string]$Demographics.$field
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $script:NameDenyList[$value] = $true
        }
    }
}

function Test-NoParticipantNames {
    param([string[]]$Paths)
    $names = @($script:NameDenyList.Keys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($names.Count -eq 0) {
        return
    }
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        foreach ($name in $names) {
            $hit = Select-String -LiteralPath $path -SimpleMatch -Pattern $name -Quiet
            if ($hit) {
                throw "Participant name '$name' was found in public output '$path'. Remove the file and inspect the importer."
            }
        }
    }
}

function New-MasterRowsFromQuestionnaire {
    param(
        [Parameter(Mandatory=$true)][string]$StudyDataRoot,
        [Parameter(Mandatory=$true)]$DemographicsByRawId
    )
    $questionnairePath = Join-Path $StudyDataRoot "data\questionnaire_responses_long.csv"
    if (-not (Test-Path -LiteralPath $questionnairePath -PathType Leaf)) {
        return @()
    }

    $questionRows = Import-Csv -LiteralPath $questionnairePath
    if (@($questionRows).Count -eq 0) {
        return @()
    }

    $dataDir = Join-Path $StudyDataRoot "data"
    $metadataByKey = @{}
    Get-ChildItem -LiteralPath $dataDir -File -Filter "*_block_metadata.json" -ErrorAction SilentlyContinue | ForEach-Object {
        $meta = Read-JsonFile -Path $_.FullName
        if ($meta.participant_id -and $meta.block_id -and $meta.vr_condition_id) {
            $key = "{0}|{1}|{2}" -f $meta.participant_id, $meta.block_id, $meta.vr_condition_id
            $metadataByKey[$key] = $meta
        }
    }

    $groups = $questionRows | Group-Object -Property participant_id, block_id, vr_condition_id
    $rows = @()
    foreach ($group in $groups) {
        $first = $group.Group[0]
        $rawId = [string]$first.participant_id
        $publicId = Convert-ParticipantId -RawParticipantId $rawId
        $condition = [string]$first.vr_condition_id
        $conditionInfo = Get-ConditionInfo -ConditionId $condition
        $metaKey = "{0}|{1}|{2}" -f $rawId, $first.block_id, $condition
        $meta = $metadataByKey[$metaKey]
        $demo = $DemographicsByRawId[$rawId]
        if ($null -ne $demo) {
            Add-NameDenyListEntries -Demographics $demo
        }

        $mappingInfo = Get-MappingInfo -ApkVariantId ([string]$first.apk_variant_id) -ApkFileCode ([string]$first.apk_file_code)
        if ($null -ne $meta) {
            $mappingInfo = Get-MappingInfo -ApkVariantId ([string]$meta.apk_variant_id) -ApkFileCode ([string]$meta.apk_file_code)
        }

        $values = @{}
        foreach ($item in $group.Group) {
            $values[[string]$item.item_id] = [string]$item.item_value
        }

        $rows += [pscustomobject][ordered]@{
            "Participant Number" = $publicId
            "Age" = $(if ($demo) { [string]$demo.age_years } else { "" })
            "Gender" = $(if ($demo) { [string]$demo.gender } else { "" })
            "Handedness" = $(if ($demo) { [string]$demo.handedness } else { "" })
            "Language" = $(if ($demo) { [string]$demo.language_code } else { "" })
            "Order" = $(if ($meta -and $meta.apk_run_position) { [string]$meta.apk_run_position } else { "" })
            "Mapping (Hand/Env)" = $mappingInfo.mapping
            "Condition Label" = $mappingInfo.condition_label
            "Condition Position" = $(if ($meta -and $meta.apk_run_position) { [string]$meta.apk_run_position } else { "" })
            "Condition Sequence" = $mappingInfo.condition_sequence
            "Experimental Condition" = $condition
            "Coherence Level" = $conditionInfo.coherence
            "Energy Level" = $conditionInfo.energy
            "Block ID" = [string]$first.block_id
            "Block Order" = [string]$first.block_order
            "Questionnaire Complete" = "true"
            "SAM Valence (1-9)" = $values["SAM1"]
            "SAM Arousal (1-9)" = $values["SAM2"]
            "SAM Dominance (1-9)" = $values["SAM3"]
            "Affect VAS Valence (-100 to 100)" = $values["valence"]
            "Affect VAS Arousal (-100 to 100)" = $values["arousal"]
            "Disgust VAS (0-100)" = $values["Disgust"]
            "Surprise VAS (0-100)" = $values["Surprise"]
            "Happiness VAS (0-100)" = $values["Happiness"]
            "Sadness VAS (0-100)" = $values["Sadness"]
            "Anger VAS (0-100)" = $values["Anger"]
            "Fear VAS (0-100)" = $values["Fear"]
            "Hand Embodiment Ownership (1-7)" = $values["Ownership"]
            "Hand Embodiment Agency (1-7)" = $values["Agency"]
        }
    }
    return $rows
}

function Import-StudyDataRoot {
    param(
        [Parameter(Mandatory=$true)][string]$StudyDataRoot,
        [Parameter(Mandatory=$true)][string]$PublicDataRoot
    )

    $dataDir = Join-Path $StudyDataRoot "data"
    if (-not (Test-Path -LiteralPath $dataDir -PathType Container)) {
        return @()
    }

    $demographics = Get-DemographicsIndex -StudyDataRoot $StudyDataRoot
    $participantMaxIndex = @{}
    $imports = @()

    $ecgFiles = Get-ChildItem -LiteralPath $dataDir -File -Filter "*_ECG_PolarH10.csv" |
        Where-Object { $_.Name -notmatch '_session_ECG_PolarH10_master\.csv$' } |
        Sort-Object Name

    foreach ($ecg in $ecgFiles) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($ecg.Name)
        if ($base -notmatch '^(?<code>.+)_(?<raw>P[A-Za-z]*\d+)_(?<block>B\d{2})_(?<condition>[A-Z]{2}_[A-Z]{2})_ECG_PolarH10$') {
            continue
        }

        $apkCode = $Matches["code"]
        $rawId = $Matches["raw"]
        $blockId = $Matches["block"]
        $condition = $Matches["condition"]
        $publicId = Convert-ParticipantId -RawParticipantId $rawId
        $conditionInfo = Get-ConditionInfo -ConditionId $condition

        $metadataPath = Join-Path $dataDir ("{0}_{1}_{2}_{3}_block_metadata.json" -f $apkCode, $rawId, $blockId, $condition)
        $meta = $null
        if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
            $meta = Read-JsonFile -Path $metadataPath
        }
        $mappingInfo = if ($meta) {
            Get-MappingInfo -ApkVariantId ([string]$meta.apk_variant_id) -ApkFileCode ([string]$meta.apk_file_code)
        } else {
            Get-MappingInfo -ApkVariantId "" -ApkFileCode $apkCode
        }

        if ($demographics.ContainsKey($rawId)) {
            Add-NameDenyListEntries -Demographics $demographics[$rawId]
        }

        $participantDir = Join-Path $PublicDataRoot $publicId
        $flatDir = Join-Path $PublicDataRoot "all-ecg-csv"
        $existingPattern = ("ECG_*_{0}_{1}_{2}_{3}_{4}.csv" -f $publicId, $mappingInfo.mapping, $condition, $conditionInfo.descriptor, $blockId)
        $existing = @()
        if (Test-Path -LiteralPath $participantDir -PathType Container) {
            $existing = @(Get-ChildItem -LiteralPath $participantDir -File -Filter $existingPattern -ErrorAction SilentlyContinue)
        }

        if ($existing.Count -gt 0 -and -not $AllowOverwrite) {
            $imports += [pscustomobject]@{
                status = "skipped_existing"
                raw_participant_id = $rawId
                public_participant_id = $publicId
                mapping = $mappingInfo.mapping
                condition = $condition
                block_id = $blockId
                source = $ecg.FullName
                destination = $existing[0].FullName
            }
            continue
        }

        if (-not $participantMaxIndex.ContainsKey($publicId)) {
            $participantMaxIndex[$publicId] = Get-ExistingMaxEcgIndex -DataRoot $PublicDataRoot -PublicParticipantId $publicId
        }
        $participantMaxIndex[$publicId] = [int]$participantMaxIndex[$publicId] + 1
        $ecgIndex = $participantMaxIndex[$publicId]
        $outName = ("ECG_{0:D2}_{1}_{2}_{3}_{4}_{5}.csv" -f $ecgIndex, $publicId, $mappingInfo.mapping, $condition, $conditionInfo.descriptor, $blockId)
        $participantOut = Join-Path $participantDir $outName
        $flatOut = Join-Path $flatDir $outName

        if (-not $DryRun) {
            if ((Test-Path -LiteralPath $participantOut -PathType Leaf) -and -not $AllowOverwrite) {
                throw "Refusing to overwrite $participantOut. Use -AllowOverwrite if this is intentional."
            }
            $replacements = @{}
            $replacements[$rawId] = $publicId
            Copy-SanitizedTextFile -Source $ecg.FullName -Destination $participantOut -Replacements $replacements
            Copy-SanitizedTextFile -Source $ecg.FullName -Destination $flatOut -Replacements $replacements
        }

        $imports += [pscustomobject]@{
            status = $(if ($DryRun) { "dry_run_would_import" } else { "imported" })
            raw_participant_id = $rawId
            public_participant_id = $publicId
            mapping = $mappingInfo.mapping
            condition = $condition
            block_id = $blockId
            source = $ecg.FullName
            destination = $participantOut
            flat_destination = $flatOut
        }
    }

    $masterRows = New-MasterRowsFromQuestionnaire -StudyDataRoot $StudyDataRoot -DemographicsByRawId $demographics
    return [pscustomobject]@{
        study_data_root = $StudyDataRoot
        ecg_imports = $imports
        master_rows = $masterRows
    }
}

function Update-MasterPsychometrics {
    param(
        [Parameter(Mandatory=$true)][string]$PublicDataRoot,
        [Parameter(Mandatory=$true)]$Rows,
        [string]$CorrectionPath = ""
    )

    $masterPath = Join-Path $PublicDataRoot "master_participant_psychometrics.csv"
    if (-not (Test-Path -LiteralPath $masterPath -PathType Leaf)) {
        throw "Missing master participant psychometrics CSV: $masterPath"
    }

    $existingRows = @(Import-Csv -LiteralPath $masterPath)
    $existingKeys = @{}
    foreach ($row in $existingRows) {
        $key = "{0}|{1}|{2}|{3}" -f $row."Participant Number", $row."Mapping (Hand/Env)", $row."Experimental Condition", $row."Block ID"
        $existingKeys[$key] = $true
    }

    $newRows = @()
    foreach ($row in $Rows) {
        $key = "{0}|{1}|{2}|{3}" -f $row."Participant Number", $row."Mapping (Hand/Env)", $row."Experimental Condition", $row."Block ID"
        if (-not $existingKeys.ContainsKey($key)) {
            $newRows += $row
            $existingKeys[$key] = $true
        }
    }

    $combined = @($existingRows) + @($newRows)
    $correctionStatus = Apply-MasterParticipantCorrections -Rows $combined -CorrectionPath $CorrectionPath
    $needsWrite = ($newRows.Count -gt 0 -or $correctionStatus.changed_cells -gt 0)

    if ($needsWrite -and -not $DryRun) {
        $combined | Export-Csv -LiteralPath $masterPath -NoTypeInformation -Encoding UTF8
    }

    return [pscustomobject]@{
        path = $masterPath
        existing_rows = $existingRows.Count
        new_rows = $newRows.Count
        corrections = $correctionStatus
        status = $(if ($DryRun -and $needsWrite) { "dry_run_would_update" } elseif ($needsWrite) { "updated" } else { "unchanged" })
    }
}

function Apply-MasterParticipantCorrections {
    param(
        [Parameter(Mandatory=$true)]$Rows,
        [string]$CorrectionPath = ""
    )

    $status = [ordered]@{
        path = $CorrectionPath
        applied_rows = 0
        changed_cells = 0
        status = "skipped"
    }
    if ([string]::IsNullOrWhiteSpace($CorrectionPath) -or -not (Test-Path -LiteralPath $CorrectionPath -PathType Leaf)) {
        return [pscustomobject]$status
    }

    $matchColumns = @(
        "Participant Number",
        "Mapping (Hand/Env)",
        "Experimental Condition",
        "Block ID"
    )
    $updateColumns = @(
        "Age",
        "Gender",
        "Handedness",
        "Language",
        "Order",
        "Condition Position",
        "Condition Sequence"
    )

    $corrections = @(Import-Csv -LiteralPath $CorrectionPath)
    foreach ($correction in $corrections) {
        $targets = @($Rows | Where-Object {
            $row = $_
            $matchesAll = $true
            foreach ($column in $matchColumns) {
                $expectedProperty = $correction.PSObject.Properties[$column]
                if ($null -eq $expectedProperty -or [string]::IsNullOrWhiteSpace([string]$expectedProperty.Value)) {
                    continue
                }
                $actualProperty = $row.PSObject.Properties[$column]
                if ($null -eq $actualProperty -or [string]$actualProperty.Value -ne [string]$expectedProperty.Value) {
                    $matchesAll = $false
                    break
                }
            }
            $matchesAll
        })

        foreach ($target in $targets) {
            $rowChanged = $false
            foreach ($column in $updateColumns) {
                $newProperty = $correction.PSObject.Properties[$column]
                if ($null -eq $newProperty -or [string]::IsNullOrWhiteSpace([string]$newProperty.Value)) {
                    continue
                }
                $targetProperty = $target.PSObject.Properties[$column]
                if ($null -eq $targetProperty) {
                    continue
                }
                if ([string]$targetProperty.Value -ne [string]$newProperty.Value) {
                    $targetProperty.Value = [string]$newProperty.Value
                    $status.changed_cells++
                    $rowChanged = $true
                }
            }
            if ($rowChanged) {
                $status.applied_rows++
            }
        }
    }

    $status.status = if ($status.changed_cells -gt 0) { "applied" } else { "no_changes_needed" }
    return [pscustomobject]$status
}

$script:RepoRootResolved = Resolve-RepoRoot
$script:HzdbResolved = $null
$script:NameDenyList = @{}
$publicDataRoot = Join-Path $script:RepoRootResolved "data\participant-datasets-by-catalog"
if (-not (Test-Path -LiteralPath $publicDataRoot -PathType Container)) {
    throw "Missing public data root: $publicDataRoot"
}
if ([string]::IsNullOrWhiteSpace($ParticipantCorrectionPath)) {
    $ParticipantCorrectionPath = Join-Path (Split-Path -Parent $PSCommandPath) "study6_public_participant_corrections.csv"
}

if ([string]::IsNullOrWhiteSpace($SourcePullDir)) {
    $script:HzdbResolved = Resolve-HzdbExecutable -Value $HzdbPath
    $SourcePullDir = New-HeadsetPull -Root $script:RepoRootResolved
} else {
    $SourcePullDir = (Resolve-Path -LiteralPath $SourcePullDir).Path
}

$studyDataRoots = @(Get-ChildItem -LiteralPath $SourcePullDir -Directory -Recurse -Filter "Study6_*_data" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match [regex]::Escape("\study6-dev\") })

$allImportResults = @()
$allMasterRows = @()
foreach ($root in $studyDataRoots) {
    $result = Import-StudyDataRoot -StudyDataRoot $root.FullName -PublicDataRoot $publicDataRoot
    $allImportResults += $result
    $allMasterRows += @($result.master_rows)
}

$masterStatus = Update-MasterPsychometrics -PublicDataRoot $publicDataRoot -Rows $allMasterRows -CorrectionPath $ParticipantCorrectionPath
$writtenPublicFiles = @()
foreach ($result in $allImportResults) {
    foreach ($item in @($result.ecg_imports)) {
        if ($item.status -eq "imported") {
            $writtenPublicFiles += $item.destination
            $writtenPublicFiles += $item.flat_destination
        }
    }
}
if ($masterStatus.status -eq "updated") {
    $writtenPublicFiles += $masterStatus.path
}
if (-not $DryRun) {
    Test-NoParticipantNames -Paths $writtenPublicFiles
}

$workbookStatus = [ordered]@{
    status = "skipped"
    reason = ""
    path = Join-Path $publicDataRoot "participant_data_collection_catalog.xlsx"
}
if ($DryRun) {
    $workbookStatus.reason = "dry_run"
} elseif ($SkipWorkbookUpdate) {
    $workbookStatus.reason = "SkipWorkbookUpdate"
} else {
    $workbookScript = Join-Path (Split-Path -Parent $PSCommandPath) "Update-ParticipantOverviewWorkbook.ps1"
    if (Test-Path -LiteralPath $workbookScript -PathType Leaf) {
        try {
            $workbookRaw = & $workbookScript -RepoRoot $script:RepoRootResolved
            $parsed = $workbookRaw | ConvertFrom-Json
            $workbookStatus.status = $parsed.status
            $workbookStatus.path = $parsed.path
            $workbookStatus.participant_rows = $parsed.participant_rows
            $workbookStatus.generated_at_utc = $parsed.generated_at_utc
        } catch {
            $fallback = Join-Path $publicDataRoot ("participant_data_collection_catalog_updated_{0}.xlsx" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
            $workbookRaw = & $workbookScript -RepoRoot $script:RepoRootResolved -OutPath $fallback
            $parsed = $workbookRaw | ConvertFrom-Json
            $workbookStatus.status = "updated_fallback"
            $workbookStatus.reason = "Primary workbook may be locked: $($_.Exception.Message)"
            $workbookStatus.path = $parsed.path
            $workbookStatus.participant_rows = $parsed.participant_rows
            $workbookStatus.generated_at_utc = $parsed.generated_at_utc
        }
    } else {
        $workbookStatus.reason = "Update-ParticipantOverviewWorkbook.ps1 missing"
    }
}

$receipt = [ordered]@{
    schema = "emotion_vr.study6_import_receipt.v1"
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    repo_root = $script:RepoRootResolved
    source_pull_dir = $SourcePullDir
    dry_run = [bool]$DryRun
    public_data_root = $publicDataRoot
    study_data_root_count = $studyDataRoots.Count
    ecg_imported_count = @($allImportResults.ecg_imports | Where-Object { $_.status -eq "imported" }).Count
    ecg_dry_run_would_import_count = @($allImportResults.ecg_imports | Where-Object { $_.status -eq "dry_run_would_import" }).Count
    ecg_skipped_existing_count = @($allImportResults.ecg_imports | Where-Object { $_.status -eq "skipped_existing" }).Count
    master_psychometrics = $masterStatus
    participant_overview_workbook = $workbookStatus
    import_results = $allImportResults
}

$receiptDir = Join-Path $script:RepoRootResolved "private\import-receipts"
$receiptName = "study6-import-receipt-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss")
$receiptPath = Join-Path $receiptDir $receiptName
if (-not $DryRun) {
    Write-JsonFile -Path $receiptPath -Value $receipt
} else {
    New-Item -ItemType Directory -Force -Path $receiptDir | Out-Null
    Write-JsonFile -Path $receiptPath -Value $receipt
}

Write-Output $receiptPath
