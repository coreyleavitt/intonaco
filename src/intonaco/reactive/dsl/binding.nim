## Static-tier reactive bindings — `computed` and `effect` with explicit deps.
##
## Each binding declares its dependencies syntactically in a bracket; heights
## compose at compile time over each dep's `{.height.}` pragma (see
## `primitives/height`); the resulting binding carries its own baked height
## for downstream composition. Under `-d:intonacoStrict` an unbaked dep is a
## hard compile error.
##
## Usage:
##   signals:
##     count = 0
##     title = ""
##   computed doubled, [count]:
##     count * 2
##   computed label, [count, doubled, title]:
##     title & ": " & $count & " (" & $doubled & ")"
##   effect [label]:
##     paint(label)
##
## Inside the body, the dep names are bound as the PEEK'D values — `count`
## above is `int`, not `Signal[int]`. The dep list is the only subscription
## mechanism; reads in the body are by-value snapshots, not edge-formers.
##
## The walker (`analysis/walker.noUndeclaredSignals`) is invoked over the
## body to reject the three stale-footgun patterns. The dep-sym rewrite
## (`analysis/ast.rewriteDepRefs`) makes the shadow survive template
## substitution.
##
## The Lean over-approximation lemma (`overApproxSound`, proofs/Consistency.lean)
## says: when the classifier over-collects the read-set and dep heights are
## sound, the baked height dominates the true height. Under the explicit-deps
## shape, `readset ⊆ D` is **true by construction** — the dep list IS the
## read-set. The implication delivers unconditionally.

{.experimental: "callOperator".}

import std/[macros, options]
import ../primitives/signal
import ../primitives/subscribable
import ../primitives/height
import ../primitives/computation
import ./kit                         # the substrate-template authoring kit

export signal      # `Signal[T]`, `signalC(...)`, `signals:`, `peek` — the
                   # user-facing static-tier surface composes on top of these
export height      # `heightOf` / `composeHeight` / `withHeight` — needed by
                   # the macros' generated code AND by `bakedHeight`'s callers

# --- The macros (built on the kit's orchestrator) ---------------------------

macro computedInner(name: untyped, deps: typed, body: untyped,
                    origDeps: untyped): untyped =
  compileBindingInner(name, deps, body, origDeps,
                      bindSym"computedC", ekComputedShape, "computed")

macro computed*(name: untyped, deps: untyped, body: untyped): untyped =
  ## `computed name, [d1, d2, ...]: body`. Two-macro pattern: outer untyped
  ## wraps each dep with `Subscribable(...)`; inner typed resolves heights at
  ## compile time + bakes `{.height.}` onto `name`.
  wrapDepsForInner(bindSym"computedInner", name, deps, body)

macro effectInner(deps: typed, body: untyped, origDeps: untyped): untyped =
  compileBindingInner(newEmptyNode(), deps, body, origDeps,
                      bindSym"effectC", ekEffectShape, "effect")

macro effect*(deps: untyped, body: untyped): untyped =
  ## `effect [d1, d2, ...]: body` — same shape as `computed`, side-effect only.
  wrapDepsForInnerNoName(bindSym"effectInner", deps, body)

# --- Introspection helper ---------------------------------------------------

macro bakedHeight*(b: typed): int =
  ## Read `b`'s baked `{.height.}` pragma at sem time as an int literal. `-1`
  ## if the binding has no pragma (i.e. it fell to the runtime tier). Used by
  ## tests to verify that the macros baked heights at compile time, not just
  ## computed them correctly at runtime.
  let h = heightOf(b)
  newLit(if h.isSome: h.get else: -1)
