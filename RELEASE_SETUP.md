# Release/update setup — v0.1.58

This package contains the updated Gen1Recomp mod-index entry plus the current installable release asset.

## 1. Mod-index submission

Copy this directory into `bryanthaboi/gen1recomp-mod-index`:

    mods/randyadr@STADIUM_OVERWORLD_MODELS/

Important v0.1.58 change: the index `dependencies` array is intentionally empty. Dramatic Shape is capability-detected at runtime so compatible forks are not blocked by the index before the mod can inspect them.

The entry keeps automatic GitHub version checking enabled for:

    randyadr/3D-Pokemon-Sprites

## 2. GitHub release

In `randyadr/3D-Pokemon-Sprites`, create/publish a GitHub Release with tag:

    v0.1.58

Attach the included installable asset:

    release_asset/STADIUM_OVERWORLD_MODELS-0.1.58.zip

The installable ZIP already has the mod files at its archive root.

## Compatibility behavior

- Current/newer Dramatic Shape renderer: patches the `drawCast()` character seam.
- Older 1.0.x/TeJota-style renderer: patches the final character loop directly inside `VoxelScene.render()`.
- Missing or unrecognized host: add-on stays dormant instead of aborting load.

This is compatibility-by-capability, not a promise that every future private fork can never break its exported API. Forks that preserve the Dramatic Shape `exports.lib.require` contract can be adapted without a launcher-level hard dependency.
