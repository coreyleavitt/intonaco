## `derive` — an incrementally-maintained mapped view of a collection.
##
## `derive(c, f)` is a read-only reactive collection whose value is, by
## definition, `c.get().map(f)` — a pure dataflow node (it sits in the Lean
## proof's model as `value = f(source)`, NOT a stateful fold). The incremental
## maintenance (apply `f` only to the element a delta touched, forwarding a
## mapped delta) is a runtime optimization that must stay equivalent to the
## wholesale map; that equivalence is the proof obligation, one lemma per
## `DeltaKind`.

{.experimental: "callOperator".}

import std/[sequtils, macros, options]
import ./subscribable
import ./collection
import ./signal
import ./height
import ./classify
import ./convergence

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

proc mapped*[T, U](c: ReactiveCollection[T], f: proc(x: T): U {.closure.},
                   fixedHeight = -1): ReactiveCollection[U] =
  ## The runtime floor under the `derive` macro — value-constructed. A mapped
  ## view of `c`: `value === c.map(f)`, maintained incrementally (each source
  ## delta becomes a mapped delta applied to the view and forwarded to the
  ## view's own consumers). `fixedHeight >= 0` bakes the scheduling height.
  ## Accepts ANY `ReactiveCollection` source, so `derive` composes.
  let h = if fixedHeight >= 0: fixedHeight else: Subscribable(c).height + 1
  let d = newReactive[U](c.get().map(f), height = h)
  c.onDelta proc(delta: Delta[T]) =
    if delta.kind == dkRollback:
      # A structural revert: recompute the view from the (already rolled-back)
      # source and forward it as one replace. Mapping the inverse ops onto the
      # view would have to mirror the source's reverse-application exactly;
      # recompute-from-source is the simpler, provably-equivalent path.
      pushDelta(d, Delta[U](kind: dkReplace, replaceVal: c.get().map(f)))
    else:
      pushDelta(d, mapDelta(delta, f))   # mapped delta: apply + emit to d's consumers
  d

proc filtered*[T](c: ReactiveCollection[T], p: proc(x: T): bool {.closure.},
                  fixedHeight = -1): ReactiveCollection[T] =
  ## The runtime floor under the `filter` macro. A filtered view of `c`:
  ## `value === c.filter(p)`, maintained incrementally. `filter` is linear
  ## (selection distributes over disjoint union), but the POSITIONAL model needs
  ## a source→view index translation: `kept[i]` mirrors `p(source[i])`, and a
  ## source index maps to a view index by `rank` (kept elements strictly before
  ## it). `p` must be pure (enforced by the macro) — a signal-dependent predicate
  ## is bilinear, out of scope.
  let src = c.get()
  var kept = newSeq[bool](src.len)
  var initial: seq[T]
  for i in 0 ..< src.len:
    kept[i] = p(src[i])
    if kept[i]: initial.add src[i]
  let h = if fixedHeight >= 0: fixedHeight else: Subscribable(c).height + 1
  let d = newReactive[T](initial, height = h)
  # rank(i) = number of kept elements strictly before source index i. O(i) here;
  # an order-statistic / Fenwick structure makes it O(log n) without changing the
  # rule (a localized optimization for large collections).
  proc rank(i: int): int =
    for j in 0 ..< i:
      if kept[j]: inc result
  proc recompute() =
    let s = c.get()
    kept = newSeq[bool](s.len)
    var fv: seq[T]
    for i in 0 ..< s.len:
      kept[i] = p(s[i])
      if kept[i]: fv.add s[i]
    pushDelta(d, Delta[T](kind: dkReplace, replaceVal: fv))
  c.onDelta proc(delta: Delta[T]) =
    case delta.kind
    of dkInsert:
      let r = rank(delta.insertIdx)
      let k = p(delta.insertVal)
      kept.insert(k, delta.insertIdx)
      if k: pushDelta(d, Delta[T](kind: dkInsert, insertIdx: r, insertVal: delta.insertVal))
    of dkRemove:
      let r = rank(delta.removeIdx)
      let was = kept[delta.removeIdx]
      kept.delete(delta.removeIdx)
      if was: pushDelta(d, Delta[T](kind: dkRemove, removeIdx: r))
    of dkUpdate:
      let r = rank(delta.updateIdx)
      let oldK = kept[delta.updateIdx]
      let newK = p(delta.updateVal)
      kept[delta.updateIdx] = newK
      if oldK and newK:
        pushDelta(d, Delta[T](kind: dkUpdate, updateIdx: r, updateVal: delta.updateVal))
      elif oldK and not newK:
        pushDelta(d, Delta[T](kind: dkRemove, removeIdx: r))
      elif (not oldK) and newK:
        pushDelta(d, Delta[T](kind: dkInsert, insertIdx: r, insertVal: delta.updateVal))
      # else: stays filtered out — no view delta
    of dkClear:
      kept.setLen(0)
      pushDelta(d, Delta[T](kind: dkClear))
    of dkReplace:
      kept = newSeq[bool](delta.replaceVal.len)
      var fv: seq[T]
      for i in 0 ..< delta.replaceVal.len:
        kept[i] = p(delta.replaceVal[i])
        if kept[i]: fv.add delta.replaceVal[i]
      pushDelta(d, Delta[T](kind: dkReplace, replaceVal: fv))
    of dkRollback: recompute()   # recompute from the reverted source (the oracle)
  d

proc folded*[T, M: CommutativeGroup](c: ReactiveCollection[T],
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
  let outSig = signal(acc)
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

proc sourceHeight(coll: NimNode): int {.compileTime.} =
  ## The compile-time height of a `derive` source. A `CollectionSignal[_]` is
  ## ALWAYS a source (a derived view is a plain `ReactiveCollection` carrying a
  ## baked height), so it's height 0 by construction — no `collections:`
  ## ceremony. Any other reactive collection must carry a baked height.
  let ty = coll.getTypeInst
  if ty.kind == nnkBracketExpr and ty.len >= 1 and ty[0].repr == "CollectionSignal":
    return 0
  let h = heightOf(coll)
  if h.isSome: return h.get
  error("derive: `" & coll.repr & "` is not a statically-resolvable collection " &
        "source (a plain `collection()` or a named `derive` result)", coll)

proc requirePure(fn: NimNode, op: string) {.compileTime.} =
  ## Reject a function argument that reads reactive state. The collection
  ## operators (`map`/`filter`) are LINEAR — `op(c ⊕ δ) = op(c) ⊕ op(δ)` — which
  ## is what makes incremental == apply-to-delta sound; a signal-dependent
  ## function makes it bilinear (a join), out of scope. Classify the function's
  ## BODY — for a named proc, via `getImpl` — so reads are caught TRANSITIVELY
  ## (through helper procs), not just in an inline lambda.
  let body =
    if fn.kind in {nnkLambda, nnkProcDef, nnkFuncDef}: fn.body
    elif fn.kind == nnkSym and fn.getImpl.kind in {nnkProcDef, nnkFuncDef}: fn.getImpl.body
    else: fn
  let cls = classify(body)
  if cls.tier == tDynamic or (cls.tier == tStatic and cls.height > 0):
    error(op & ": the function reads reactive state — collection operators are " &
          "linear (pure). For a signal-dependent transform use a `computed` " &
          "(`c.get()` then transform) or apply it at the render layer; a " &
          "collection×signal transform is a join, deliberately out of scope.", fn)

proc transformBinding(name, coll, fn, floor: NimNode, op: string): NimNode
    {.compileTime.} =
  ## Shared emission for the linear collection-transform macros: enforce purity,
  ## resolve+compose the source height at compile time, bake it onto `name`, and
  ## emit `floor(coll, fn, fixedHeight = h)`. So the binding is in the static
  ## fragment and downstream transforms compose through its baked height.
  requirePure(fn, op)
  let h = sourceHeight(coll) + 1
  let ctor = newCall(floor, coll, fn,
    nnkExprEqExpr.newTree(ident"fixedHeight", newLit(h)))
  nnkLetSection.newTree(nnkIdentDefs.newTree(
    withHeight(name, h), newEmptyNode(), ctor))

macro derive*(name: untyped, coll: typed, f: typed): untyped =
  ## A compile-time-scheduled mapped view of a collection — the blessed `map`
  ## (the floor is `mapped`). `f` must be pure (linear `map`); the height is
  ## resolved + baked so downstream transforms compose.
  transformBinding(name, coll, f, bindSym"mapped", "derive")

macro keep*(name: untyped, coll: typed, p: typed): untyped =
  ## A compile-time-scheduled filtered view — keeps the elements satisfying `p`
  ## (the floor is `filtered`). Named `keep` rather than `filter` because
  ## `std/sequtils` exports `filter`, and the new-binding name in `keep e, c, p`
  ## would collide during overload resolution. `p` must be pure (linear).
  transformBinding(name, coll, p, bindSym"filtered", "keep")

macro fold*(name: untyped, coll: typed, f: typed): untyped =
  ## A compile-time-scheduled incremental aggregate (collection→scalar) over a
  ## commutative group — the floor is `folded`. `acc = ⊕ f(x)`, maintained O(1)
  ## per delta via the group inverse. `f` must be pure (linear).
  transformBinding(name, coll, f, bindSym"folded", "fold")
