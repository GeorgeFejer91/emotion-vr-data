# Study 6 Headset Data Import Protocol

This folder is the standalone, agent-runnable import protocol for moving Study 6
headset data into this external data repository.

It is intentionally self-contained. An agent on any lab computer should be able
to clone this repository, connect a Quest headset, install `hzdb`, and run the
PowerShell module here without relying on the working `study-6` repository.

## Privacy Rule

Participant names must never be committed to this repository.

The importer reads demographics only to recover non-name fields needed for the
catalog, such as age, gender, handedness, and language. It never writes these
demographics JSON files into `data/`. It also refuses to finish if a newly
written public output contains a participant first name, last name, or full name
seen in the headset pull.

Public outputs use the de-identified participant code format `P##`.

Examples:

- `PH1` becomes `P01`
- `PH9` becomes `P09`
- `PI11` becomes `P11`

## Normal Sync

From the root of this repository:

```powershell
.\Import Data\Sync-Study6HeadsetData.ps1 -Serial <QUEST_SERIAL>
```

The script will:

1. Pull installed Study 6 app-private data from the headset through `hzdb`.
2. Store the raw headset pull under gitignored `private/headset-sync/`.
3. Import block ECG CSV files into `data/participant-datasets-by-catalog/P##/`.
4. Mirror each imported ECG CSV into `data/participant-datasets-by-catalog/all-ecg-csv/`.
5. Append de-identified questionnaire summary rows to
   `data/participant-datasets-by-catalog/master_participant_psychometrics.csv`
   when they are not already present.
6. Refresh the color-coded participant overview workbook at
   `data/participant-datasets-by-catalog/participant_data_collection_catalog.xlsx`.
7. Write an import receipt under gitignored `private/import-receipts/`.

By default the script does not force-stop any app on the headset. If a run has
fully ended and a clean pull is needed, add `-ForceStop`.

## Import From An Existing Pull

If another agent has already pulled headset data into a local folder, run:

```powershell
.\Import Data\Sync-Study6HeadsetData.ps1 -SourcePullDir "C:\path\to\headset-pull"
```

Use `-DryRun` to verify what would be imported without modifying public data:

```powershell
.\Import Data\Sync-Study6HeadsetData.ps1 -SourcePullDir "C:\path\to\headset-pull" -DryRun
```

## Refresh Only The Color-Coded Workbook

To rebuild the public color-coded Excel overview from the already imported
de-identified data:

```powershell
.\Import Data\Update-ParticipantOverviewWorkbook.ps1
```

This workbook intentionally omits the participant-name column. It keeps the
useful earlier structure: colored condition timestamp cells, collection order,
status, and remarks.

If Excel has the workbook open, Windows may lock the file. In that case the
sync script writes a timestamped anonymous fallback workbook next to the main
catalog, named `participant_data_collection_catalog_updated_YYYYMMDD-HHMMSS.xlsx`.

## Private Named Operator Workbook

For local operator use only, a name-bearing copy can be generated into the
gitignored `private/` folder. Do not move this file into `data/` or commit it.

```powershell
$sources = @(
  "C:\path\to\study-6\s6v\data-recorded",
  "C:\path\to\headset-pull"
)
.\Import Data\Update-ParticipantOverviewWorkbook.ps1 `
  -OutPath "private\participant_data_collection_catalog_with_names.xlsx" `
  -IncludeNames `
  -NameSourceDir $sources
```

The named workbook uses the same color coding as the public workbook, but adds
a `Name` column from local demographics JSON files.

## Required Tools

- PowerShell 5.1 or newer.
- Meta Horizon Debug Bridge (`hzdb`) available on `PATH`, or pass `-HzdbPath`.
- A connected Quest headset with developer mode and USB debugging enabled.
- `tar` available on the host for unpacking the app-private archive.

If more than one headset is connected, always pass `-Serial`.

## What Must Not Be Committed

Do not commit:

- `private/`
- `raw/`
- Excel lock files such as `~$participant_data_collection_catalog.xlsx`
- Headset pull tarballs
- Source manifests that include local machine paths
- Name lookup sheets
- Demographics JSON files with first or last names

The color-coded public overview is safe to commit because it is generated only
from public `P##` folders and `master_participant_psychometrics.csv`.

The repository `.gitignore` is configured to keep these out of Git.
