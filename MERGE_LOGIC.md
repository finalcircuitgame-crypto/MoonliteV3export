# Why this merge is correct for the supplied Moonlite stream format

`Stream.Split()` stores a stream manifest with the common timeline metadata and track schema. Non-Action track key arrays are emptied in the manifest. Action keys remain on the manifest. Cues and Media are retained by the manifest while the stream-window documents clear them.

Each window uses the original document frame coordinate system. The `windowKeys` helper uses a lower bound for the window start and includes one preceding key as interpolation/context. Therefore adjacent windows can contain the same frame key. `Stream.AssertWindow` checks name, profile, frame rate, total frame count, track count, and track order/IDs.

The reconstruction clones the manifest; for every non-Action track it gathers the keys from all matching window tracks, deduplicates records that have the same Frame and identical contents, sorts by Frame, and retains manifest Action keys. A differing key at an already-used frame is treated as a hard conflict. It removes `Metadata.Stream`, then calls `Document.Validate` on the complete result.

`Document.Merge()` is intentionally not used. Its purpose is to merge separately-bound animations with target and binding remapping, not to stitch slices of the same original stream.

## Direct (non-stream) documents

A non-stream package has no `Metadata.Stream` layout and already stores the complete timeline in its `Scene` container. It does not need `Stream.Layout`, `Stream.Split`, `RequestCutsceneChunk`, or a window merge.

The direct path is:

1. Read the existing container with `Container.Read`.
2. Validate the full document with `Document.Validate`.
3. Clone it with `Document.Clone`.
4. Serialize a new container with `Container.Create`.
5. Parent the new `Scene` under `Workspace/<PackageName>_Reconstructed`.

This reserializes the complete document and generates a fresh `_MoonliteV3Data` chunk layout. It can normalize/rebuild the output container, but it cannot recover source bytes when a required source chunk is already missing. In that case the tool reports the missing numbered chunk so it can be restored from an authoritative copy.

## Original container backup and crash recovery

Rebuilding a Direct document creates a new Workspace container, but exporting that Workspace folder with a separate SaveInstance implementation can still fail independently (for example, if the client runs out of memory). The tool therefore preserves the original source container first.

The backup operation writes:

- SceneHeader.txt: the exact original Scene.Value header and metadata string.
- chunk_0001.txt, chunk_0002.txt, etc.: each original numbered _MoonliteV3Data StringValue, saved separately and unchanged.
- manifest.json: package identity, source metadata, expected/found/saved chunk counts, file names, character counts, and validation results.
- REPORT.txt: a readable summary of the backup, including missing, invalid, and failed chunks.
- COMPLETE.txt only when every expected chunk was saved and read back exactly, Container.Read succeeded, and Document.Validate passed. Otherwise the folder receives PARTIAL.txt.

Each chunk is written and read back independently. The tool does not join the payload into a console string or clipboard-sized value. In Direct mode this backup is attempted automatically before Container.Create generates the Workspace copy; the manual "Backup Original Container" action is also available for Stream, Incomplete, and Invalid entries to preserve whatever source data remains.

The raw backup is not an .rbxm file. It is a durable copy of the original serialized container inputs that can be decoded or rebuilt later even when a separate SaveInstance export crashes. A partial backup preserves only the chunks actually present; missing source bytes cannot be synthesized from the remaining chunks.
