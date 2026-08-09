## Reactive-computation runtime primitives — `computedC` and `effectC`.
##
## These are the procs the C-shape DSL macros (`computed` / `effect` in
## `dsl/binding.nim`) emit. They subscribe to declared deps and re-fire the
## body when any dep changes; height is either compile-time-baked by the
## macro (`fixedHeight >= 0`) or runtime-composed via `maxDepHeight`.
##
## Substrate-internal. Consumers use the DSL macros instead. Substrate-
## template authors use these via the M-α.3 authoring kit.


proc maxDepHeight(deps: openArray[Subscribable]): int =
  for d in deps:
    if d.height + 1 > result: result = d.height + 1

proc computedC[T](deps: openArray[Subscribable],
                   body: proc(): T {.closure.},
                   fixedHeight = -1): Signal[T] {.gcsafe.} =
  ## The runtime primitive under the `computed` macro. Height: `fixedHeight`
  ## if >= 0 (compile-time-baked by the macro), else runtime-composed via
  ## `maxDepHeight`. Subscribes to declared deps only.
  ##
  ## `{.gcsafe.}` is asserted via the single-chronos-dispatcher invariant
  ## (see fresco/CLAUDE.md non-negotiables): no concurrent thread races
  ## the subscribe / onCleanup / scope machinery. Matches the discipline
  ## of the lower-level `createEffect` / `createComputed` in `runtime.nim`.
  {.cast(gcsafe).}:
    let h = if fixedHeight >= 0: fixedHeight else: maxDepHeight(deps)
    let outSig = signalC(body())
    outSig.height = h
    let comp = Computation(kind: ckComputed, height: h, heightFixed: true)
    comp.run = proc() =
      if comp.disposed: return
      outSig.set(body())
    for d in deps: subscribe(d, comp)
    if currentScope.value != nil:
      let captured = comp
      onCleanup proc() =
        captured.disposed = true
        unsubscribeAll(captured)
    outSig

proc effectC(deps: openArray[Subscribable], body: proc() {.closure.},
              fixedHeight = -1) {.gcsafe.} =
  ## The runtime primitive under the `effect` macro. Same shape as `computedC`,
  ## side-effect only. See `computedC` for the gcsafe discipline.
  {.cast(gcsafe).}:
    let h = if fixedHeight >= 0: fixedHeight else: maxDepHeight(deps)
    let comp = Computation(kind: ckEffect, height: h, heightFixed: true)
    comp.run = proc() =
      if comp.disposed: return
      body()
    for d in deps: subscribe(d, comp)
    body()
    if currentScope.value != nil:
      let captured = comp
      onCleanup proc() =
        captured.disposed = true
        unsubscribeAll(captured)
