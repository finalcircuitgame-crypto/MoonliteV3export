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
