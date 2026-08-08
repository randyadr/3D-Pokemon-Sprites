# Pokemon Stadium Overworld Models

Adds Pokemon Stadium 3D models to Gen1Recomp for identified overworld Pokemon and battles, with follower locomotion and compatibility integrations.

## Features

- Pokemon Stadium 3D models for overworld followers.
- Stadium model integration in battles where the installed voxel host exposes Stadium support.
- Ground locomotion and species-specific walking behavior, including Charizard, Mankey, and Pikachu tuning.
- Lead-party and Followers EX compatibility.
- Dramatic Sky Ride compatibility.
- Water reflection and 3D shadow integration where supported by the installed Dramatic Shape build.
- Android Stadium ROM picker support.
- Multi-fork Dramatic Shape compatibility for both newer `drawCast()` renderers and older 1.0.x direct-render layouts.

## Dramatic Shape compatibility

Dramatic Shape is a runtime host for the 3D model renderer, but v0.1.56 no longer declares it as a hard index/manifest dependency. This prevents Gen1Recomp from rejecting the add-on before a compatible fork can be capability-detected.

The current official Dramatic Shape build and older/derived builds that preserve the `DRAMALESS_SHAPE` library export are supported. If no compatible voxel host is enabled, this add-on loads dormant instead of crashing the game or being rejected solely for the missing hard dependency.

## Requirements

- Gen1Recomp compatible with the declared manifest range.
- A compatible Dramatic Shape / DramaticShapeVoxelMod build for actual 3D overworld rendering.
- A user-supplied compatible Pokemon Stadium ROM for local model import where that host requires it.

No Pokemon Stadium ROM, extracted model pack, or Nintendo-owned game assets are distributed by this mod.

## Install and updates

Install the release asset named `STADIUM_OVERWORLD_MODELS-X.Y.Z.zip` through Gen1Recomp's MODS screen.

The mod declares `randyadr/3D-Pokemon-Sprites` as its GitHub update source. With automatic version checking enabled in the mod index, future GitHub Releases can be detected by the index and by Gen1Recomp's Update / Versions functionality without submitting a new index pull request for every version.


Compatible voxel hosts include **Dramatic Shape** and **Dramaless Shape**.
