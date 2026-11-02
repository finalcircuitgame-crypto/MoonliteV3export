# Moonlite V3 Cutscene Tool

Executor-side GUI for capturing, decoding, merging, and exporting Moonlite V3 cutscenes.

## Load with `loadstring`

If this repository is public, run this one-line loader in Xeno:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/finalcircuitgame-crypto/MoonliteV3export/main/MoonliteTool.lua"))()
```

This downloads and executes the latest `MoonliteTool.lua` from the repository's `main` branch.

### Important: repository visibility

This repository is currently **private**. Roblox executor HTTP requests do not automatically authenticate as your GitHub account, so the raw URL above will not be readable while the repository remains private.

To use that exact one-line loader, either:
- make the repository public; or
- publish the script through another HTTPS location that your executor can access.

Do **not** put a GitHub personal access token into the loader or a script shared with other people. Anyone who obtains the script could extract the token.

If you want to keep the repository private, open `MoonliteTool.lua` in your local copy and execute its contents through Xeno's editor instead.

## Requirements

- Xeno or another executor environment that supports `loadstring` and `game:HttpGet` for the loader method.
- Executor filesystem functions: `isfolder`, `makefolder`, `isfile`, `readfile`, and `writefile`.
- `saveinstance` for the model-export button.
- The game's Moonlite modules at:

```text
ReplicatedStorage
└── Client
    └── Modules
        └── MoonliteV3
            ├── Container
            ├── Document
            └── Stream
```

## What the tool does

1. Scans `ReplicatedStorage.Assets.CutScenes` for packages containing a valid Moonlite `Scene` manifest.
2. Displays stream-enabled packages in the GUI, including their window counts.
3. Reads each selected package's `MoonliteStreamId` and `MoonliteStreamWindowCount` attributes.
4. Requests the package's stream windows using the game's `ReplicatedStorage.Network.CutScenes["RF:RequestCutsceneChunk"]` RemoteFunction.
5. Saves the returned packet data locally under `MoonliteCapture/<PackageName>/`.
6. Reconstructs and decodes each packet using `Stream.SceneFromPacket` and `Container.Read`.
7. Verifies each decoded window with `Stream.AssertWindow`.
8. Reassembles the full document using the stream-aware merge algorithm described below.
9. Creates a new Moonlite `Scene` and parents it under a generated folder in `Workspace`.
10. Offers a SaveInstance export of that generated folder.

## GUI controls

- **Refresh** — rescans `ReplicatedStorage.Assets.CutScenes`.
- **Cutscene list** — selects a discovered stream-enabled package.
- **Local capture folder** — sets the root directory; defaults to `MoonliteCapture`.
- **Acquire + Decode + Merge** — requests all windows, saves them, decodes them, merges them, and creates the Workspace result.
- **Import Existing Capture** — skips the acquisition requests and uses packet files already saved locally.
- **Export with SaveInstance** — calls `saveinstance({ Object = outputFolder })` for the generated Workspace folder.

## Local capture layout

For a package named `NIGHT1TESTING`, files are written as:

```text
MoonliteCapture/
└── NIGHT1TESTING/
    ├── COMPLETE.txt
    ├── window_001/
    │   ├── header.bin
    │   ├── info.txt
    │   ├── value_0001.bin
    │   └── value_0002.bin
    ├── window_002/
    │   ├── header.bin
    │   ├── info.txt
    │   └── value_0001.bin
    └── ...
```

Each `info.txt` records the window index and number of packet values. If acquisition is interrupted, already-written windows remain on disk and can be inspected or imported.

## Merge logic

The implementation follows the supplied Moonlite `Stream.lua` and `Document.lua` behavior:

1. Decode the selected package's `Scene` as the stream manifest.
2. Use `Stream.Layout(manifest)` to obtain the expected window size and count.
3. Decode every packet and verify it with `Stream.AssertWindow(manifest, window)`.
4. Clone the manifest, preserving its targets, cues, media, metadata, and Action-track keys.
5. For each non-Action track, gather keys from all windows, deduplicate identical records with the same absolute `Frame`, and sort them chronologically.
6. Abort if two different key records occupy the same track/frame.
7. Remove `Metadata.Stream`, validate the reconstructed document with `Document.Validate`, and serialize it with `Container.Create`.

The windows use absolute frame numbers. `Stream.Split()` intentionally includes a preceding context key in a window when needed for interpolation, so identical boundary keys can occur in adjacent windows.

`Document.Merge()` is not used: it combines independently bound timelines, while stream windows are partitions of the same original tracks.

## Workspace output

A successful reconstruction is placed at:

```text
Workspace
└── <PackageName>_Reconstructed
    └── Scene
        └── _MoonliteV3Data
            ├── 1
            ├── 2
            └── ...
```

The export button passes this generated folder as the `Object` to SaveInstance. The exact exported filename, extension, and destination are determined by the installed SaveInstance implementation and its settings.

## Troubleshooting

**The GUI does not appear**
- Check the executor console for an error before the GUI is created.
- Confirm the Moonlite module paths exist.
- Confirm `ReplicatedStorage.Assets.CutScenes` exists.

**The cutscene list is empty**
- The script currently scans `ReplicatedStorage.Assets.CutScenes` only.
- A package must have a `Scene` StringValue containing a valid Moonlite V3 container and stream manifest.

**A window request fails**
- Check the returned status and packet data.
- Confirm the selected package has valid `MoonliteStreamId` and `MoonliteStreamWindowCount` attributes.
- Check whether the server expects a different request limit or retry interval.

**A window fails decoding**
- Check that the packet header and all values were saved.
- Confirm that the game's Moonlite module version matches the capture format.

**SaveInstance fails**
- Confirm `saveinstance` exists in the executor.
- Check the executor's console and its configured export destination.

## Project files

- `MoonliteTool.lua` — standalone executor GUI and processing pipeline.
- `MERGE_LOGIC.md` — explanation of stream reconstruction.
- `default.project.json` — Rojo project manifest for the modular project layout.
