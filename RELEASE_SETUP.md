# Release/update setup — v0.1.53

This package contains the updated Gen1Recomp mod-index entry plus the current installable release asset.

## 1. Mod-index submission

Copy this directory into `bryanthaboi/gen1recomp-mod-index`:

    mods/randyadr@STADIUM_OVERWORLD_MODELS/

The entry is set to version `0.1.53` and keeps automatic GitHub version checking enabled for:

    randyadr/3D-Pokemon-Sprites

## 2. GitHub release

In `randyadr/3D-Pokemon-Sprites`, create/publish a GitHub Release with tag:

    v0.1.53

Attach the included installable asset:

    release_asset/STADIUM_OVERWORLD_MODELS-0.1.53.zip

The installable ZIP already has the mod files at its archive root.

## Future updates

For v0.1.54 and later, publish a new GitHub Release and attach:

    STADIUM_OVERWORLD_MODELS-<version>.zip

Because the index entry contains `github: randyadr/3D-Pokemon-Sprites` and `automatic_version_check: true`, you should not need a new index PR for each normal version bump.
