# Moonlite V3 Cutscene Tool

A GUI for processing **already-captured** Moonlite V3 stream windows. It discovers stream packages dynamically, reads packet folders from the local filesystem, decodes every window, reconstructs the complete document using Moonlite's stream semantics, places the rebuilt Scene in Workspace, and offers a SaveInstance export button.

> This tool does not call `RF:RequestCutsceneChunk` or any other game RemoteFunction. It starts from capture files that already exist on disk.

## Game module locations

The script expects your existing modules at:

```lua
ReplicatedStorage.Client.Modules.MoonliteV3
    Container
    Document
    Stream
```

It searches both `ReplicatedStorage.Assets.CutScenes` and direct children of `Workspace` for packages containing a `Scene` StringValue with a valid Moonlite stream manifest.

## Local capture layout

Default capture root: `MoonliteCapture`. For a package named `NIGHT1TESTING`:

```text
MoonliteCapture/
└── NIGHT1TESTING/
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

It reads `Values=<number>` from each `info.txt`, matching the loader you supplied.

## Install

Use the Rojo manifest `default.project.json`, or manually place:

- `src/MoonliteLocalCapture.lua` as `ReplicatedStorage.MoonliteCutsceneTool.MoonliteLocalCapture` (ModuleScript)
- `src/MoonliteStreamMerger.lua` as `ReplicatedStorage.MoonliteCutsceneTool.MoonliteStreamMerger` (ModuleScript)
- `src/Main.client.lua` as `StarterPlayer.StarterPlayerScripts.MoonliteCutsceneTool` (LocalScript)

Keep your existing Moonlite modules at `ReplicatedStorage.Client.Modules.MoonliteV3`.

The local filesystem functions required are `isfolder`, `isfile`, and `readfile`.

## Merge algorithm

This is based on the actual `Stream.lua` and `Document.lua` you supplied:

1. Decode the selected package's `Scene` as the stream manifest.
2. Use `Stream.Layout(manifest)` for the expected window count and frame width.
3. Rebuild each packet's `Scene` using `Stream.SceneFromPacket`, decode it with `Container.Read`, and verify it with `Stream.AssertWindow`.
4. Clone the manifest, preserving targets, cues, media, metadata and Action-track keys.
5. For each non-Action track, gather keys from every window, deduplicate identical records by absolute `Frame`, and sort them.
6. Remove `Metadata.Stream`, validate with `Document.Validate`, then serialize with `Container.Create`.

`Stream.Split()` keeps absolute frame numbers and includes a preceding context key in later windows. Identical frame duplicates at boundaries are expected. Conflicting values for the same track/frame abort the merge instead of silently choosing one. `Document.Merge()` is not the right API here: it composes separate animation bindings, while stream windows are slices of the same bindings.

## Output

A successful result appears under:

```text
Workspace
└── <PackageName>_Reconstructed
    └── Scene
        └── _MoonliteV3Data
```

The export button calls `saveinstance({ Object = outputFolder })`. The actual file name, extension, and destination depend on the SaveInstance implementation/settings in the executor.

## Scope

- Processes local capture folders only; it does not acquire new windows from a live server.
- The selected package must still have its original manifest `Scene` available.
- Every window described by `Stream.Layout` must be present locally.
