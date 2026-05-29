# intonaco

intonaco is the **compile-time-first reactive substrate** for Nim. It's the platform that fresco (the canonical terminal-frontend consumer) and sinopia (planned trace frontend) build on. This file is the discovery entry point for anyone working in the repo.

## Where to read first

| You are... | Start here |
|---|---|
| Extending the substrate (writing a new walker pass, adding a research direction, building a sinopia-style frontend) | [`docs/extension-protocol.md`](docs/extension-protocol.md) — the canonical M-α platform reference |
| Understanding the C-shape design (why explicit `[deps]` brackets, why the walker exists at all) | [`docs/rfc-c-shape-migration.md`](docs/rfc-c-shape-migration.md) |
| Looking at the modal framing of the static/dynamic tier split | [`docs/rfc-modal-tiers.md`](docs/rfc-modal-tiers.md) |
| Looking at the five-direction research roadmap | [`fresco/docs/roadmap-compile-time-research.md`](../fresco/docs/roadmap-compile-time-research.md) |
| Looking for general conventions / commit style / non-negotiables | [`fresco/AGENTS.md`](../fresco/AGENTS.md) + [`fresco/CLAUDE.md`](../fresco/CLAUDE.md) |
| Looking at the Lean proof | [`proofs/Consistency.lean`](proofs/Consistency.lean) (build via `proofs/Containerfile` + `leanbox` container; see [`reference_mechanized_proof`](https://github.com/coreyleavitt/fresco) memory) |

## The relationship to fresco

fresco currently owns the project-level conventions (`fresco/CLAUDE.md`, `fresco/AGENTS.md`, `fresco/DESIGN.md`) for historical reasons — these documents date back to before the hard split where intonaco moved to its own repo. Whether intonaco should grow its own full set of these documents is **an open question** (deferred since the M4 atomic merge); for now this file is the minimal pointer.

For general project-wide conventions (commit style, build/test workflow, non-negotiables like termios restore and chronos-only async), the fresco docs are authoritative for both repos.

## intonaco-specific non-negotiables

The substrate-level rules that are intonaco's own (independent of fresco's frontend concerns):

- **Compile-time-first**: when a property can be enforced at compile time, the substrate prefers compile-time over runtime. See `fresco/docs/rfc-intonaco-fresco-split.md` Thesis 1.
- **Research drives engineering**: every substrate-level RFC ships three deliverables — theoretical contribution, engineering primitives, research artifact. See the same RFC Thesis 2.
- **Five-anti-pattern discipline** (from the C-shape migration): no shims, no soft-deprecation, no flags, no translation layers, no "just in case" preservation. Applies to all platform refactors.
- **Extension over fork**: future research directions extend the analysis platform via the M-α extension protocol (registered walker passes, kit-built DSL macros), not by forking the substrate. See `docs/extension-protocol.md`.

## Where work happens

- **Substrate primitives + analysis + DSL**: `src/intonaco/reactive/`
- **Async task system**: `src/intonaco/task/`
- **Journal + persistence**: `src/intonaco/journal/`
- **Lean proof**: `proofs/`
- **Worked extension examples**: `examples/extensions/`
- **Tests**: `tests/` (run via `nimble test` in the dev Docker container — see `fresco/AGENTS.md` for the wrapper)

## Active milestones

See the GitHub milestones page for current work. As of this writing the active threads are:

- **Milestone #1** (compile-time research substrate) — five flagship research directions + supporting work
- **Milestone #4** (scheduler refinement-conformance harness) — #68-73, fidelity work
- **Milestone #5** (compile-time analysis platform) — M-α series, the platform extension surface (#79-83 — this is the work `docs/extension-protocol.md` documents the result of)
- **Milestones #6-8** (signal surface discipline / decide-act seam / collection algebra unification) — design-spec milestones following M-α
