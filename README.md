# Moonlite V3 Cutscene Tool

Executor-side GUI for capturing, decoding, merging, and exporting Moonlite V3 cutscenes.

## Load with `loadstring`

Run this one-line loader in Xeno:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/finalcircuitgame-crypto/MoonliteV3export/main/MoonliteTool.lua"))()
```

This downloads and executes the latest `MoonliteTool.lua` from the repository's `main` branch.

### Important: repository visibility

This repository is public, so the raw GitHub URL can be fetched without an account token.

To use that exact one-line loader, either:
- make the repository public; or
- publish the script through another HTTPS location that your executor can access.

Do **not** put a GitHub personal access token into the loader or a script shared with other people. Anyone who obtains the script could extract the token.

If you want to keep the repository private, open `MoonliteTool.lua` in your local copy and execute its contents through Xeno's editor instead.

## Requirements

- Xeno or another executor environment that supports `loadstring` and `game:HttpGet` for the loader method.
- Executor filesystem functions: `isfolder`, `makefolder`, `isfile`, `readfile`, and `writefile`.
- `saveinstance` for the model-export button.
- The game's Moonlite Container and Document modules at:

```text
ReplicatedStorage
└── Client
    └── Modules
        └── MoonliteV3
            ├── Container
            ├── Document
            └── Stream (only required for stream packages)
```

## What the tool does

1. Scans `ReplicatedStorage.Assets.CutScenes` for Moonlite `Scene` containers and classifies them as **Stream**, **Direct**, **Incomplete**, or **Invalid**.
2. Stream packages use `MoonliteStreamId`, `MoonliteStreamWindowCount`, and the game's `RF:RequestCutsceneChunk` RemoteFunction. The remote is resolved only when stream capture is requested.
3. Direct packages already contain a complete timeline document. The tool reads the document with `Container.Read`, validates it with `Document.Validate`, clones it, and re-encodes it with `Container.Create`. No stream metadata, window requests, packet imports, or boundary-key merge are needed.
4. Stream packets are saved locally under `MoonliteCapture/<PackageName>/`, decoded with `Stream.SceneFromPacket` and `Container.Read`, and verified with `Stream.AssertWindow`.
5. Stream windows are reassembled using the stream-aware merge algorithm described below.
6. Both modes create a fresh Moonlite `Scene` under `Workspace/<PackageName>_Reconstructed`.
7. The generated folder can be exported using [Universal Syn Save Instance](https://github.com/finalcircuitgame-crypto/UniversalSynSaveInstance). The engine is downloaded only when export is requested.

## GUI controls

- **Refresh** — rescans `ReplicatedStorage.Assets.CutScenes`.
- **Cutscene list** — selects a Stream, Direct, Incomplete, or Invalid package.
- **Local capture folder** — sets the root directory; defaults to `MoonliteCapture`.
- **Acquire + Decode + Merge** — for Stream packages, requests and merges the windows; for Direct packages, rebuilds the complete document immediately without stream calls.
- **Import Existing Capture** — imports previously saved Stream packets. It is hidden for Direct packages because they have no windows to import.
- **Export with Universal Syn Save Instance** — downloads `saveinstance.luau` from the linked repository on first use, then calls the returned `synsaveinstance(outputFolder)` function. Passing the generated Folder Instance directly makes it the export target; the rest of the DataModel is not selected.

## Direct versus Stream packages

A **Direct** package stores the complete animation document in its `Scene` container. The tool does not call `RF:RequestCutsceneChunk`; it validates the decoded document and uses `Container.Create` to generate a fresh container. This rebuilds the chunk layout for the output while preserving the document's tracks, keys, targets, cues, media, and other metadata.

A **Stream** package stores a manifest plus separately requested windows. It still requires the Stream module, valid stream attributes, and the existing packet acquisition/import pipeline.

An **Incomplete** package is shown in the list with its container error. When the metadata exposes `ChunkCount`, the diagnostic reports missing or empty numbered entries under `_MoonliteV3Data`. Re-encoding can repair the output container only after `Container.Read` succeeds. If a source chunk is genuinely absent (for example, chunk `1`), the tool cannot recreate its contents from the remaining chunks or from the manifest; it needs an authoritative copy of that chunk or of the original complete container.
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

The export button uses [Universal Syn Save Instance](https://github.com/finalcircuitgame-crypto/UniversalSynSaveInstance). Its engine is fetched lazily from `saveinstance.luau` and called with the generated folder Instance directly, which the library documents as the `Object` option for a model export. The exact exported filename, extension, and destination are determined by the library's options and executor filesystem implementation.

The project must retain the required attribution and license notices from Universal Syn Save Instance. Required credit string: `UniversalSynSaveInstance https://discord.gg/wx4ThpAsmw`. See the [USSI license](https://github.com/finalcircuitgame-crypto/UniversalSynSaveInstance/blob/main/LICENSE).

## Troubleshooting

**The GUI does not appear**
- Check the executor console for an error before the GUI is created.
- Confirm the Moonlite module paths exist.
- Confirm `ReplicatedStorage.Assets.CutScenes` exists.

**The cutscene list is empty**
- The script currently scans `ReplicatedStorage.Assets.CutScenes` only.
- A package must have a `Scene` StringValue containing a Moonlite V3 container. Direct packages do not need stream metadata or the Stream module.

**A window request fails**
- Check the returned status and packet data.
- Confirm the selected package has valid `MoonliteStreamId` and `MoonliteStreamWindowCount` attributes.
- Check whether the server expects a different request limit or retry interval.

**A direct Scene fails decoding**
- Check the reported missing or empty chunk indices under `_MoonliteV3Data`.
- A complete container can be rebuilt with `Container.Create`; a truly missing source chunk must be restored from an authoritative copy.

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
