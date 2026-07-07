# eMotion Data Repository Sync Protocol

This repository is the OSF-facing data-publication mirror for:

**eMotion: Mapping Valence and Arousal Through Embodied and Environmental Particle Dynamics in Virtual Reality**

## Boundary

Only mirror the final, de-identified OSF-facing package from the working study repository:

`C:\Users\gfeje\Documents\GitHub\study-6\s6v\data-recorded\participant-datasets-by-catalog`

Do not copy raw headset sync folders, participant names, private lookup files, source manifests, per-session questionnaire exports, intermediate inventories, or orchestration scratch files.

## Required Contents

The data package in this repository should be:

`data\participant-datasets-by-catalog`

Expected contents:

- Participant folders named `P##`.
- ECG files named so alphabetical order reflects collection order:
  - `ECG_01_...` through `ECG_08_...` for complete participants.
  - `ECG_01_...` through `ECG_04_...` for participants with only one session so far.
- `master_participant_psychometrics.csv`.
- De-identified `participant_data_collection_catalog.xlsx`.

## Standard Future Sync

1. In the working `study-6` repository, sync headset data first.
2. Rebuild the participant catalog, OSF package, Excel files, and PDFs there.
3. In this repository, run:

```powershell
.\scripts\publish_data_repo.ps1
```

This mirrors the final package, validates the privacy boundary, commits, and pushes to GitHub.

## OSF Integration

This repository is intended to be connected to OSF through the OSF GitHub add-on/integration. Once linked in OSF, GitHub becomes the clean synchronization layer and OSF can expose the `data/participant-datasets-by-catalog` folder.

Keep the repository and OSF project private until data sharing terms, participant privacy checks, and release timing are confirmed.
