## Dynamic[T] — the type-quarantined escape to the runtime floor.
##
## The static-tier bindings (`computed` / `effect` in `binding.nim`) declare
## their deps explicitly and compose heights at compile time. But some nodes
## are built from a `proc()` VALUE — a factory, a closure assembled at
## runtime — whose read-set isn't a fixed compile-time list. Those are the
## dynamic tier.
##
## The shape:
##   * `Dynamic[T]` is the type that carries the dynamic-ness through the
##     type system. Any binding that reads one is itself in the dynamic tier;
##     the `binding` module's walker rejects a `Dynamic[_]`-typed reference
##     in a static body at sem time.
##   * `dynamicComputed` / `dynamicEffect` are the runtime-floor constructors,
##     auto-tracking reads via the existing `createEffect` machinery.
##   * `dynamic name: body` is the macro form — `let name = dynamicComputed(...)`.
##
## `Dynamic[T]` is height-uncomposable by construction: the value never
## carries a baked `{.height.}` pragma, so a static `computed` declaring it
## as a dep gets `composeHeight = none` and is a compile error (M-ε.3
## made the static-gate unconditional). The escape is explicit,
## greppable (the user wrote `dynamic name: ...`), and cannot masquerade as
## statically scheduled.



proc get*[T](d: Dynamic[T]): T {.gcsafe, tags: [ReactiveRead].} =
  ## Read the current value, registering a dependency on the current
  ## Computation. Carries `ReactiveRead` (like `Signal.get`) so the static-tier
  ## walker catches a Dynamic read hidden behind a helper — directly via the
  ## type-walk (Dynamic[_] sym), transitively via the reactive-read effect tag.
  trackRead(d)
  d.val

proc `()`*[T](d: Dynamic[T]): T {.gcsafe.} = d.get()

proc dynamicComputed[T](body: proc(): T {.closure.}): Dynamic[T] =
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

proc dynamicEffect(body: proc() {.closure.}): Computation {.discardable.} =
  ## Value-construct a leaf side-effect on the runtime floor — the `proc()`
  ## form of the `effect:` macro. Runs `body` immediately, re-runs on any read
  ## signal's change, and is torn down with the current scope. Returns the
  ## Computation handle for lifecycle control.
  createEffect(body)

# --- The macro sugar -------------------------------------------------------

macro dynamic*(name: untyped, body: untyped): untyped =
  ## `dynamic name: body` desugars to `let name = dynamicComputed(proc(): auto = body)`.
  ##
  ## The body runs on the runtime floor with auto-tracking: reads via `.get()`
  ## / `()` register edges to the underlying signals; reads via `.peek()` do
  ## not. The result is `Dynamic[T]`, propagating the dynamic-ness through
  ## the type system.
  ##
  ## Example:
  ##   let activeTab = signalC(0)
  ##   dynamic visibleContent:
  ##     tabs[activeTab.get()].title.get()
  ##
  ## A static `computed` declaring `visibleContent` as a dep is a compile
  ## error (no baked height) — M-ε.3 made the static-gate unconditional;
  ## the dynamic tier IS the named escape, used at the read site rather
  ## than as a fallback. Reads of `visibleContent` inside a static body
  ## are rejected by the walker (type-quarantine).
  result = quote do:
    let `name` = dynamicComputed(proc(): auto = `body`)
