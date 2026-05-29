## The runtime reactive floor — INTERNAL plumbing, not part of the blessed
## surface.
##
## `createEffect` / `createComputed` build a reactive node from a `proc()`
## VALUE with no compile-time classification: the height is accumulated at
## subscribe time. They are the substrate the higher layers stand on:
##   - the `computed` / `effect` / `dynamic` macros emit them via `bindSym`
##     (so consumers get classification + glitch-free scheduling),
##   - `dynamicComputed` / `dynamicEffect` (see `reactive/dynamic`) wrap them
##     as the sanctioned value-construction escape,
##   - `tracked:` and `mountWhen` use them internally.
##
## Consumers should NOT import this module. There is no compile-time scheduling
## here and no `dynamic:`-style quarantine — reach for the macros or `Dynamic[T]`
## instead. It is `*`-exported only so the macros' `bindSym` and the in-package
## users can name it; importing it is the explicit, greppable "I'm bypassing the
## classifier" act.

import ./subscribable
import ./scope
import ./signal
export subscribable   ## callers of `createEffect` need to name `Computation`

proc createEffect*(body: proc() {.closure.}, kind = ckEffect,
                   fixedHeight = -1): Computation {.gcsafe, discardable.} =
  ## Run `body` immediately, tracking reactive reads; re-run on any tracked
  ## change until the enclosing scope is disposed. Returns the Computation
  ## (discardable) so `createComputed` can read its height and tag its kind.
  ##
  ## `fixedHeight >= 0` bakes the height (#53): the Architecture-B macros pass
  ## the compile-time-resolved height so subscribe-time accumulation does not
  ## override it. `-1` (the default / explicit-dynamic path) accumulates.
  {.cast(gcsafe).}:
    let comp = Computation(kind: kind)
    if fixedHeight >= 0:
      comp.height = fixedHeight
      comp.heightFixed = true
    comp.run = proc() =
      if comp.disposed: return
      unsubscribeAll(comp)
      let prev = currentComputation
      currentComputation = comp
      try:
        body()
      finally:
        currentComputation = prev
    if currentScope != nil:
      onCleanup proc() =
        comp.disposed = true
        unsubscribeAll(comp)
    comp.run()
    result = comp

proc createComputed*[T](body: proc(): T {.closure.}, fixedHeight = -1): Signal[T]
    {.gcsafe.} =
  ## A derived signal that re-evaluates when its dependencies change. Reading
  ## the returned signal both yields the current value and subscribes the
  ## current computation to it.
  ##
  ## `fixedHeight >= 0` bakes the producing computation's height (#53); the
  ## output signal then carries that baked height for downstream readers.
  {.cast(gcsafe).}:
    let outSig = signalC(default(T))   # placeholder; the effect sets it immediately
    let comp = createEffect((proc() = outSig.set(body())), kind = ckComputed,
                            fixedHeight = fixedHeight)
    # The output signal carries the producing computation's height, so
    # downstream readers compute their height relative to it. (When baked,
    # comp.height is the fixed height; otherwise the accumulated one.)
    outSig.height = comp.height
    result = outSig
