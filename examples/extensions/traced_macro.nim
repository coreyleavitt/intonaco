## Worked example: a kit-built substrate template with a custom runtime primitive.
##
## **What this template provides**: `traced name, [deps]: body` — semantically
## identical to `computed name, [deps]: body` (same dep declaration; same
## walker discipline; same compile-time height baking) but layered on a
## different runtime primitive that increments a module-level counter on each
## fire. Pedagogical demo for the substrate-template authoring kit (M-α.3).
##
## **What this example demonstrates**:
## - The substrate kit composes new substrate templates from existing
##   primitives — `tracedC` is built on top of `computedC` by wrapping the
##   body proc to add a side effect, but to the user it looks like a
##   first-class substrate primitive.
## - The kit-built macro (`traced`) inherits ALL the substrate discipline
##   (walker checks, height baking, dep-rewrite, runAnalysis integration)
##   from `compileBindingInner` — zero re-implementation.
## - Adding a new substrate template family is ~7 lines of macro definitions
##   plus the primitive.
##
## **Pattern**: when sinopia (the trace frontend) lands, its `traceSignal`
## and `traceTransition` substrate templates use exactly this shape:
## a `traceSignalC`-style primitive that calls into journal infrastructure,
## then a kit-built macro that exposes the template-author-side discipline.
##
## **How to use this template in your own code**:
##
##   import intonaco/examples/extensions/traced_macro
##
##   signals: x = 0
##   traced y, [x]: x * 2
##   x := 5
##   # TRACE_COUNTER incremented on each fire
##
## See `intonaco/docs/extension-protocol.md` §"Building new DSL macros: the
## substrate kit" for the full kit walkthrough.

# This extension is an INCLUDE-FILE, not a standalone module. Consumers
# include it AFTER `include intonaco/reactive_internal` so types unify
# within their compilation unit. See `docs/extension-protocol.md` for
# the substrate-author extension pattern.

# --- The custom runtime primitive -------------------------------------------

var TRACE_COUNTER* = 0
  ## Module-level counter incremented on each fire of any `traced`-built
  ## binding. The example's observable side effect, for the test to assert
  ## against.

proc tracedC*[T](deps: openArray[Subscribable],
                 body: proc(): T {.closure.},
                 fixedHeight = -1): Signal[T] {.gcsafe.} =
  ## A `computedC`-shaped runtime primitive that increments TRACE_COUNTER on
  ## each fire BEFORE invoking the body. Delegates the actual reactive
  ## machinery to `computedC`.
  ##
  ## `{.cast(gcsafe).}` matches the substrate's single-chronos-dispatcher
  ## invariant — bindings always fire on the dispatcher, never racing.
  {.cast(gcsafe).}:
    proc tracedBody(): T =
      inc TRACE_COUNTER
      body()
    computedC(deps, tracedBody, fixedHeight)

# --- The kit-built macros ---------------------------------------------------

macro tracedInner(name: untyped, deps: typed, body: untyped,
                  origDeps: untyped): untyped =
  ## Inner-typed macro: hand off to the kit's orchestrator with our
  ## primitive's name.
  compileBindingInner(name, deps, body, origDeps,
                      bindSym"tracedC", ekComputedShape, "traced")

macro traced*(name, deps, body): untyped =
  ## `traced name, [deps]: body` — the consumer-facing macro. Outer-untyped
  ## wraps deps in `Subscribable(...)` and invokes the inner macro.
  wrapDepsForInner(bindSym"tracedInner", name, deps, body)
