# intonaco

**Status**: placeholder. The package's source code currently lives in [`coreyleavitt/fresco`](https://github.com/coreyleavitt/fresco) and migrates here during the structural split described in [`fresco/docs/rfc-intonaco-fresco-split.md`](https://github.com/coreyleavitt/fresco/blob/main/docs/rfc-intonaco-fresco-split.md).

## What this will be

A compile-time-first reactive systems library for Nim:

- Fine-grained reactive primitives (signal / computed / effect / scope) on a chronos contextvar substrate, surviving every `await`
- OTP-flavored supervision with strategies, lifecycle, restart windows, error policies, adopted task groups
- Capability discharge — `cap T`, `{.needs.}`, `supervisor:` macro, concept-based authority checking with type-level grant tokens
- Journal-as-source-of-truth observability with `rewindTo` / `resumeLive`, snapshots, causal-chain ancestors, persistent JSONL
- Multi-source `receive:` with cancel-safe race-then-cancel cleanup
- Static dependency extraction via `tracked:` — compile-time reactive graph
- Speculative scope (optimistic-revert), animation primitives, collection signals with delta observers

The terminal-rendering frontend that today ships in `fresco` will continue to live in `fresco`, depending on `intonaco`.

## Why this name

A *fresco* is a mural painted on wet plaster. *Intonaco* is the smooth top layer of plaster onto which the paint is applied — the substrate beneath what's visible. The metaphor mirrors the architecture: intonaco is the reactive runtime; fresco is the terminal painting laid atop it.

## Why split

Read [`rfc-intonaco-fresco-split.md`](https://github.com/coreyleavitt/fresco/blob/main/docs/rfc-intonaco-fresco-split.md) for the full case. Short version: the substrate has outgrown its "terminal-UI kernel" framing; future frontends (headless, web, bot, sidecar) all target the substrate, varying only in what surface the paint lands on; splitting the package boundary makes the architecture visible.

## Status

This repo is empty at the time of writing. Watch the fresco split milestone for migration progress.
