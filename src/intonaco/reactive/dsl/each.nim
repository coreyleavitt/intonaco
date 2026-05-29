## Per-item bindings over a CollectionSignal — the dynamic-tier shape for
## "set dynamism" (lists that grow / shrink at runtime).
##
## Iterates a `CollectionSignal[T]`'s delta stream. For each item present in
## the collection (initially + on insert), runs `body(item)` in a fresh
## scope. On remove, disposes the scope — which cascades `onCleanup` callbacks
## through every reactive binding the body created. Lifecycle is by
## construction; there is no "did I forget to unsubscribe?" surface.
##
## Usage:
##   let todos = collectionC[Todo]()
##   eachItem(todos) do (todo: Todo):
##     computed display, [pageStyle]:
##       formatTodo(pageStyle, todo)
##     effect [display]:
##       paint(display)
##
## The body's reactive bindings (`computed` / `effect` / nested `eachItem` /
## `dynamic`) attach to the current scope; the scope's disposal on remove
## tears them all down.


macro eachDelta*(src: typed, deltaIdent: untyped, body: untyped): untyped =
  ## Observe each delta of `src` as it fires; run `body` with the delta
  ## bound to `deltaIdent`. The substrate's public seam for "side-effect-
  ## on-delta" — wraps the private `onDelta` floor with a named, walker-
  ## reachable surface for substrate-author consumers (fresco's
  ## bindCollection, devtools-style widgets).
  ##
  ## Usage:
  ##   collections:
  ##     items = newSeq[int]()
  ##   eachDelta items, d:
  ##     case d.kind
  ##     of dkInsert: target.setRow(d.insertIdx, $d.insertVal)
  ##     of dkRemove: target.eraseRow(d.removeIdx)
  ##     else: discard
  ##
  ## Walker discipline: `src` is implicitly the only declared dep. The
  ## body is a closure passed to `onDelta`; the walker skips lambda
  ## bodies (deferred-execution context). Opaque side effects (IO,
  ## mutation of captured locals) are allowed — that's the point of the
  ## seam. Body fires at `src.height + 1`, scope-bound via `onDelta`'s
  ## cleanup machinery.
  ##
  ## Modality: works over both `CollectionSignal[T]` (static) and
  ## `DynamicCollection[T]` (dynamic) — both inherit `ReactiveCollection[T]`
  ## so `onDelta`'s dispatch resolves without modality branching here.
  expectKind(deltaIdent, nnkIdent)
  let srcType = src.getTypeInst
  if srcType.kind != nnkBracketExpr or srcType.len < 2:
    error("eachDelta: source must be a reactive collection (" &
          "CollectionSignal[T] or DynamicCollection[T])", src)
  let elemType = srcType[1]
  result = quote do:
    `src`.onDelta proc(`deltaIdent`: Delta[`elemType`]) {.closure.} =
      `body`

proc eachItem*[T](src: CollectionSignal[T],
                  body: proc(item: T) {.closure.}) =
  ## Initial seed: for each item currently in `src`, spawn a scope, run
  ## `body(item)` in it, retain the scope. Then subscribe to the collection's
  ## delta stream: on insert, spawn a scope at the insertion index; on remove,
  ## dispose the scope at the removed index and drop the seq slot; on clear,
  ## dispose all scopes; updates / replaces / rollbacks are not handled in
  ## this version (a richer iteration can be added without changing this
  ## interface).
  var scopes: seq[Scope] = @[]
  proc spawnAt(item: T, pos: int) =
    let s = newScope()
    withScope s:
      body(item)
    if pos >= scopes.len: scopes.add s
    else: scopes.insert(s, pos)
  for i, item in src.get():
    spawnAt(item, i)
  onDelta(src, proc(d: Delta[T]) =
    case d.kind
    of dkInsert:
      spawnAt(d.insertVal, d.insertIdx)
    of dkRemove:
      scopes[d.removeIdx].dispose()
      scopes.delete(d.removeIdx)
    of dkClear:
      for s in scopes: s.dispose()
      scopes.setLen(0)
    else:
      discard
  )
