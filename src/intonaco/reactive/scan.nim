## `scan` — fold a collection's delta stream into derived state.
##
## A `CollectionSignal[T]` has two faces: its *value* (`c.get()` — the whole
## seq; integration) and its *delta stream* (`deltas(c)` — the typed changes;
## differentiation). `scan` consumes the delta face as a first-class reactive
## node: it subscribes to the stream (a real graph edge, so the dependency on
## `c` is compile-time-visible and height-ordered), and folds each typed delta
## into an accumulator — O(1) per delta, no whole-seq re-read.
##
## This is the engine under fresco's differential collection bindings. The
## value/event duality is explicit: `deltas(c)` is `c`'s event face, at `c`'s
## height; a `scan` over it sits one height above, like any derived node.

{.experimental: "callOperator".}

import std/[macros, options]
import ./subscribable
import ./collection
import ./signal
import ./height
import ./classify

type
  DeltaStream*[T] = ref object of Subscribable
    ## `c`'s event face — carries the deltas pending for the current
    ## propagation. Height equals `c`'s, so a `scan` over it composes a
    ## normal `c.height + 1`.
    pending: seq[Delta[T]]

proc deltas*[T](c: CollectionSignal[T]): DeltaStream[T] =
  ## Obtain `c`'s delta stream. Each mutation pushes its typed delta onto the
  ## stream and schedules the stream's observers through the height-ordered
  ## scheduler.
  let s = DeltaStream[T]()
  s.height = Subscribable(c).height
  c.onDelta proc(d: Delta[T]) =
    s.pending.add d
    notify(Subscribable(s))
  s

proc foldDeltas*[T, S](s: DeltaStream[T], initial: S,
                 step: proc(acc: S, d: Delta[T]): S {.closure.},
                 fixedHeight = -1): Signal[S] =
  ## The runtime floor under the `scan` macro — value-constructed, unclassified
  ## (the step is an opaque closure). Folds the stream's deltas into derived
  ## state: `step(acc, delta)` runs once per delta, in height order; the result
  ## is exposed as a derived `Signal[S]`. Prefer the `scan` macro, which
  ## classifies the step and bakes a compile-time height.
  ##
  ## `fixedHeight >= 0` bakes the scheduling height (the `scan` macro passes the
  ## classified `max(collection, step-reads) + 1`), so the node fires after a
  ## higher-height signal its step reads — subscribe-time accumulation would only
  ## see the collection dependency and under-shoot, re-introducing a glitch.
  let outSig = signal(initial)
  var state = initial
  let comp = Computation(kind: ckEffect)
  if fixedHeight >= 0:
    comp.height = fixedHeight
    comp.heightFixed = true
    outSig.height = fixedHeight
  comp.run = proc() =
    if comp.disposed: return
    for d in s.pending:
      state = step(state, d)
    s.pending.setLen(0)   # consumed for this propagation
    outSig.set(state)
  subscribe(Subscribable(s), comp)
  outSig

macro scan*(name: untyped, coll: typed, initial: typed, step: typed): untyped =
  ## Declare a static, height-baked fold over a collection's delta stream — the
  ## blessed form (the floor is `foldDeltas`). The collection must carry a
  ## compile-time height (declare it via `collections:`), so the binding's
  ## dependency on it is compile-time-verified rather than a silent runtime
  ## escape. Bakes `{.height: h(coll)+1.}` onto `name` so downstream nodes
  ## compose through it.
  let ch = heightOf(coll)
  if ch.isNone:
    error("scan: `" & coll.repr & "` has no compile-time height — declare the " &
          "collection via `collections:` so its dependency can be scheduled " &
          "statically (or use the `foldDeltas` floor for a dynamic fold)", coll)
  # The scan depends on the collection AND on every signal the step reads.
  # Classify the step body to fold those reads into the height; an unresolvable
  # read can't be scheduled statically.
  let stepBody = if step.kind in {nnkLambda, nnkProcDef, nnkFuncDef}: step.body
                 else: step
  let cls = classify(stepBody)
  if cls.tier == tDynamic:
    error("scan: the step reads reactive state that can't be scheduled " &
          "statically (" & $cls.reason.kind & ") — restructure the read, or " &
          "use the `foldDeltas` floor", step)
  let h = max(ch.get + 1, cls.height)   # collection dep vs the step's read deps
  let ctor = newCall(bindSym"foldDeltas",
    newCall(bindSym"deltas", coll), initial, step,
    nnkExprEqExpr.newTree(ident"fixedHeight", newLit(h)))
  nnkLetSection.newTree(nnkIdentDefs.newTree(
    withHeight(name, h), newEmptyNode(), ctor))
