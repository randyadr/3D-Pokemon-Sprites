# Pokemon Stadium Overworld Models v0.1.47

A Gen1Recomp companion mod for Dramatic Shape that replaces identified overworld Pokemon with Pokemon Stadium 3D models and extends the 3D presentation into battles.

No Pokemon Stadium ROM, extracted model files, or Nintendo assets are distributed with this repository. Stadium data is imported locally from the user's own compatible ROM through Dramatic Shape / the mod's ROM picker.

## Features

- Pokemon Stadium 3D models for identified overworld Pokemon
- Lead-party and Followers EX compatibility, including configurable follower count
- Ground locomotion / waddles for non-Flying species
- Curated overworld scaling for tiny and very large Pokemon
- Stadium battle model integration and procedural 2D/3D battle effects
- 3D wind funnels and branching electrical effects
- Android Stadium ROM file picker
- Dramatic Sky Ride compatibility
- Water reflection and 3D shadow integration where supported by Dramatic Shape

## Requirements

- Gen1Recomp compatible with the manifest range
- Dramatic Shape (`DRAMATIC_SHAPE`)
- A user-supplied compatible Pokemon Stadium ROM for local model import

Optional integrations include Followers EX and Dramatic Sky Ride.

## Install

Download the release asset named `STADIUM_OVERWORLD_MODELS-X.Y.Z.zip`, then import it from Gen1Recomp's **MODS > Import mod .zip** screen.

Do not extract or bundle a Stadium ROM with this mod.

## Automatic updates

This mod declares:

```json
"github": "randyadr/3D-Pokemon-Sprites"
```

Gen1Recomp can use GitHub Releases from this repository for **Update / Versions**. Release assets are generated automatically with the mod files at the ZIP root.

## v0.1.47

- Adds GitHub repository metadata required by Gen1Recomp's updater.
- Adds the standard automatic GitHub Release workflow.
- Keeps the v0.1.46 gameplay/rendering behavior unchanged.
