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
import ./height
import ./classify

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

macro derive*(name: untyped, coll: typed, f: typed): untyped =
  ## A compile-time-scheduled mapped view of a collection — the blessed form
  ## (the floor is `mapped`). The source's height is resolved at compile time
  ## (a `CollectionSignal` is height 0 by construction), composed, and baked
  ## onto `name` so the node is in the static fragment and downstream `derive`s
  ## compose through it.
  # The map must be PURE. `derive` is a LINEAR operator (`map(f)(c ⊕ δ) =
  # map(f)(c) ⊕ map(f)(δ)`), which is what makes incremental == apply-to-delta
  # sound. A signal-dependent map is BILINEAR (a collection×signal join) — out
  # of scope; express it as a `computed` (`c.get().map(...)`) or at the render
  # layer. Classify the map's BODY — for a named proc, via `getImpl` — so the
  # check catches reactive reads TRANSITIVELY (through helper procs), not just
  # in an inline lambda.
  let fBody =
    if f.kind in {nnkLambda, nnkProcDef, nnkFuncDef}: f.body
    elif f.kind == nnkSym and f.getImpl.kind in {nnkProcDef, nnkFuncDef}: f.getImpl.body
    else: f
  let cls = classify(fBody)
  if cls.tier == tDynamic or (cls.tier == tStatic and cls.height > 0):
    error("derive: the map reads reactive state — `derive` is a linear (pure) " &
          "map. For a signal-dependent map use a `computed` (`c.get().map(...)`) " &
          "or apply it at the render layer; a collection×signal map is a join, " &
          "deliberately out of scope.", f)
  let h = sourceHeight(coll) + 1
  let ctor = newCall(bindSym"mapped", coll, f,
    nnkExprEqExpr.newTree(ident"fixedHeight", newLit(h)))
  nnkLetSection.newTree(nnkIdentDefs.newTree(
    withHeight(name, h), newEmptyNode(), ctor))
