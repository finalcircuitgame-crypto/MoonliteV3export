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

The loader does not require a GitHub personal access token. Do not put a personal access token into an executor script or share one with other people.

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
7. Direct mode automatically backs up the original serialized `Scene` header and every numbered `_MoonliteV3Data` chunk before rebuilding. The same backup can be started manually for any selected package, including incomplete containers.
8. The generated folder can be exported using [Universal Syn Save Instance](https://github.com/finalcircuitgame-crypto/UniversalSynSaveInstance). The engine is downloaded only when export is requested.

## GUI controls

- **Refresh** — rescans `ReplicatedStorage.Assets.CutScenes`.
- **Cutscene list** — selects a Stream, Direct, Incomplete, or Invalid package.
- **Local capture folder** — sets the root directory; defaults to `MoonliteCapture`.
- **Acquire + Decode + Merge** — for Stream packages, requests and merges the windows; for Direct packages, first backs up the original container, then rebuilds the complete document without stream calls.
- **Import Existing Capture** — imports previously saved Stream packets. It is hidden for Direct packages because they have no windows to import.
- **Backup Original Container** — writes the original `Scene.Value` header and each numbered `_MoonliteV3Data` StringValue to separate files. Every file is read back and compared with its source. A report and JSON manifest record chunk indices, sizes, missing entries, failed writes, and whether `Container.Read` plus `Document.Validate` succeeded. Incomplete packages can still produce a useful partial backup.
- **Export Rebuilt Model** — downloads `saveinstance.luau` from the linked repository on first use, then calls the returned `synsaveinstance(outputFolder)` function. Passing the generated Folder Instance directly makes it the export target; the rest of the DataModel is not selected.

## Direct versus Stream packages

A **Direct** package stores the complete animation document in its `Scene` container. The tool does not call `RF:RequestCutsceneChunk`; it validates the decoded document and uses `Container.Create` to generate a fresh container. This rebuilds the chunk layout for the output while preserving the document's tracks, keys, targets, cues, media, and other metadata.

A **Stream** package stores a manifest plus separately requested windows. It still requires the Stream module, valid stream attributes, and the existing packet acquisition/import pipeline.

An **Incomplete** package is shown in the list with its container error. When the metadata exposes `ChunkCount`, the diagnostic reports missing or empty numbered entries under `_MoonliteV3Data`. Re-encoding can repair the output container only after `Container.Read` succeeds. If a source chunk is genuinely absent (for example, chunk `1`), the tool cannot recreate its contents from the remaining chunks or from the manifest; it needs an authoritative copy of that chunk or of the original complete container.
## Local capture layout

Stream packet captures and original-container backups are stored under the same root.

Stream captures use this layout:

```text
MoonliteCapture/
└── NIGHT1TESTING/
    ├── COMPLETE.txt
    ├── window_001/
    │   ├── header.bin
    │   ├── info.txt
    │   └── value_0001.bin
    └── ...
```

Direct source backups use a unique folder per attempt:

```text
MoonliteCapture/
└── N3C2_STAGING_OriginalContainer_<timestamp>_<id>/
    ├── SceneHeader.txt
    ├── chunk_0001.txt
    ├── chunk_0002.txt
    ├── ...
    ├── manifest.json
    ├── REPORT.txt
    └── COMPLETE.txt  (or PARTIAL.txt)
```

The header and each numbered chunk are written separately—never concatenated into one giant console/clipboard string. Each write is read back and byte-for-byte compared with the source value. `COMPLETE.txt` is emitted only when all expected chunks were saved, the container can be read, and the decoded document passes validation. Otherwise the backup is marked `PARTIAL.txt`, and `REPORT.txt` lists the missing or failed entries.

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

**SaveInstance fails or Roblox crashes during export**
- The original container backup is created automatically during Direct reconstruction, before the generated Workspace model is created.
- Check `MoonliteCapture/<PackageName>_OriginalContainer_.../` for `COMPLETE.txt` and `REPORT.txt`. This backup is independent of USSI and can be used to rebuild the container even when the `.rbxm` export did not finish.
- For Stream packages or incomplete packages, use **Backup Original Container** before another export attempt.
- A completed raw-container backup is not itself an `.rbxm`; it preserves the source header and chunk strings for later reconstruction.

## Project files

- `MoonliteTool.lua` — standalone executor GUI and processing pipeline.
- `MERGE_LOGIC.md` — explanation of stream reconstruction.
- `default.project.json` — Rojo project manifest for the modular project layout.
