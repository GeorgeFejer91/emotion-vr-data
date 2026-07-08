param(
    [string]$RepoRoot = "",
    [string]$OutPath = "",
    [int]$PlannedParticipantMax = 24,
    [switch]$IncludeNames,
    [string[]]$NameSourceDir = @(),
    [string]$NameOverridePath = ""
)

$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        return (Resolve-Path -LiteralPath $RepoRoot).Path
    }
    $scriptDir = Split-Path -Parent $PSCommandPath
    return (Resolve-Path -LiteralPath (Join-Path $scriptDir "..")).Path
}

function ConvertTo-XmlText {
    param($Value)
    if ($null -eq $Value) {
        return ""
    }
    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function ConvertTo-ColumnName {
    param([Parameter(Mandatory=$true)][int]$Index)
    $name = ""
    while ($Index -gt 0) {
        $Index--
        $name = [char](65 + ($Index % 26)) + $name
        $Index = [Math]::Floor($Index / 26)
    }
    return $name
}

function New-CellXml {
    param(
        [Parameter(Mandatory=$true)][string]$Ref,
        $Value,
        [int]$Style = 2
    )
    $text = ConvertTo-XmlText $Value
    return "<c r=`"$Ref`" s=`"$Style`" t=`"inlineStr`"><is><t>$text</t></is></c>"
}

function New-RowXml {
    param(
        [Parameter(Mandatory=$true)][int]$RowNumber,
        [Parameter(Mandatory=$true)]$Values,
        [Parameter(Mandatory=$true)]$Styles,
        [int]$Height = 24
    )
    $cells = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $Values.Count; $index++) {
        $col = ConvertTo-ColumnName ($index + 1)
        $style = if ($index -lt $Styles.Count) { [int]$Styles[$index] } else { 2 }
        $cells.Add((New-CellXml -Ref "$col$RowNumber" -Value $Values[$index] -Style $style))
    }
    return "<row r=`"$RowNumber`" ht=`"$Height`" customHeight=`"1`">$($cells -join '')</row>"
}

function Read-FirstCsvTimestamp {
    param([Parameter(Mandatory=$true)][string]$Path)
    $reader = [System.IO.StreamReader]::new($Path)
    try {
        $header = $reader.ReadLine()
        $data = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($header) -or [string]::IsNullOrWhiteSpace($data)) {
            return ""
        }
        $headers = $header -split ","
        $values = $data -split ","
        $index = [Array]::IndexOf($headers, "host_received_timestamp_utc")
        if ($index -ge 0 -and $index -lt $values.Count) {
            return $values[$index]
        }
    } finally {
        $reader.Dispose()
    }
    return ""
}

function Format-Timestamp {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }
    try {
        return ([DateTimeOffset]::Parse($Value)).UtcDateTime.ToString("yyyy-MM-dd HH:mm")
    } catch {
        return $Value
    }
}

function ConvertTo-PublicParticipantId {
    param([string]$RawParticipantId)
    if ([string]::IsNullOrWhiteSpace($RawParticipantId)) {
        return ""
    }
    if ($RawParticipantId -match '(\d+)$') {
        return ("P{0:D2}" -f [int]$Matches[1])
    }
    return ""
}

function Get-JsonTextProperty {
    param(
        [Parameter(Mandatory=$true)]$Json,
        [Parameter(Mandatory=$true)][string[]]$PropertyNames
    )
    foreach ($name in $PropertyNames) {
        $property = $Json.PSObject.Properties |
            Where-Object { $_.Name -ieq $name } |
            Select-Object -First 1
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return ([string]$property.Value).Trim()
        }
    }
    return ""
}

function Get-ParticipantNameLookup {
    param([string[]]$SourceDirs)

    $lookup = @{}
    foreach ($sourceDir in $SourceDirs) {
        if ([string]::IsNullOrWhiteSpace($sourceDir)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
            continue
        }

        $demographicFiles = @(Get-ChildItem -LiteralPath $sourceDir -Recurse -File -Filter "*demographics*.json" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc)
        foreach ($file in $demographicFiles) {
            try {
                $json = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            } catch {
                continue
            }

            $rawParticipantId = Get-JsonTextProperty -Json $json -PropertyNames @(
                "participant_id",
                "participantId",
                "participant_number",
                "participantNumber"
            )
            if ([string]::IsNullOrWhiteSpace($rawParticipantId) -and $file.BaseName -match '^([A-Za-z]+\d+)_demographics') {
                $rawParticipantId = $Matches[1]
            }

            $participantId = ConvertTo-PublicParticipantId $rawParticipantId
            if ([string]::IsNullOrWhiteSpace($participantId)) {
                continue
            }

            $name = Get-JsonTextProperty -Json $json -PropertyNames @(
                "participant_name",
                "participantName",
                "name"
            )
            if ([string]::IsNullOrWhiteSpace($name)) {
                $first = Get-JsonTextProperty -Json $json -PropertyNames @(
                    "participant_first_name",
                    "participantFirstName",
                    "first_name",
                    "firstName"
                )
                $last = Get-JsonTextProperty -Json $json -PropertyNames @(
                    "participant_last_name",
                    "participantLastName",
                    "last_name",
                    "lastName"
                )
                $name = ("$first $last").Trim()
            }
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $lookup[$participantId] = $name
            }
        }
    }
    return $lookup
}

function Add-ParticipantNameOverrides {
    param(
        [Parameter(Mandatory=$true)]$Lookup,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $Lookup
    }

    $rows = @(Import-Csv -LiteralPath $Path)
    foreach ($row in $rows) {
        $participant = ""
        foreach ($propertyName in @("Participant Nr", "Participant", "participant_id", "participantId", "participant_number", "participantNumber")) {
            $property = $row.PSObject.Properties |
                Where-Object { $_.Name -ieq $propertyName } |
                Select-Object -First 1
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $participant = [string]$property.Value
                break
            }
        }

        $participantId = ConvertTo-PublicParticipantId $participant
        if ([string]::IsNullOrWhiteSpace($participantId) -and $participant -match '^P\d+$') {
            $participantId = ("P{0:D2}" -f [int]($participant -replace '\D',''))
        }
        if ([string]::IsNullOrWhiteSpace($participantId)) {
            continue
        }

        $name = ""
        foreach ($propertyName in @("Name", "participant_name", "participantName")) {
            $property = $row.PSObject.Properties |
                Where-Object { $_.Name -ieq $propertyName } |
                Select-Object -First 1
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $name = ([string]$property.Value).Trim()
                break
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $Lookup[$participantId] = $name
        }
    }
    return $Lookup
}

function Get-MappingSummary {
    param(
        [Parameter(Mandatory=$true)][string]$ParticipantDir,
        [Parameter(Mandatory=$true)][string]$ParticipantId,
        [Parameter(Mandatory=$true)][string]$Mapping
    )
    $files = @()
    if (Test-Path -LiteralPath $ParticipantDir -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $ParticipantDir -File -Filter ("ECG_*_{0}_{1}_*.csv" -f $ParticipantId, $Mapping) -ErrorAction SilentlyContinue | Sort-Object Name)
    }
    $timestamps = @()
    foreach ($file in $files) {
        $timestamp = Read-FirstCsvTimestamp -Path $file.FullName
        if (-not [string]::IsNullOrWhiteSpace($timestamp)) {
            $timestamps += $timestamp
        }
    }
    $earliest = ""
    if ($timestamps.Count -gt 0) {
        $earliest = ($timestamps | Sort-Object | Select-Object -First 1)
    }
    return [pscustomobject]@{
        count = $files.Count
        timestamp_raw = $earliest
        timestamp_display = Format-Timestamp $earliest
    }
}

function New-WorksheetXml {
    param(
        [Parameter(Mandatory=$true)][string[]]$Columns,
        [Parameter(Mandatory=$true)][string[]]$Rows,
        [string]$Dimension
    )
    $colsXml = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $colNum = $i + 1
        $colsXml.Add("<col min=`"$colNum`" max=`"$colNum`" width=`"$($Columns[$i])`" customWidth=`"1`" />")
    }
    return @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <dimension ref="$Dimension"/>
  <sheetViews>
    <sheetView showGridLines="0" workbookViewId="0">
      <pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>
      <selection pane="bottomLeft"/>
    </sheetView>
  </sheetViews>
  <sheetFormatPr defaultRowHeight="18"/>
  <cols>$($colsXml -join '')</cols>
  <sheetData>$($Rows -join '')</sheetData>
</worksheet>
"@
}

function Add-ZipEntry {
    param(
        [Parameter(Mandatory=$true)]$Archive,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Content
    )
    $entry = $Archive.CreateEntry($Name)
    $stream = $entry.Open()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally {
        $stream.Dispose()
    }
}

function Write-Workbook {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string[]]$CatalogColumnWidths,
        [Parameter(Mandatory=$true)]$CatalogRows,
        [Parameter(Mandatory=$true)]$LegendRows
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $tempPath = "$Path.tmp"
    if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
        Remove-Item -LiteralPath $tempPath -Force
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $catalogXml = New-WorksheetXml `
        -Columns $CatalogColumnWidths `
        -Rows $CatalogRows `
        -Dimension ("A1:{0}{1}" -f (ConvertTo-ColumnName $CatalogColumnWidths.Count), $CatalogRows.Count)
    $legendXml = New-WorksheetXml `
        -Columns @("34", "78", "18") `
        -Rows $LegendRows `
        -Dimension ("A1:C{0}" -f $LegendRows.Count)

    $archive = [System.IO.Compression.ZipFile]::Open($tempPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Add-ZipEntry $archive "[Content_Types].xml" @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>
'@
        Add-ZipEntry $archive "_rels/.rels" @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
'@
        Add-ZipEntry $archive "xl/_rels/workbook.xml.rels" @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>
'@
        Add-ZipEntry $archive "xl/workbook.xml" @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
    <sheet name="Participant Catalog" sheetId="1" r:id="rId1"/>
    <sheet name="Legend" sheetId="2" r:id="rId2"/>
  </sheets>
</workbook>
'@
        Add-ZipEntry $archive "xl/styles.xml" @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="2">
    <font><sz val="11"/><color rgb="FF1F2933"/><name val="Calibri"/></font>
    <font><b/><sz val="11"/><color rgb="FF1F2933"/><name val="Calibri"/></font>
  </fonts>
  <fills count="7">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFE5E7EB"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFC6EFCE"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFBDD7EE"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFF3F4F6"/><bgColor indexed="64"/></patternFill></fill>
  </fills>
  <borders count="2">
    <border><left/><right/><top/><bottom/><diagonal/></border>
    <border><left style="thin"><color rgb="FFB7B7B7"/></left><right style="thin"><color rgb="FFB7B7B7"/></right><top style="thin"><color rgb="FFB7B7B7"/></top><bottom style="thin"><color rgb="FFB7B7B7"/></bottom><diagonal/></border>
  </borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="8">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="0" fillId="3" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="0" fillId="4" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="0" fillId="5" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="0" fillId="6" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="1" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
  </cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>
'@
        Add-ZipEntry $archive "xl/worksheets/sheet1.xml" $catalogXml
        Add-ZipEntry $archive "xl/worksheets/sheet2.xml" $legendXml
    } finally {
        $archive.Dispose()
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }
    Move-Item -LiteralPath $tempPath -Destination $Path
}

$root = Resolve-RepoRoot
$dataRoot = Join-Path $root "data\participant-datasets-by-catalog"
if ([string]::IsNullOrWhiteSpace($OutPath)) {
    if ($IncludeNames) {
        $OutPath = Join-Path $root "private\participant_data_collection_catalog_with_names.xlsx"
    } else {
        $OutPath = Join-Path $dataRoot "participant_data_collection_catalog.xlsx"
    }
}
if (-not [System.IO.Path]::IsPathRooted($OutPath)) {
    $OutPath = Join-Path $root $OutPath
}

if ($IncludeNames -and $NameSourceDir.Count -eq 0) {
    $privateDir = Join-Path $root "private"
    if (Test-Path -LiteralPath $privateDir -PathType Container) {
        $NameSourceDir = @($privateDir)
    }
}
if ($IncludeNames -and [string]::IsNullOrWhiteSpace($NameOverridePath)) {
    $NameOverridePath = Join-Path $root "private\participant_name_overrides.csv"
}

$masterPath = Join-Path $dataRoot "master_participant_psychometrics.csv"
if (-not (Test-Path -LiteralPath $masterPath -PathType Leaf)) {
    throw "Missing master participant psychometrics CSV: $masterPath"
}

$masterRows = @(Import-Csv -LiteralPath $masterPath)
$byParticipant = $masterRows | Group-Object -Property "Participant Number"
$demoByParticipant = @{}
foreach ($group in $byParticipant) {
    $first = $group.Group[0]
    $demoByParticipant[$group.Name] = $first
}
$nameByParticipant = if ($IncludeNames) {
    $lookup = Get-ParticipantNameLookup -SourceDirs $NameSourceDir
    Add-ParticipantNameOverrides -Lookup $lookup -Path $NameOverridePath
} else {
    @{}
}

$participantIds = New-Object System.Collections.Generic.HashSet[string]
foreach ($group in $byParticipant) {
    [void]$participantIds.Add($group.Name)
}
Get-ChildItem -LiteralPath $dataRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^P\d+$' } |
    ForEach-Object { [void]$participantIds.Add($_.Name) }
for ($i = 1; $i -le $PlannedParticipantMax; $i++) {
    [void]$participantIds.Add(("P{0:D2}" -f $i))
}

$headers = @("Participant Nr")
if ($IncludeNames) {
    $headers += "Name"
}
$headers += @(
    "Age",
    "Gender",
    "Handedness",
    "Language",
    "Dynamic Hands + Static Icosphere (UTC timestamp)",
    "Dynamic Hands ECG CSV count",
    "Static Hands + Dynamic Icosphere (UTC timestamp)",
    "Static Hands ECG CSV count",
    "Collection order",
    "Status",
    "Remarks"
)
$catalogColumnWidths = @("16")
if ($IncludeNames) {
    $catalogColumnWidths += "24"
}
$catalogColumnWidths += @("10", "14", "14", "12", "32", "16", "32", "16", "38", "22", "52")
$catalogRows = New-Object System.Collections.Generic.List[string]
$catalogRows.Add((New-RowXml -RowNumber 1 -Values $headers -Styles (@(1) * $headers.Count) -Height 46))

$rowNumber = 2
foreach ($participantId in ($participantIds | Sort-Object { [int](($_ -replace '\D','')) })) {
    $participantDir = Join-Path $dataRoot $participantId
    $hand = Get-MappingSummary -ParticipantDir $participantDir -ParticipantId $participantId -Mapping "Hand"
    $env = Get-MappingSummary -ParticipantDir $participantDir -ParticipantId $participantId -Mapping "Env"
    $demo = $demoByParticipant[$participantId]

    $handHasData = $hand.count -gt 0
    $envHasData = $env.count -gt 0
    $handComplete = $hand.count -ge 4
    $envComplete = $env.count -ge 4
    $hasPartialMapping = (($handHasData -and -not $handComplete) -or ($envHasData -and -not $envComplete))
    $completeMappingCount = 0
    if ($handComplete) { $completeMappingCount++ }
    if ($envComplete) { $completeMappingCount++ }
    $status = if ($handComplete -and $envComplete) {
        "complete"
    } elseif ($hasPartialMapping) {
        "partial"
    } elseif ($completeMappingCount -eq 1) {
        "one mapping complete"
    } else {
        "not started"
    }
    $order = ""
    if ($handHasData -and $envHasData) {
        $order = if ($hand.timestamp_raw -le $env.timestamp_raw) { "Dynamic Hands + Static Icosphere first" } else { "Static Hands + Dynamic Icosphere first" }
    } elseif ($handHasData) {
        $order = "Dynamic Hands + Static Icosphere only collected"
    } elseif ($envHasData) {
        $order = "Static Hands + Dynamic Icosphere only collected"
    }

    $remarks = @()
    if ($handHasData) { $remarks += "Dynamic/Hand ECG files: $($hand.count)" }
    if ($envHasData) { $remarks += "Static/Env ECG files: $($env.count)" }
    if ($status -eq "partial") {
        if (-not $handHasData) {
            $remarks += "Missing Dynamic/Hand mapping"
        } elseif (-not $handComplete) {
            $remarks += "Dynamic/Hand mapping has fewer than 4 ECG files"
        }
        if (-not $envHasData) {
            $remarks += "Missing Static/Env mapping"
        } elseif (-not $envComplete) {
            $remarks += "Static/Env mapping has fewer than 4 ECG files"
        }
    }

    $handStyle = 2
    $envStyle = 2
    if ($handHasData -and $envHasData) {
        if ($hand.timestamp_raw -le $env.timestamp_raw) {
            $handStyle = 3
            $envStyle = 4
        } else {
            $handStyle = 4
            $envStyle = 3
        }
    } elseif ($handHasData) {
        $handStyle = 3
    } elseif ($envHasData) {
        $envStyle = 3
    }
    $statusStyle = if ($status -eq "complete") { 3 } elseif ($status -eq "one mapping complete" -or $status -eq "partial") { 5 } else { 6 }

    $values = @($participantId)
    if ($IncludeNames) {
        $values += $(if ($nameByParticipant.ContainsKey($participantId)) { $nameByParticipant[$participantId] } else { "" })
    }
    $values += @(
        $(if ($demo) { $demo.Age } else { "" }),
        $(if ($demo) { $demo.Gender } else { "" }),
        $(if ($demo) { $demo.Handedness } else { "" }),
        $(if ($demo) { $demo.Language } else { "" }),
        $hand.timestamp_display,
        $(if ($hand.count -gt 0) { [string]$hand.count } else { "" }),
        $env.timestamp_display,
        $(if ($env.count -gt 0) { [string]$env.count } else { "" }),
        $order,
        $status,
        ($remarks -join "; ")
    )
    $styles = @(2)
    if ($IncludeNames) {
        $styles += 2
    }
    $styles += @(2, 2, 2, 2, $handStyle, $handStyle, $envStyle, $envStyle, 2, $statusStyle, 2)
    $catalogRows.Add((New-RowXml -RowNumber $rowNumber -Values $values -Styles $styles -Height 30))
    $rowNumber++
}

$legendRows = New-Object System.Collections.Generic.List[string]
$legendRows.Add((New-RowXml -RowNumber 1 -Values @("Item", "Meaning", "Color") -Styles @(1, 1, 1) -Height 34))
$legendRows.Add((New-RowXml -RowNumber 2 -Values @("Green condition cells", "First collected mapping for that participant, or the only collected mapping.", "") -Styles @(2, 2, 3) -Height 34))
$legendRows.Add((New-RowXml -RowNumber 3 -Values @("Blue condition cells", "Second collected mapping for that participant.", "") -Styles @(2, 2, 4) -Height 34))
$legendRows.Add((New-RowXml -RowNumber 4 -Values @("Yellow status", "One mapping is complete, or an attempted mapping is partial and needs review.", "") -Styles @(2, 2, 5) -Height 34))
$legendRows.Add((New-RowXml -RowNumber 5 -Values @("Gray status", "No public ECG files are present for this participant.", "") -Styles @(2, 2, 6) -Height 34))
$privacyBoundary = if ($IncludeNames) {
    "Names included from private demographic sources. Keep this workbook in gitignored private storage; do not publish or commit."
} else {
    "This public workbook intentionally omits participant names and raw demographics JSON."
}
$legendRows.Add((New-RowXml -RowNumber 6 -Values @("Privacy boundary", $privacyBoundary, "") -Styles @(2, 2, 2) -Height 34))

Write-Workbook -Path $OutPath -CatalogColumnWidths $catalogColumnWidths -CatalogRows $catalogRows -LegendRows $legendRows

[pscustomobject]@{
    status = "updated"
    path = $OutPath
    include_names = [bool]$IncludeNames
    participant_rows = $catalogRows.Count - 1
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json -Depth 3
