# The decide/act seam

**Status**: canonical reference (M-γ.3, milestone #7 "Decide/act seam first-class")
**Companion to**: [`extension-protocol.md`](extension-protocol.md) (substrate-author surface), [`rfc-c-shape-migration.md`](rfc-c-shape-migration.md) (the consistency model the seam lives inside)
**Tracking issues**: coreyleavitt/intonaco#85 (relocation), #86 (cancellation + scope-affine), #87 (this doc)

This document defines intonaco's **decide/act seam** — the substrate's principled answer to "how does a reactive body invoke opaque, async, or I/O-shaped work without breaking the static-analysis discipline that makes the substrate compile-time-first?"

If you are writing a new substrate template that needs to react to a signal change *and* call into the outside world (spawn a task, write a journal line, issue an HTTP request, restart a child process), this is the doc that tells you the named, supported pattern.

## The structural tension

intonaco's defining property is that reactive bindings are statically analyzed (see [`rfc-c-shape-migration.md`](rfc-c-shape-migration.md) for the full story). A `computed name, [deps]: body` or `effect [deps]: body` runs the body through a walker that:

1. Verifies every reactive read in the body appears in `[deps]` (the `noUndeclaredSignals` pass).
2. Rejects any opaque callee — anything the walker cannot prove is reactive-free. The proof obligation is concrete: the callee must carry `{.forbids: [ReactiveRead, ReactiveWrite].}` or be marked otherwise inspectable.

The second rule is what makes the substrate sound. Without it, a body could call `someAsyncProc()` whose hidden implementation reads a signal that isn't in `[deps]`, and the height-ordered scheduler's glitch-free guarantee silently degrades.

But real reactive systems need to invoke opaque work. mountWhen spawns child tasks. A journal-bound effect writes log entries. A future HTTP-backed effect fires requests when a signal stabilizes. The walker correctly rejects all of these as bare calls inside an effect body, so the substrate has to provide a *structural* place where opaque work is permitted, and one place only.

That place is the decide/act seam.

## The three rejected alternatives

Before settling on the structural seam, the substrate considered three alternatives. Each was rejected on first principles.

### (A) Annotate-substrate-procs

> *Add `{.forbids: [ReactiveRead, ReactiveWrite].}` to every "safe" substrate proc, then let effect bodies call them freely.*

**Rejected.** The pragma is a *promise*, not a proof. Nim's effect system can verify it for direct reactive primitives (`set`, `peek`, `trackRead`) but cannot verify it transitively across chronos's async dispatch, FFI calls, or any closure that captures a Subscribable in its environment. Marking `spawnChild` as `forbids:` would be an unverified annotation; the walker would have to trust the substrate's word. The compile-time-first identity rules this out — we never accept "trust me" where a structural check is available.

### (B) Walker escape-pragma at the call site

> *Let consumers annotate `{.escapeWalker.}: opaqueCall()` inside an effect body. The walker skips the marked region.*

**Rejected.** It defeats the discipline. Once an escape pragma exists, every consumer who hits a walker rejection reaches for it instead of restructuring the work. The pragma encodes *what the consumer wants* (silence the error) rather than *what the consumer means* (defer until propagation settles). The walker's job is to surface the structural tension; an escape hatch hides it.

### (D) Reactive bodies as queues with explicit `effect.act:` blocks

> *Reshape the effect macro so the body is a record of separate `decide:` and `act:` sub-blocks. The macro stitches them together.*

**Rejected.** Multiplies the substrate surface. Every binding macro (`computed`, `effect`, `scan`, `derive`, `keep`, `fold`, hypothetical research-direction macros) would need a parallel act-block treatment. The mountWhen migration alone would have demanded a new macro variant. The seam should be *one* primitive, used compositionally — not a parallel grammar.

### Why (C) — the structural seam — won

(C) is structural, not syntactic. The substrate carves out exactly one lexically-distinguished position where opaque work is permitted: the closure body handed to `runAfterPropagation`. The walker's existing lambda-skip rule (lambda bodies execute in a separate frame, so reads inside them aren't reads of the binding's dependencies) handles the static analysis automatically — no new pragma, no new escape hatch, no new macro variant.

The seam is a *contract*, not a feature flag: bodies decide; closures act; the substrate guarantees ordering, cancellation, and lifecycle. New binding macros get it for free because they all compose with the same primitive.

## The contract

The decide/act seam is defined by three operational guarantees and one analytical guarantee.

```
┌────────────────────────── effect/computed body ──────────────────────────┐
│  reactive reads (declared in [deps])                                     │
│  pure computation                                                        │
│  runAfterPropagation(proc() {.closure.} =                                │
│    opaque work — IO, async dispatch, task spawn, journal writes          │
│  )                                                                       │
└──────────────────────────────────────────────────────────────────────────┘
       ▲ body runs under walker analysis        ▲ closure is a lambda;
       ▲ opaque calls here are rejected         ▲ walker skips its body
```

### Operational guarantees

1. **Quiescence before action.** The closure runs *after* the height-ordered worklist drains. By the time the action fires, every dependent in the current propagation frame has settled. The action observes a glitch-free snapshot.

2. **Interleaved drain with reactive work.** A closure that writes signals re-enters propagation. The substrate's interleave loop (in `primitives/scheduler.nim`) drains the reactive worklist to quiescence, then runs one batch of deferred actions, then re-drains the reactive worklist, until both empty. Consumers don't reason about batching; they reason about "after the graph settles."

3. **Scope-affine lifecycle (M-γ.2).** The handle returned by `runAfterPropagation` is bound to the `currentScope` at call time. Disposing the scope auto-cancels the pending action — no captured `disposed` flag, no consumer-side state machine. The `runAfterPropagationDetached` variant opts out for substrate-internal cases whose lifecycle is decoupled from any reactive scope.

### Analytical guarantee

4. **The walker skips lambda bodies.** This is the structural seam: closure bodies handed to `runAfterPropagation` are not walked. The closure can call anything. The substrate's soundness rests on `runAfterPropagation` being marked `{.forbids: [ReactiveRead, ReactiveWrite].}` itself (so the *call* survives walker analysis) and the closure being syntactically a lambda (so its *body* is not descended into).

This is why the seam works as a single primitive instead of a parallel grammar. The walker's existing rules — lambda-skip + forbids-pragma at the call site — compose to give exactly the right shape.

## Cancellation + scope-affine semantics (M-γ.2)

```nim
type DeferredHandle* = ref object   # opaque

proc runAfterPropagation*(action: DeferredAction): DeferredHandle
    {.discardable, gcsafe, raises: [],
      forbids: [ReactiveRead, ReactiveWrite].}
proc runAfterPropagationDetached*(action: DeferredAction): DeferredHandle
    {.discardable, gcsafe, raises: [],
      forbids: [ReactiveRead, ReactiveWrite].}
proc cancel*(h: DeferredHandle)
proc cancelled*(h: DeferredHandle): bool
```

- `runAfterPropagation` is **scope-affine**: the handle latches to `currentScope` at call time. Scope dispose before the deferred batch drains auto-cancels the pending action.
- `runAfterPropagationDetached` opts out of scope binding. Use when the lifecycle is genuinely decoupled (substrate-internal disposers, module-level metric flushes).
- `cancel` is idempotent and nil-tolerant.
- Cancellation is monotonic: once `cancelled`, always `cancelled`. There is no re-arm.
- Self-cancel from inside the action body is a no-op for the in-flight invocation (the closure has already started); the flag flips but doesn't un-fire anything. Deferred actions are fire-once.

### The effect-body-vs-registering-scope mismatch

A subtle and important fact: effect bodies fire from `notify`, which runs in the *writer's* scope context, not the effect's registering scope. If you call `runAfterPropagation` directly inside an effect body, the handle binds to whatever scope happened to be current at the write site — usually not what you want.

The substrate's answer is **explicit restoration at the seam**: substrate-template authors who want the handle to bind to the registering scope wrap the call in `withScope(registeringScope)`:

```nim
let registeringScope = currentScope          # captured at template expansion
effect [sig]:
  let value = sig
  withScope(registeringScope):                # restore at call time
    runAfterPropagation(proc() = ...)
```

This is the pattern mountWhen uses. The alternative — having effect bodies restore their registering scope automatically — was rejected because it would change the semantics of every reactive read inside the body (the effect's reads would attribute to the registering scope rather than the writer's task in the journal). The explicit wrap is the honest seam.

## Worked examples

### mountWhen (the canonical case)

`task/mount.nim` is the only substrate-shipped consumer of the seam. It mounts a child task while a boolean signal is true; cancels on false; re-mounts on the next true.

```nim
template mountWhen*(boolSig: Signal[bool], body: untyped): untyped =
  let mountWhenCtx = currentContext()
  let mountWhenScope = currentScope
  var currentMount: Mount = nil
  effect [boolSig]:
    let should = boolSig                       # decide: pure bool snapshot
    withScope(mountWhenScope):
      runAfterPropagation(proc() {.closure.} =
        withContext(mountWhenCtx):
          if should:
            if currentMount == nil or currentMount.future.finished:
              currentMount = body               # act: spawn the child
          else:
            if currentMount != nil and not currentMount.future.finished:
              currentMount.cancel()
              currentMount = nil)
  onCleanup proc() =
    if currentMount != nil and not currentMount.future.finished:
      currentMount.cancel()
      currentMount = nil
```

Notice the structure:

- **Decide**: `let should = boolSig` is a pure read of a declared dep. Walker accepts.
- **Act**: the closure body spawns or cancels a Mount. Walker doesn't see it (lambda body, deferred-execution context). The closure is allowed to do whatever it likes.
- **Scope-affine wrap**: `withScope(mountWhenScope)` ensures the handle binds to the template's expansion scope, so scope dispose auto-cancels pending mount/cancel decisions.
- **Cleanup**: separately cancels an *in-flight* Mount on scope dispose. The seam handles pending decisions; `onCleanup` handles work already in progress. These are different concerns.

### Hypothetical: `onChange(sig, sink)` — write a journal line on every settled value

A substrate template that journals every settled value of a signal:

```nim
template onChange*[T](sig: Signal[T], sink: Sink): untyped =
  let captureScope = currentScope
  effect [sig]:
    let value = sig                            # decide: snapshot
    withScope(captureScope):
      runAfterPropagation(proc() {.closure.} =
        sink.writeLine($value))                # act: opaque I/O
```

The closure body calls `sink.writeLine`, which is opaque (it does I/O). Inside an effect body it would be rejected by the walker. Inside the deferred closure, it's allowed — and the scope-affine binding means a torn-down owner won't see stale writes during the dispose chain.

### Hypothetical: `whenStable(sig, fetcher)` — fire an HTTP request when the graph settles

A template that issues an HTTP request whenever a signal value settles to a non-empty state:

```nim
template whenStable*[T](sig: Signal[T], fetcher: proc(v: T): Future[Response]):
    DeferredHandle =
  let captureScope = currentScope
  var pending: DeferredHandle = nil
  effect [sig]:
    let value = sig
    if value.nonempty:
      pending.cancel()                         # cancel an outstanding pending
      withScope(captureScope):
        pending = runAfterPropagation(proc() {.closure.} =
          asyncSpawn fetcher(value))           # act: async dispatch
  pending
```

Two structural points worth noting:

1. The template *can* hold the previous handle and cancel it before enqueueing a new one — this is how a substrate template implements debouncing or last-writer-wins semantics without consumer-side state.
2. `asyncSpawn` is async dispatch — the most aggressively opaque kind of call. Inside the closure, it's fine.

## For substrate-template authors writing new seams

When you reach for the decide/act seam:

- **Anything in the decide phase** must be walker-clean. Reactive reads must be in `[deps]`; opaque callees must carry `forbids:` or be inspected. If your decide phase needs an opaque call, you're describing a different abstraction — file an issue, don't try to widen the seam.
- **Anything in the act phase** can do what it likes. The closure body is not walked.
- **Always wrap the runAfterPropagation call in `withScope(registeringScope)`** if you want the handle bound to the template's expansion scope rather than the writer's. The mountWhen pattern is the reference.
- **Capture `currentContext()` if your act phase spawns tasks**. Tasks parent to whatever scope is current at the call site of `spawn`; without the context capture, the spawn would parent to the dispatcher's currentScope (often nil), and journal attribution + cleanup would attach to the wrong place.
- **Hold the returned handle if you want manual cancellation**. The discardable annotation means you can ignore it; you only need it for debouncing, manual cleanup, or testing.
- **Use `runAfterPropagationDetached` only when the lifecycle is genuinely decoupled** from any reactive scope. Detached deferred actions are easy to leak; prefer scope-affine.

### What NOT to put in the closure

- **Long-running synchronous work.** The closure runs on the dispatcher thread; blocking it stalls the entire substrate. If you need long work, `asyncSpawn` a task from inside the closure.
- **Anything that depends on `currentScope` or `currentContext` being preserved without explicit restoration.** The closure fires under the dispatcher's context, which is usually not what you want. Capture at template expansion, restore inside the closure.
- **Re-entrant calls into the same template.** If the closure's action writes a signal that re-fires the same template, you can build infinite loops. The substrate doesn't detect this — the closure body is opaque. Standard convergence discipline applies (see [`rfc-c-shape-migration.md`](rfc-c-shape-migration.md) on convergence concepts).

## Decision log

- **2026-05-21** (fresco M10 "direction C") — seam pattern selected over (A) annotate-substrate-procs, (B) walker-escape pragma, (D) explicit act-block grammar. Rationale: the seam is structural; the walker's lambda-skip rule already handles the analysis; one primitive composes with all binding macros.
- **2026-05-29** (M-γ.1, #85) — scheduler relocated from `primitives/subscribable.nim` to `primitives/scheduler.nim`. Scope of seam unchanged; module boundary now reflects the substrate concern.
- **2026-05-29** (M-γ.2, #86) — `DeferredHandle` added; scope-affine binding made first-class; mountWhen's captured `disposed` flag eliminated. Cancellation became part of the seam contract.
- **2026-05-29** (M-γ.3, #87) — this document. The seam is named and discoverable.
