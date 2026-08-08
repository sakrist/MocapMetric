## Why

WatchConnectivity can deliver the optional audio file after the iPhone has
already assembled the core recording package. The recording list then shows
audio from the loose file, while sharing the package sends a folder without
that audio asset.

## What Changes

- Merge late optional assets into an existing recording package.
- Keep the package as the single item shared through AirDrop.
- Add regression coverage for audio arriving after core package assembly.

## Impact

This changes only iPhone package assembly and export consistency. Recording
filenames, binary formats, and the package schema remain unchanged.
