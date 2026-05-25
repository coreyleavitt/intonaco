## Dynamic[T] — the value-construction escape to the runtime floor.
##
## The blessed reactive surface is the `computed` / `effect` macros, which
## classify their body at compile time and schedule the static fragment
## glitch-free. But some nodes are built from a `proc()` VALUE (a factory, a
## closure assembled at runtime) whose reads the compiler cannot see. Those
## are categorically dynamic. `dynamicComputed` / `dynamicEffect` are their
## sanctioned constructors, and `Dynamic[T]` is the output type.
##
## `Dynamic[T]` is height-uncomposable BY CONSTRUCTION: the classifier treats
## any read of a `Dynamic[T]` as a dynamic dependency, so a `computed` reading
## one can never bake a static height (and so never glitch by under-counting).
## This is the type-level quarantine — the escape is explicit, greppable, and
## cannot masquerade as statically scheduled.

{.experimental: "callOperator".}

import ./signal

type
  Dynamic*[T] = ref object of Subscribable
    val: T

proc get*[T](d: Dynamic[T]): T {.gcsafe, tags: [ReactiveRead].} =
  ## Read the current value, registering a dependency on the current
  ## Computation. Carries `ReactiveRead` (like `Signal.get`) so the classifier
  ## catches a Dynamic read hidden behind a helper. A reader inside a `computed`
  ## body is forced to the dynamic tier — directly via the classifier's
  ## `drDynamicValue`, transitively via the reactive-read effect.
  trackRead(d)
  d.val

proc `()`*[T](d: Dynamic[T]): T {.gcsafe.} = d.get()

proc dynamicComputed*[T](body: proc(): T {.closure.}): Dynamic[T] =
  ## Value-construct a derived reactive value on the runtime floor. `body`
  ## re-runs whenever a signal it reads changes; the result is stored in the
  ## returned `Dynamic[T]` and its observers re-fire.
  let outDyn = Dynamic[T]()
  let comp = createEffect(proc() =
    let v = body()
    when compiles(outDyn.val == v):
      if outDyn.val == v: return
    outDyn.val = v
    notify(outDyn))
  # The output carries the producing computation's accumulated height, so a
  # downstream reader is scheduled only after this node settles (glitch-free
  # on the floor). The height is never baked as a `{.height.}` pragma, so the
  # static classifier still can't compose against it.
  outDyn.height = comp.height
  outDyn

proc dynamicEffect*(body: proc() {.closure.}): Computation {.discardable.} =
  ## Value-construct a leaf side-effect on the runtime floor — the `proc()`
  ## form of the `effect:` macro. Runs `body` immediately, re-runs on any read
  ## signal's change, and is torn down with the current scope. Returns the
  ## Computation handle for lifecycle control.
  createEffect(body)
