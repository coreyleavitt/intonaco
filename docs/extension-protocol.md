# intonaco extension protocol

**Status**: Canonical reference (M-α.5)
**Companion to**: `docs/rfc-c-shape-migration.md` (the substrate this protocol exposes), `docs/rfc-modal-tiers.md` (the modal framing that future-direction passes inherit), `fresco/docs/roadmap-compile-time-research.md` (the five research directions that consume this protocol)
**Worked example**: `examples/extensions/no_io_call.nim`

This document is the entry point for anyone extending intonaco's compile-time analysis platform — sinopia building a new frontend, a research-direction author landing one of the five flagship directions (refinement / substructural / transactions / guarded / consistency-follow-on), or anyone writing custom substrate templates on top of the existing primitives.

If you're a fresco app author writing `signals: x = 0; computed y, [x]: x * 2` — this isn't the document you want. Read `intonaco/docs/rfc-c-shape-migration.md` for the binding-shape semantics; this protocol is for substrate-author work.

## Table of contents

1. [The platform thesis](#the-platform-thesis)
2. [Stratification](#stratification)
3. [Writing a walker pass](#writing-a-walker-pass)
4. [The Diagnostic contract](#the-diagnostic-contract)
5. [Building new DSL macros: the substrate kit](#building-new-dsl-macros-the-substrate-kit)
6. [Worked example walkthrough](#worked-example-walkthrough)
7. [Determinism + extensibility rules](#determinism--extensibility-rules)
8. [Where to go next](#where-to-go-next)

## The platform thesis

intonaco's substrate is built around one operational claim: **the typed reactive AST is a compile-time analysis platform**. Every binding macro (`computed`, `effect`, `scan`, `derive`, `dynamic`, and any future macros built on the same platform) produces a typed AST that walks one tree, runs multiple analyses, and emits structured diagnostics through a shared contract.

Each future research direction — refinement types, substructural under re-execution, reactive transactions, guarded productivity — adds one or more analysis passes over that platform. They share the substrate; they don't fork it.

This protocol explains how to plug into the platform without forking.

## Stratification

The compile-time machinery lives in three layers under `intonaco/reactive/`:

```
reactive/
├── primitives/          ← runtime substrate (Signal, Computation, scheduler, ...)
├── analysis/            ← compile-time analysis platform — YOU EXTEND HERE
│   ├── pass.nim            (Finding, WalkContext, registerWalkPass, runAnalysis, analyze)
│   ├── passes_core.nim     (the three default passes shipped with the substrate)
│   ├── ast.nim             (rewriteDepRefs, depSymUnwrap, containsDepSym)
│   └── diagnostic.nim      (Severity, GlossaryTerm, Diagnostic, validate, group, render)
└── dsl/                 ← consumer-facing macros (built on the kit)
    ├── kit.nim             (substrate-template authoring kit)
    └── binding.nim, scan.nim, derive.nim, dynamic.nim, ...
```

Two aggregator entry points cover most consumers:

```nim
import intonaco/reactive        # consumer surface — for fresco apps
import intonaco/substrate       # substrate-author surface — for THIS document's audience
```

`intonaco/substrate` re-exports primitives + analysis + dsl + kit. Anything in this protocol is reachable from a single `import intonaco/substrate`.

## Writing a walker pass

A walker pass is a compile-time procedure that inspects every AST node of a binding body and returns zero or more `Finding`s (diagnostic drafts).

### Pass signature

```nim
proc myPass(node: NimNode, ctx: WalkContext): seq[Finding] {.nimcall.}
```

- `node`: the current AST node being visited
- `ctx`: `WalkContext{deps: seq[NimNode], body: NimNode}` — declared dep syms + the full body for cross-node analysis

### The Finding shape

```nim
type Finding* = object
  severity*: Severity                   ## sevError | sevNote | sevSilent
  rule*: GlossaryTerm                   ## the consequence vocabulary (exhaustive enum)
  subject*: SignalId                    ## empty string if no specific subject
  symptom*: string                      ## what's wrong — NO internal vocab
  fix*: string                          ## actionable; NO internal vocab
  site*: NimNode                        ## for Nim's error() location
  breaksPreconditionOf*: seq[SignalId]  ## subjects this finding breaks (group())
```

Each `Finding` corresponds 1-to-1 with a `Diagnostic`; the orchestrator fills in `id`, `pausedBy`, and translates `site: NimNode` → `SourceSite{file, line, col}`.

### Registration

A pass registers itself at module load time via a `static:` block:

```nim
static: registerWalkPass(myPass)
```

When any consumer of the analysis platform (binding macro, `analyze` call, etc.) runs in the same compilation, `myPass` is in its registry.

Registration is per-compilation. A test file that imports your pass module gets the pass; an unrelated test file in the same suite doesn't (because it didn't import your module). This is by design — it's exactly the Nim semantics you expect, no additional mechanism required.

### Descent control

By default the walker skips into `nnkLambda` / `nnkProcDef` / `nnkFuncDef` / `nnkDo` bodies. These represent **deferred execution context** — their reads run in a separate reactive frame (deferred callbacks, stored handlers, `runAfterPropagation` closures). The walker discipline is "all reactive reads from the IMMEDIATE body must be declared"; deferred bodies declare their own deps when they become bindings.

If your pass needs to descend into lambdas — for example, the guarded-productivity direction (#46) needs to follow recursion through lambda bodies — that's a hook to add when the direction lands. Don't add the hook speculatively.

## The Diagnostic contract

The platform doesn't emit raw error strings. Every `Finding` from a pass routes through `analysis/diagnostic.nim`'s contract before reaching the user:

1. **`validate(d)`** rejects symptoms/fixes that leak internal vocabulary — words like `height`, `scc`, `tier`, `worklist`, `fixpoint`, `monoid`, `semilattice`, `subscribable`, `computation`. A pass with leaky vocabulary is a checker bug; `analyze()` `doAssert`s it at CT.

2. **`group(diags)`** applies cascading pause. If a sevError finding has `breaksPreconditionOf: [X]` and another finding's subject is `X`, the second is paused (its `pausedBy` is set to the root's id). One level of pause from each root; transitive pause is deferred (intonaco #58).

3. **`surfaced(diags)`** returns only the diagnostics whose `pausedBy.isNone`. These are the diagnostics actually emitted.

4. **`render(d)`** assembles the user-facing string: `` `subject`: <glossary consequence> — <symptom>. Fix: <fix>``.

### Vocabulary discipline

The `GlossaryTerm` enum is the consequence vocabulary — phrases like *"this could read a half-updated value"* (gtRuntimeScheduled) or *"this value depends on itself"* (gtReactiveCycle). Internal proof / scheduler / type-theory terms are reserved for the expert/verbose channel; user-facing diagnostics use only the glossary.

When you write `symptom` and `fix`, you can describe things in natural English — **but you cannot use the internal-vocabulary tokens**. The substrate enforces this via `validate(d)`; failure is a checker bug, not a runtime issue.

### Picking a GlossaryTerm

For consistency-family violations (something can read a stale value, the dep graph is broken, etc.), use `gtRuntimeScheduled`. For refined-value violations, use `gtValueRule`. For substructural violations, `gtUsedMoreThanAllowed`. The exhaustive enum makes the menu visible; pick the consequence that matches your pass's concern.

If your research direction needs a new GlossaryTerm, you add it to `analysis/diagnostic.nim` and provide the corresponding consequence sentence in `glossary()`. The exhaustive case-statement makes this a compile error otherwise.

## Building new DSL macros: the substrate kit

The walker is what runs analysis on binding bodies. For new substrate templates — sinopia's `traced`, future modality-specific macros — you also need to orchestrate the macro-expansion side: extract dep syms, build shadow lets, rewrite-dep-refs in the body, compose heights, emit the runtime primitive call, bake `{.height.}` pragmas.

`reactive/dsl/kit.nim` provides this orchestration. A new substrate-template family is ~7 lines:

```nim
import intonaco/substrate

# A hypothetical `traced name, [deps]: body` — same as computed but emits
# a journal event each fire. Pretend `tracedC` is a runtime primitive you
# defined elsewhere.

macro tracedInner(name: untyped, deps: typed, body: untyped, origDeps: untyped): untyped =
  compileBindingInner(name, deps, body, origDeps,
                      bindSym"tracedC", ekComputedShape, "traced")

macro traced*(name, deps, body): untyped =
  wrapDepsForInner(bindSym"tracedInner", name, deps, body)
```

For specialized templates that don't fit the computed/effect shape (scan's height-plus-one policy, derive's no-deps shape, future modality-specific macros), the kit also exposes lower-level helpers: `extractDepSyms`, `buildShadowLets`, `rewriteAndAnalyze`. See `reactive/dsl/scan.nim` for a worked example using just the helpers.

## Worked example walkthrough

`examples/extensions/no_io_call.nim` is the canonical end-to-end example. It registers `noIOCallPass` — a pass that flags calls to procs carrying any `IOEffect`-family tag.

The interesting parts:

```nim
proc noIOCallPass*(node: NimNode, ctx: WalkContext): seq[Finding] {.nimcall.} =
  if node.kind notin {nnkCall, nnkCommand}: return
  if node.len < 1 or node[0].kind != nnkSym: return
  let callee = node[0]
  for tag in getTagsList(callee):
    if tag.repr.endsWith("IOEffect"):
      result.add Finding(
        severity: sevError,
        rule: gtRuntimeScheduled,
        subject: SignalId(callee.repr),
        symptom: "the call performs I/O — binding bodies should remain pure",
        fix: "move the I/O out of the binding body, or use the deferred-action " &
             "seam (`runAfterPropagation`) to host opaque work post-settle",
        site: node)
      return

static: registerWalkPass(noIOCallPass)
```

What this demonstrates:

- **Early returns for non-applicable nodes** — the walker invokes every pass at every node, so passes need to filter cheaply.
- **Tag-based callee inspection** via `getTagsList` — the same pattern `passes_core.noOpaqueCalleePass` uses, but for a different tag. The platform's tag-inspection plumbing is uniform.
- **Suffix-match for tag families** — `endsWith("IOEffect")` catches `IOEffect`, `WriteIOEffect`, `ReadIOEffect`, etc. uniformly. Effect tags don't carry hierarchy at the tag-name level.
- **Vocabulary discipline** in `symptom`/`fix` — the substrate's `validate` will assert otherwise. Common gotchas: "computation" and "subscribable" are internal vocab; phrase user-facing in terms of "binding," "call," "value."
- **`subject`** carries the callee's name so the rendered error names what's wrong.
- **The `static:` registration** at module bottom — runs at compile time when this module is imported.

To use the pass in your own code: `import intonaco/examples/extensions/no_io_call`. Every `computed`/`effect` in the same compilation unit gets the I/O check.

A test exercising the pass lives at `tests/test_extension_protocol_example.nim`.

## Determinism + extensibility rules

The substrate enforces several rules to keep the platform stable as multiple directions ship in parallel:

### Pass determinism

- **Passes MUST be pure compile-time**. No mutation of Nim's tag state, no I/O, no caching in `var` between invocations.
- **Passes MUST return the same `Finding` set for the same `(node, ctx)` input**. Non-determinism makes diagnostics unstable across compilations.
- **Passes MUST own a `GlossaryTerm`**. If your concern doesn't fit any existing term, add a new one to `analysis/diagnostic.nim` with its consequence sentence.
- **Passes MUST phrase user-facing strings without internal vocabulary**. `validate` enforces.

### Registration ordering

- **Cross-module registration order is module-import order**. If module A registers pass P, and module B registers pass Q, then a compilation that imports A then B sees `registry = [P, Q]`.
- **Pass ordering matters for cascading-pause grouping**. If pass A produces a sevError root and pass B produces a sevNote on the broken subject, the order they fire affects whose id is assigned first. For correct cascading, register more-fundamental passes first.

### Adding new GlossaryTerms

When a research direction needs a new consequence term:

1. Add the term to the `GlossaryTerm` enum in `analysis/diagnostic.nim`.
2. Add the consequence sentence in the `glossary()` proc's exhaustive case.
3. Update the existing `internalTerms` list if your direction needs new internal-vocabulary tokens (e.g., guarded productivity might add "fixpoint" beyond the existing list — but check before adding; many directions can share internal vocab).
4. Land your pass.

### What NOT to do

- **Do NOT bypass the substrate kit** to roll your own dep extraction / shadow injection / rewrite logic in a new substrate template. The kit's helpers handle subtle cases (template-substituted typed syms, deeply-nested wrappers from Subscribable conversion) that take real effort to get right. If you find the kit doesn't cover your case, **file an issue extending the kit** rather than working around it.
- **Do NOT emit Nim `error()` / `warning()` directly from a pass**. Always go through the `Finding` API; the orchestrator routes through the contract.
- **Do NOT cache findings across compilations** via a `{.global.}` var or similar. CT state should be ephemeral within one compile.

## Where to go next

For the research-direction author landing one of the five flagship directions, the next step depends on the direction:

- **Consistency (#44)** is already in place; new follow-ons (#57 descend-and-collect, #58 transitive grouping) extend the analysis platform.
- **Refinement (#4)** writes a pass that walks each `signal.set` site and discharges its refinement predicate. Uses `ctx.body` to find write sites. Adds `gtValueRule` or a refinement-specific GlossaryTerm.
- **Substructural (#3)** writes a pass that counts consumption of linear/affine/bounded caps via the same walker. The hard question is per-execution vs per-lifetime semantics — see the rfc.
- **Guarded productivity (#46)** needs the descend-into-lambdas hook (not yet shipped). Will require extending the analysis platform.
- **Transactions (#45)** writes both a pass (transaction scope discharge) and a new substrate template (transactional `computed` variant via the kit).

For sinopia building the trace frontend, the kit + analysis pattern is what you ship `traceSignal` and `traceTransition` on top of. The kit handles the macro orchestration; you provide the runtime primitives that journal trace events.

The companion documents:

- `docs/rfc-c-shape-migration.md` — the substrate this protocol exposes
- `docs/rfc-modal-tiers.md` — the modal framing your direction will inherit
- `fresco/docs/roadmap-compile-time-research.md` — the five directions' RFCs
- `fresco/docs/rfc-consistency-model.md` — the consistency direction (the lead) for reference

Land your direction as an extension, not a fork. The platform is sized for it.
