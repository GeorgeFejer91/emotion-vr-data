# eMotion: Mapping Valence and Arousal Through Embodied and Environmental Particle Dynamics in Virtual Reality

This repository mirrors the de-identified, OSF-ready data package for the eMotion VR study.

It is intentionally separate from the working `study-6` repository. The working repository can contain raw headset exports, orchestration files, intermediate inventories, private lookup files, and development scripts. This repository should contain only the final upload-facing data package and minimal dataset-facing documentation.

## Repository Contents

- `data/participant-datasets-by-catalog/`
  - De-identified participant folders.
  - `all-ecg-csv/`, a flat duplicate copy of every ECG CSV.
  - `master_participant_psychometrics.csv`.
  - De-identified, color-coded `participant_data_collection_catalog.xlsx`.
- `docs/`
  - `condition_variable_code_sheet.csv`.
  - `study6_vr_questionnaire_materials.pdf`.
- `Import Data/`
  - Standalone headset-to-repository import protocol.
  - Pulls Study 6 app-private headset data through `hzdb`.
  - Writes only de-identified `P##` public outputs and rejects participant names.
  - Refreshes the public color-coded participant overview workbook.

Most orchestration and development scripts still live in the working `study-6`
repository. The `Import Data/` folder is the portable exception that lets an
agent sync headset data into this standalone data repository from any lab
computer.

## Current Data Snapshot

The current package was mirrored from:

`C:\Users\gfeje\Documents\GitHub\study-6\s6v\data-recorded\participant-datasets-by-catalog`

Expected current snapshot:

- Participant folders: `P01`, `P02`, `P03`, `P04`, `P05`, `P07`, `P09`, `P11`, `P14`, `P23`, `P24`
- Participant-folder ECG CSV files: `76`
- Flat `all-ecg-csv/` ECG CSV files: `76`
- Master psychometrics rows: `76`
- Participant catalog rows: `24`
- Documentation files: `docs/condition_variable_code_sheet.csv`, `docs/study6_vr_questionnaire_materials.pdf`

## Standard Update Flow

For direct headset import from this standalone repository:

```powershell
.\Import Data\Sync-Study6HeadsetData.ps1 -Serial <QUEST_SERIAL>
```

For a safe preview against an already pulled headset folder:

```powershell
.\Import Data\Sync-Study6HeadsetData.ps1 -SourcePullDir "C:\path\to\headset-pull" -DryRun
```

The importer stores raw headset pulls and receipts under gitignored `private/`
and never commits demographics JSON or participant names. It also refreshes the
color-coded participant overview workbook without a participant-name column.

From the working `study-6` repository:

```powershell
tmp\participant-catalog-xlsx\publish_osf_data_repo.ps1
```

That command mirrors the clean data package into this repository, validates the mirrored files, commits any changes, and pushes to GitHub.

## OSF Sync

Recommended setup:

1. In OSF, open the project for this study.
2. Add the GitHub add-on/integration.
3. Connect this repository: `GeorgeFejer91/emotion-vr-data`.
4. Point collaborators to the `data/participant-datasets-by-catalog` folder as the upload-ready dataset.

After the GitHub add-on is connected, future OSF-facing updates happen from the working `study-6` repository by running `tmp\participant-catalog-xlsx\publish_osf_data_repo.ps1` and pushing the refreshed data to GitHub.

## Privacy Boundary

This repository should not contain:

- Participant names.
- Private name lookup sheets.
- Raw headset sync folders.
- Source manifests.
- Per-session questionnaire source JSON/CSV files.
- Intermediate inventory files.
- Working scripts from the study repository.
- AI/orchestration instructions.

License and public reuse terms should be confirmed before making the OSF project or this repository public.
