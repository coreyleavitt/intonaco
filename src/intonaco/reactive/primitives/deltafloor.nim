## The collection-dataflow floor — INTERNAL plumbing, not part of the blessed
## surface.
##
## These procs build a reactive node from a collection's delta stream by VALUE,
## with no compile-time classification: each forms a real graph edge
## (`subscribe`) and fires an opaque handler. They are the substrate the
## classified collection macros stand on:
##   - `onDelta` registers a height-scheduled delta sink (the one cross-module
##     primitive — `mapped`/`filtered`/`folded`/`deltas` all stand on it),
##   - `derive`/`keep`/`fold` (see `reactive/derive`) emit `mapped`/`filtered`/
##     `folded` via `bindSym` so consumers get classification + a baked height,
##   - `scan` (see `reactive/scan`) emits `foldDeltas` over `deltas` the same way.
##
## Consumers should NOT import this module. There is no compile-time scheduling
## here — reach for the `derive`/`keep`/`fold`/`scan` macros instead. It is
## `*`-exported only so those macros' `bindSym` and deliberate consumers (e.g.
## fresco's `bindCollection`, whose windowed view is legitimately dynamic) can
## name it; the explicit `import intonaco/reactive/primitives/deltafloor` is the greppable
## "I'm bypassing the classifier" act, mirroring `reactive/runtime` for signals.


proc onDelta[T](c: ReactiveCollection[T], handler: DeltaHandler[T]) =
  ## Register `handler` to receive every delta — height-scheduled. The handler
  ## fires through the worklist at the consumer's height (`c.height + 1`), after
  ## every lower-height dependency of the same propagation has settled, NOT
  ## eagerly inside the mutation. Lifetime-bound to the current scope.
  let dc = DeltaConsumer[T](comp: Computation(kind: ckEffect))
  dc.comp.run = proc() =
    # `swap` (move, not copy) the pending buffer out — a plain `let batch =
    # dc.pending` COPY corrupts a recursive `Delta` variant (`dkRollback`'s
    # `rollbackOps: seq[Delta]`) under ORC. Snapshot-then-drain so a reentrant
    # mutation's deltas land in the fresh `dc.pending` for the next fire.
    var batch: seq[Delta[T]]
    swap(batch, dc.pending)
    for d in batch:
      try: handler(d)
      except Exception: discard
        # A faulty delta handler must not break siblings or the writing task.
  subscribe(Subscribable(c), dc.comp)   # in c.observers, height = c.height + 1
  c.deltaConsumers.add dc
  let captured = c
  let cdc = dc
  onCleanup proc() =
    cdc.comp.disposed = true
    let idx = captured.deltaConsumers.find(cdc)
    if idx >= 0: captured.deltaConsumers.del idx
    unsubscribeAll(cdc.comp)

# --- Linear transform floors (under derive/keep/fold) ---------------------

proc mapDelta[T, U](d: Delta[T], f: proc(x: T): U {.closure.}): Delta[U] =
  ## Map a source delta to the corresponding delta on the mapped view —
  ## applying `f` only to the element(s) the delta carries. `dkRollback` maps
  ## its inverse ops recursively. This is the per-`DeltaKind` correspondence the
  ## IVM-equivalence lemma rests on.
  case d.kind
  of dkInsert:  Delta[U](kind: dkInsert, insertIdx: d.insertIdx, insertVal: f(d.insertVal))
  of dkRemove:  Delta[U](kind: dkRemove, removeIdx: d.removeIdx)
  of dkUpdate:  Delta[U](kind: dkUpdate, updateIdx: d.updateIdx, updateVal: f(d.updateVal))
  of dkClear:   Delta[U](kind: dkClear)
  of dkReplace: Delta[U](kind: dkReplace, replaceVal: d.replaceVal.map(f))
  of dkRollback:
    # Unreachable: `mapped` recomputes the view from the (already-reverted)
    # source on rollback — that recompute IS the oracle value — and never routes
    # a rollback through `mapDelta`. The 5 forward kinds above map incrementally
    # (the linear IVM rule); rollback is the one structural case handled by
    # recompute, so there's no inverse-mapping path to get subtly wrong.
    raise newException(Defect, "mapDelta: dkRollback is handled by recompute, not mapped")

template mappedWiring[T, U](c: ReactiveCollection[T],
                            f: proc(x: T): U {.closure.},
                            d: ReactiveCollection[U]) =
  ## Shared delta-wiring for `mapped` (□) and `mappedDynamic` (◇). Both
  ## flavors observe `c`'s deltas the same way; only the output type
  ## and height-composition differ.
  c.onDelta proc(delta: Delta[T]) =
    if delta.kind == dkRollback:
      # A structural revert: recompute the view from the (already rolled-back)
      # source and forward it as one replace. Mapping the inverse ops onto the
      # view would have to mirror the source's reverse-application exactly;
      # recompute-from-source is the simpler, provably-equivalent path.
      pushDelta(d, Delta[U](kind: dkReplace, replaceVal: c.get().map(f)))
    else:
      pushDelta(d, mapDelta(delta, f))   # mapped delta: apply + emit to d's consumers

proc mapped[T, U](c: ReactiveCollection[T], f: proc(x: T): U {.closure.},
                   fixedHeight = -1): ReactiveCollection[U] =
  ## The static (□-modality) floor under the `derive` macro. `value ===
  ## c.map(f)`, maintained incrementally. `fixedHeight >= 0` bakes the
  ## scheduling height (set by the macro from compile-time height
  ## composition).
  let h = if fixedHeight >= 0: fixedHeight else: Subscribable(c).height + 1
  let d = newReactive[U](c.get().map(f), height = h)
  mappedWiring(c, f, d)
  d

proc mappedDynamic[T, U](c: ReactiveCollection[T],
                          f: proc(x: T): U {.closure.}):
    DynamicCollection[U] =
  ## The dynamic (◇-modality) floor under the `derive` macro: same delta
  ## semantics as `mapped`, but the output carries `DynamicCollection`
  ## modality and uses runtime-height composition only. Used when the
  ## source is itself a `DynamicCollection` — the macro dispatches.
  let d = newDynamicReactive[U](c.get().map(f),
                                height = Subscribable(c).height + 1)
  mappedWiring(c, f, ReactiveCollection[U](d))
  d

proc filteredInitial[T](c: ReactiveCollection[T],
                        p: proc(x: T): bool {.closure.}):
                       tuple[initial: seq[T], kept: seq[bool]] =
  let src = c.get()
  result.kept = newSeq[bool](src.len)
  for i in 0 ..< src.len:
    result.kept[i] = p(src[i])
    if result.kept[i]: result.initial.add src[i]

proc filteredWiring[T](c: ReactiveCollection[T],
                       p: proc(x: T): bool {.closure.},
                       d: ReactiveCollection[T],
                       kept: ref seq[bool]) =
  ## Shared delta-wiring for `filtered` (□) and `filteredDynamic` (◇).
  ## `kept` is the source→view kept-mask, held through a `ref` so the
  ## delta-handler closure can mutate it across invocations.
  proc rank(i: int): int =
    for j in 0 ..< i:
      if kept[][j]: inc result
  proc recompute() =
    let s = c.get()
    kept[] = newSeq[bool](s.len)
    var fv: seq[T]
    for i in 0 ..< s.len:
      kept[][i] = p(s[i])
      if kept[][i]: fv.add s[i]
    pushDelta(d, Delta[T](kind: dkReplace, replaceVal: fv))
  c.onDelta proc(delta: Delta[T]) =
    case delta.kind
    of dkInsert:
      let r = rank(delta.insertIdx)
      let k = p(delta.insertVal)
      kept[].insert(k, delta.insertIdx)
      if k: pushDelta(d, Delta[T](kind: dkInsert, insertIdx: r, insertVal: delta.insertVal))
    of dkRemove:
      let r = rank(delta.removeIdx)
      let was = kept[][delta.removeIdx]
      kept[].delete(delta.removeIdx)
      if was: pushDelta(d, Delta[T](kind: dkRemove, removeIdx: r))
    of dkUpdate:
      let r = rank(delta.updateIdx)
      let oldK = kept[][delta.updateIdx]
      let newK = p(delta.updateVal)
      kept[][delta.updateIdx] = newK
      if oldK and newK:
        pushDelta(d, Delta[T](kind: dkUpdate, updateIdx: r, updateVal: delta.updateVal))
      elif oldK and not newK:
        pushDelta(d, Delta[T](kind: dkRemove, removeIdx: r))
      elif (not oldK) and newK:
        pushDelta(d, Delta[T](kind: dkInsert, insertIdx: r, insertVal: delta.updateVal))
      # else: stays filtered out — no view delta
    of dkClear:
      kept[].setLen(0)
      pushDelta(d, Delta[T](kind: dkClear))
    of dkReplace:
      kept[] = newSeq[bool](delta.replaceVal.len)
      var fv: seq[T]
      for i in 0 ..< delta.replaceVal.len:
        kept[][i] = p(delta.replaceVal[i])
        if kept[][i]: fv.add delta.replaceVal[i]
      pushDelta(d, Delta[T](kind: dkReplace, replaceVal: fv))
    of dkRollback: recompute()   # recompute from the reverted source (the oracle)

proc filtered[T](c: ReactiveCollection[T], p: proc(x: T): bool {.closure.},
                  fixedHeight = -1): ReactiveCollection[T] =
  ## The static (□-modality) floor under the `keep` macro. `value ===
  ## c.filter(p)`, maintained incrementally via a kept-mask + rank.
  let (initial, kept) = filteredInitial(c, p)
  let keptRef = new(seq[bool]); keptRef[] = kept
  let h = if fixedHeight >= 0: fixedHeight else: Subscribable(c).height + 1
  let d = newReactive[T](initial, height = h)
  filteredWiring(c, p, d, keptRef)
  d

proc filteredDynamic[T](c: ReactiveCollection[T],
                         p: proc(x: T): bool {.closure.}):
    DynamicCollection[T] =
  ## The dynamic (◇-modality) floor under the `keep` macro. Same
  ## incremental semantics as `filtered`, modality-typed output.
  let (initial, kept) = filteredInitial(c, p)
  let keptRef = new(seq[bool]); keptRef[] = kept
  let d = newDynamicReactive[T](initial, height = Subscribable(c).height + 1)
  filteredWiring(c, p, ReactiveCollection[T](d), keptRef)
  d

proc folded[T, M: CommutativeGroup](c: ReactiveCollection[T],
    f: proc(x: T): M {.closure.}, fixedHeight = -1): Signal[M] =
  ## The runtime floor under the `fold` macro — collection→scalar. Maintains
  ## `acc = ⊕ f(x)` over a commutative GROUP: the inverse makes remove/update
  ## O(1) (`merge(acc, invert(m))`), where the group laws (assoc/comm/inverse)
  ## are exactly what make the incremental aggregate equal the wholesale fold.
  ## `contributions[i]` holds `f(source[i])`, so a remove/update can undo the
  ## departed element's contribution without its value (the delta carries only
  ## an index). `f` must be pure (enforced by the macro).
  mixin merge, unit, invert
  var contributions: seq[M]
  var acc = unit(M)
  for x in c.get():
    let m = f(x)
    contributions.add m
    acc = merge(acc, m)
  let outSig = signalC(acc)
  if fixedHeight >= 0: outSig.height = fixedHeight
  c.onDelta proc(delta: Delta[T]) =
    case delta.kind
    of dkInsert:
      let m = f(delta.insertVal)
      contributions.insert(m, delta.insertIdx)
      acc = merge(acc, m)
    of dkRemove:
      acc = merge(acc, invert(contributions[delta.removeIdx]))
      contributions.delete(delta.removeIdx)
    of dkUpdate:
      let m = f(delta.updateVal)
      acc = merge(merge(acc, invert(contributions[delta.updateIdx])), m)
      contributions[delta.updateIdx] = m
    of dkClear:
      contributions.setLen(0)
      acc = unit(M)
    of dkReplace:
      contributions.setLen(0)
      acc = unit(M)
      for x in delta.replaceVal:
        let m = f(x)
        contributions.add m
        acc = merge(acc, m)
    of dkRollback:                  # recompute from the reverted source
      contributions.setLen(0)
      acc = unit(M)
      for x in c.get():
        let m = f(x)
        contributions.add m
        acc = merge(acc, m)
    outSig.set(acc)
  outSig

proc foldedDynamic[T, M: CommutativeGroup](c: ReactiveCollection[T],
    f: proc(x: T): M {.closure.}): Dynamic[M] =
  ## The dynamic (◇-modality) floor under the `fold` macro: same
  ## incremental commutative-group aggregation as `folded`, but the
  ## output is a `Dynamic[M]` carrying the ◇-modality through the type
  ## system. Height is runtime-composed (no fixedHeight knob — dynamic
  ## inputs don't carry a baked height for the macro to thread through).
  mixin merge, unit, invert
  var contributions: seq[M]
  var acc = unit(M)
  for x in c.get():
    let m = f(x)
    contributions.add m
    acc = merge(acc, m)
  let outDyn = newDynamic(acc)
  Subscribable(outDyn).height = Subscribable(c).height + 1
  c.onDelta proc(delta: Delta[T]) =
    case delta.kind
    of dkInsert:
      let m = f(delta.insertVal)
      contributions.insert(m, delta.insertIdx)
      acc = merge(acc, m)
    of dkRemove:
      acc = merge(acc, invert(contributions[delta.removeIdx]))
      contributions.delete(delta.removeIdx)
    of dkUpdate:
      let m = f(delta.updateVal)
      acc = merge(merge(acc, invert(contributions[delta.updateIdx])), m)
      contributions[delta.updateIdx] = m
    of dkClear:
      contributions.setLen(0)
      acc = unit(M)
    of dkReplace:
      contributions.setLen(0)
      acc = unit(M)
      for x in delta.replaceVal:
        let m = f(x)
        contributions.add m
        acc = merge(acc, m)
    of dkRollback:
      contributions.setLen(0)
      acc = unit(M)
      for x in c.get():
        let m = f(x)
        contributions.add m
        acc = merge(acc, m)
    outDyn.val = acc
    notify(Subscribable(outDyn))
  outDyn

# --- Delta-stream fold floor (under scan) ---------------------------------

type
  DeltaStream*[T] = ref object of Subscribable
    ## `c`'s event face — carries the deltas pending for the current
    ## propagation. Height equals `c`'s, so a `scan` over it composes a
    ## normal `c.height + 1`.
    pending: seq[Delta[T]]

proc deltas[T](c: CollectionSignal[T]): DeltaStream[T] =
  ## Obtain `c`'s delta stream. Each mutation pushes its typed delta onto the
  ## stream and schedules the stream's observers through the height-ordered
  ## scheduler.
  let s = DeltaStream[T]()
  s.height = Subscribable(c).height
  c.onDelta proc(d: Delta[T]) =
    s.pending.add d
    notify(Subscribable(s))
  s

proc foldDeltas[T, S](s: DeltaStream[T], initial: S,
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
  let outSig = signalC(initial)
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
