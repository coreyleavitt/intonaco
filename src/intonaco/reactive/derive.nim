## `derive`/`keep`/`fold` — the classified, height-baked collection-transform
## macros.
##
## `derive(c, f)` is a read-only reactive collection whose value is, by
## definition, `c.get().map(f)` — a pure dataflow node (it sits in the Lean
## proof's model as `value = f(source)`, NOT a stateful fold). The incremental
## maintenance (apply `f` only to the element a delta touched, forwarding a
## mapped delta) is a runtime optimization that must stay equivalent to the
## wholesale map; that equivalence is the proof obligation, one lemma per
## `DeltaKind`.
##
## Each macro enforces purity (linearity) and bakes a compile-time height, then
## emits its value-constructed floor (`mapped`/`filtered`/`folded`, in
## `reactive/deltafloor`) via `bindSym`. The floor procs are imported here only
## so `bindSym` can name them — they are NOT re-exported, so a consumer importing
## `derive` gets the macros, never the unclassified floor (see `test_surface`).

{.experimental: "callOperator".}

import std/[macros, options]
import ./deltafloor   # mapped / filtered / folded — named by bindSym, not re-exported
import ./height
import ./classify

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
