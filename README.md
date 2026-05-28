# intonaco

A **compile-time-first reactive systems substrate** for Nim. Sibling to [`coreyleavitt/fresco`](https://github.com/coreyleavitt/fresco) (terminal frontend) and the planned [`coreyleavitt/sinopia`](https://github.com/coreyleavitt/sinopia) (trace frontend).

## What this is

A reactive substrate where each binding declares its dependencies explicitly and heights compose at compile time:

```nim
import intonaco/reactive/binding

signals:
  count = 0
  title = ""

computed doubled, [count]:
  count * 2

computed label, [count, doubled, title]:
  title & ": " & $count & " (" & $doubled & ")"

effect [label]:
  paint(label)
```

Inside each body, the dep names are bound as their snapshot values (`count` is `int`, not `Signal[int]`). The walker rejects, at sem time, any reactive read in the body that isn't in the brackets — directly, transitively through helpers carrying the `ReactiveRead` effect tag, or through an opaque callee (`RootEffect` from method dispatch / async / FFI / indirect call).

Heights are composed from each dep's `{.height.}` pragma and baked onto the new binding for downstream composition. Under `-d:intonacoStrict` an unbaked dep is a hard compile error.

The runtime scheduler — a height-ordered glitch-free worklist — is **machine-checked** in Lean 4 (`proofs/Consistency.lean`, sorry-free, axiom-clean: scheduler correctness, confluence, glitch-freedom, height-ordered worklist correctness, plus the over-approximation soundness lemma whose precondition is satisfied *by construction* under the explicit-deps shape).

## Highlights

- **Signal / computed / effect** with explicit deps + compile-time height baking + sem-time walker safety net
- **`Dynamic[T]`** — type-quarantined escape to the runtime floor; cross-tier wall enforced by the walker (a static binding cannot read a `Dynamic[_]` without a compile error)
- **`each`** over `CollectionSignal[T]` — per-item bindings, lifecycle by scope discipline (insert spawns a scope, remove disposes the entire per-item reactive subgraph cleanly)
- **Collection algebra** — `derive` / `keep` / `fold` (linear operators with IVM proof obligation) + `scan` (delta-stream fold with explicit extra-dep bracket)
- **`mountWhen(boolSig): body`** — reactive conditional mount over `Signal[bool]`
- **OTP-flavored supervision** with strategies, lifecycle, restart windows, error policies, adopted task groups
- **Capability discharge** — `cap T`, `{.needs.}`, `supervisor:` macro, concept-based authority checking with type-level grant tokens
- **Journal-as-source-of-truth observability** with `rewindTo` / `resumeLive`, snapshots, causal-chain ancestors, persistent JSONL
- **Speculative scope** (optimistic-revert), animation primitives, collection signals with delta observers

## Status

Active. The C-shape binding direction (explicit deps + walker, replacing an earlier auto-tracking + classifier-inference path) is migrating in milestone #3 — see [`docs/rfc-c-shape-migration.md`](docs/rfc-c-shape-migration.md). The runtime scheduler, height carrier, scope/lifecycle machinery, journal, collection delta machinery, and the Lean proof are unchanged across the migration; the classifier and effect-purity oracle are deleted.

## Why this name

A *fresco* is a mural painted on wet plaster. *Intonaco* is the smooth top layer of plaster onto which the paint is applied — the substrate beneath what's visible. The metaphor mirrors the architecture: intonaco is the reactive substrate; fresco is the terminal painting laid atop it.

## Why split from fresco

Read [`fresco/docs/rfc-intonaco-fresco-split.md`](https://github.com/coreyleavitt/fresco/blob/main/docs/rfc-intonaco-fresco-split.md) for the full case. Short version: the substrate outgrew its "terminal-UI kernel" framing; future frontends (sinopia for trace observability, a hypothetical fresco-web) all target the substrate, varying only in what surface the paint lands on. Splitting the package boundary makes the architecture visible. Hard split is complete; both packages now live independently.

## License

Apache 2.0.
