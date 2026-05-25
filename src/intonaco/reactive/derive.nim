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

type
  DerivedCollection*[U] = ref object of Subscribable
    items: seq[U]

proc get*[U](d: DerivedCollection[U]): seq[U] =
  ## Snapshot of the mapped items; registers a reactive dependency.
  trackRead(d)
  d.items

proc `()`*[U](d: DerivedCollection[U]): seq[U] = d.get()

proc len*[U](d: DerivedCollection[U]): int =
  trackRead(d)
  d.items.len

proc mapped*[T, U](c: CollectionSignal[T], f: proc(x: T): U {.closure.},
                   fixedHeight = -1): DerivedCollection[U] =
  ## The runtime floor under the `derive` macro — value-constructed. A mapped
  ## view of `c`: `value === c.map(f)`, maintained incrementally as `c` changes.
  ## `fixedHeight >= 0` bakes the scheduling height (the `derive` macro passes
  ## the compile-time-composed height) so the node is in the static fragment.
  let d = DerivedCollection[U]()
  d.height = if fixedHeight >= 0: fixedHeight else: Subscribable(c).height + 1
  d.items = c.get().map(f)
  c.onDelta proc(delta: Delta[T]) =
    # Apply only what the delta touched — `f` runs on the changed element, not
    # the whole collection. The structurally-destructive kinds (replace / the
    # batched rollback) re-map wholesale: correct, and inherently O(N) anyway.
    case delta.kind
    of dkInsert:   d.items.insert(f(delta.insertVal), delta.insertIdx)
    of dkRemove:   d.items.delete(delta.removeIdx)
    of dkUpdate:   d.items[delta.updateIdx] = f(delta.updateVal)
    of dkClear:    d.items.setLen(0)
    of dkReplace:  d.items = delta.replaceVal.map(f)
    of dkRollback: d.items = c.get().map(f)
    notify(Subscribable(d))
  d

proc sourceHeight(coll: NimNode): int {.compileTime.} =
  ## The compile-time height of a `derive` source. A `CollectionSignal[_]` is
  ## ALWAYS a source (derived collections are the distinct `DerivedCollection`
  ## type), so it's height 0 by construction — no `collections:` ceremony.
  ## A `DerivedCollection` carries a baked height from its own `derive`.
  let ty = coll.getTypeInst
  if ty.kind == nnkBracketExpr and ty.len >= 1:
    case ty[0].repr
    of "CollectionSignal": return 0
    of "DerivedCollection":
      let h = heightOf(coll)
      if h.isSome: return h.get
      error("derive: derived source `" & coll.repr &
            "` carries no baked height (built via the `mapped` floor?)", coll)
    else: discard
  error("derive: `" & coll.repr & "` is not a bindable collection source", coll)

macro derive*(name: untyped, coll: typed, f: typed): untyped =
  ## A compile-time-scheduled mapped view of a collection — the blessed form
  ## (the floor is `mapped`). The source's height is resolved at compile time
  ## (a `CollectionSignal` is height 0 by construction), composed, and baked
  ## onto `name` so the node is in the static fragment and downstream `derive`s
  ## compose through it.
  let h = sourceHeight(coll) + 1
  let ctor = newCall(bindSym"mapped", coll, f,
    nnkExprEqExpr.newTree(ident"fixedHeight", newLit(h)))
  nnkLetSection.newTree(nnkIdentDefs.newTree(
    withHeight(name, h), newEmptyNode(), ctor))
