## `derive` / `keep` / `fold` — height-baked collection-transform macros.
##
## `derive(c, f)` is a read-only reactive collection whose value is, by
## definition, `c.get().map(f)` — a pure dataflow node (it sits in the Lean
## proof's model as `value = f(source)`, NOT a stateful fold). The incremental
## maintenance (apply `f` only to the element a delta touched, forwarding a
## mapped delta) is a runtime optimization that must stay equivalent to the
## wholesale map; that equivalence is the proof obligation, one lemma per
## `DeltaKind`.
##
## Each macro enforces purity (linearity) via the C-shape walker
## (`noUndeclaredSignals` from `binding`) applied to the function's body, and
## bakes a compile-time height, then emits its value-constructed floor
## (`mapped` / `filtered` / `folded`, in `reactive/deltafloor`) via `bindSym`.
##
## A signal-dependent function makes the operator bilinear (a join), which is
## deliberately out of scope — for cross-signal transforms, use a `computed`
## (`c.get()` then transform) or apply at the render layer.

{.experimental: "callOperator".}

import std/[macros, options]
import ../primitives/deltafloor   # mapped / filtered / folded — named by bindSym
import ../primitives/height
import ../analysis/pass            # runAnalysis
import ../analysis/passes_core     # registers the three core walker passes

proc isDynamicCollectionType(ty: NimNode): bool {.compileTime.} =
  ## True iff `ty` is `DynamicCollection[_]` (the ◇-modality collection).
  ## The modality check the M-δ macros dispatch on — distinct from
  ## CollectionSignal (□-modality source) and from a baked-height
  ## derived view.
  ty.kind == nnkBracketExpr and ty.len >= 1 and ty[0].repr == "DynamicCollection"

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
        "source (a plain `collectionC()` or a named `derive` result)", coll)

proc fnBody(fn: NimNode): NimNode {.compileTime.} =
  ## Extract the body of a function argument for the walker. Inline lambdas
  ## and proc defs expose their body directly; a named proc symbol needs
  ## `getImpl` to reach the body (so transitive reads through helpers are
  ## also walker-checked).
  if fn.kind in {nnkLambda, nnkProcDef, nnkFuncDef}: return fn.body
  if fn.kind == nnkSym and fn.getImpl.kind in {nnkProcDef, nnkFuncDef}:
    return fn.getImpl.body
  fn

proc transformBinding(name, coll, fn, floor: NimNode, op: string): NimNode
    {.compileTime.} =
  ## Shared emission for the linear collection-transform macros: walker-check
  ## the function for purity (at THIS macro's compile time via `getAst`, so no
  ## runtime trace), resolve+compose the source height, bake it onto `name`,
  ## and emit `floor(coll, fn, fixedHeight = h)`.
  let body = fnBody(fn)
  discard getAst(runAnalysis(body, []))    # walker fires at sem; errors localize
  let h = sourceHeight(coll) + 1
  let ctor = newCall(floor, coll, fn,
    nnkExprEqExpr.newTree(ident"fixedHeight", newLit(h)))
  nnkLetSection.newTree(nnkIdentDefs.newTree(
    withHeight(name, h), newEmptyNode(), ctor))

proc transformBindingDynamic(name, coll, fn, floorDynamic: NimNode): NimNode
    {.compileTime.} =
  ## Dynamic-modality (◇) emission. Same walker check as the static
  ## variant (the function must be linear), but the source carries no
  ## baked height — emission is `floorDynamic(coll, fn)` with runtime
  ## height composition, and the result's type carries the ◇-modality
  ## through the binding (no `{.height.}` pragma on `name`).
  let body = fnBody(fn)
  discard getAst(runAnalysis(body, []))
  let ctor = newCall(floorDynamic, coll, fn)
  nnkLetSection.newTree(nnkIdentDefs.newTree(name, newEmptyNode(), ctor))

macro derive*(name: untyped, coll: typed, f: typed): untyped =
  ## A reactive mapped view of a collection — the blessed `map`. Modality-
  ## polymorphic: dispatches on the input's static type.
  ##
  ## * Static input (`CollectionSignal[T]` or a baked-height derived
  ##   view): emits `mapped` with a compile-time-composed `fixedHeight`,
  ##   bakes `{.height.}` on `name`, returns `ReactiveCollection[U]`.
  ## * Dynamic input (`DynamicCollection[T]`): emits `mappedDynamic`,
  ##   no height bake, returns `DynamicCollection[U]`. The ◇-modality
  ##   propagates so chained `derive`/`keep` over the result stay
  ##   dynamic.
  ##
  ## `f` must be pure (linear `map`) in both modes — the walker
  ## rejects reactive reads inside the function body regardless of
  ## modality.
  if isDynamicCollectionType(coll.getTypeInst):
    transformBindingDynamic(name, coll, f, bindSym"mappedDynamic")
  else:
    transformBinding(name, coll, f, bindSym"mapped", "derive")

macro keep*(name: untyped, coll: typed, p: typed): untyped =
  ## A reactive filtered view — keeps elements satisfying `p`. Modality-
  ## polymorphic (M-δ): dispatches on input type, mirroring `derive`.
  ## Named `keep` rather than `filter` because `std/sequtils` exports
  ## `filter`, and the new-binding name in `keep e, c, p` would collide
  ## during overload resolution. `p` must be pure (linear) in both modes.
  if isDynamicCollectionType(coll.getTypeInst):
    transformBindingDynamic(name, coll, p, bindSym"filteredDynamic")
  else:
    transformBinding(name, coll, p, bindSym"filtered", "keep")

macro fold*(name: untyped, coll: typed, f: typed): untyped =
  ## An incremental commutative-group aggregate (collection→scalar).
  ## Modality-polymorphic:
  ##
  ## * Static input: emits `folded`, output `Signal[M]` with baked height.
  ## * Dynamic input: emits `foldedDynamic`, output `Dynamic[M]` — the
  ##   ◇-modality of the scalar tier. The modality propagates so
  ##   downstream static `computed`/`effect` over the result is
  ##   walker-rejected (type-quarantine via `Dynamic[_]`).
  ##
  ## `f` must be pure (linear) in both modes.
  if isDynamicCollectionType(coll.getTypeInst):
    transformBindingDynamic(name, coll, f, bindSym"foldedDynamic")
  else:
    transformBinding(name, coll, f, bindSym"folded", "fold")
