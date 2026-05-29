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
import ../analysis/walker
import ../analysis/ast

export signal      # `Signal[T]`, `signal(...)`, `signals:`, `peek` — the
                   # user-facing static-tier surface composes on top of these
export height      # `heightOf` / `composeHeight` / `withHeight` — needed by
                   # the macros' generated code AND by `bakedHeight`'s callers

# --- The macros (sugar over the primitives + walker + height bake) ----------

macro computedInner(name: untyped, deps: typed, body: untyped,
                    origDeps: untyped): untyped =
  ## Inner typed-arg macro for `computed`. `deps` arrives as a typed bracket
  ## of `Subscribable(<sym>)` calls (homogenized by the outer wrapper); we
  ## unwrap each to the original sym for `heightOf`, compose at compile time,
  ## bake the result onto `name`.
  var depSyms: seq[NimNode]
  var shadows = newStmtList()
  for d in deps:
    var sym = d
    if sym.kind in {nnkCall, nnkHiddenCallConv, nnkHiddenStdConv, nnkConv} and
       sym.len >= 2:
      sym = sym[^1]
    sym = depSymUnwrap(sym)
    depSyms.add sym
    let lhs = newIdentNode(if sym.kind == nnkSym: sym.strVal else: $sym)
    shadows.add quote do:
      let `lhs` = `sym`.peek()
  # Rewrite dep-sym references in the body to fresh idents — required for
  # bodies arriving via template substitution (the template parameter sym
  # ends up in the body AST and the ident-shadow doesn't shadow already-
  # typed syms). See `rewriteDepRefs` for the rationale.
  let bodyRewritten = rewriteDepRefs(body, depSyms)
  # Wrap ONLY the user's body in `noUndeclaredSignals` — not the shadows
  # (their `let x = x.peek()` legitimately reads the outer Signal once).
  let bodyChecked = quote do:
    noUndeclaredSignals(`bodyRewritten`)
  var bodyOut = newStmtList()
  for s in shadows: bodyOut.add s
  bodyOut.add bodyChecked
  let staticH = composeHeight(depSyms)
  if staticH.isSome:
    let h = staticH.get
    let hLit = newLit(h)
    let ctor = quote do:
      computedC(`deps`, proc(): auto = `bodyOut`, fixedHeight = `hLit`)
    result = nnkLetSection.newTree(
      nnkIdentDefs.newTree(withHeight(name, h), newEmptyNode(), ctor))
  else:
    if defined(intonacoStrict):
      error("computed: at least one dep has no resolvable compile-time " &
            "height — declare the source via `signals:` or wrap the read " &
            "in `dynamic:`", origDeps)
    result = quote do:
      let `name` = computedC(`deps`, proc(): auto = `bodyOut`)

macro computed*(name: untyped, deps: untyped, body: untyped): untyped =
  ## `computed name, [d1, d2, ...]: body`. Two-macro pattern: outer untyped
  ## wraps each dep with `Subscribable(...)` (homogenizes the array so Nim's
  ## type-unification doesn't reject mixed `Signal[T]` element types), inner
  ## typed (`computedInner`) resolves heights at compile time and bakes the
  ## resulting `{.height.}` pragma onto `name`.
  expectKind(deps, nnkBracket)
  var wrapped = nnkBracket.newTree()
  for d in deps:
    wrapped.add quote do: Subscribable(`d`)
  result = quote do:
    computedInner(`name`, `wrapped`, `body`, `deps`)

macro effectInner(deps: typed, body: untyped, origDeps: untyped): untyped =
  ## Inner typed-arg macro for `effect`. Same shape as `computedInner`, no
  ## output binding.
  var depSyms: seq[NimNode]
  var shadows = newStmtList()
  for d in deps:
    var sym = d
    if sym.kind in {nnkCall, nnkHiddenCallConv, nnkHiddenStdConv, nnkConv} and
       sym.len >= 2:
      sym = sym[^1]
    sym = depSymUnwrap(sym)
    depSyms.add sym
    let lhs = newIdentNode(if sym.kind == nnkSym: sym.strVal else: $sym)
    shadows.add quote do:
      let `lhs` = `sym`.peek()
  # See `rewriteDepRefs` rationale in computedInner.
  let bodyRewritten = rewriteDepRefs(body, depSyms)
  let bodyChecked = quote do:
    noUndeclaredSignals(`bodyRewritten`)
  var bodyOut = newStmtList()
  for s in shadows: bodyOut.add s
  bodyOut.add bodyChecked
  let staticH = composeHeight(depSyms)
  if staticH.isSome:
    let hLit = newLit(staticH.get)
    result = quote do:
      effectC(`deps`, proc() = `bodyOut`, fixedHeight = `hLit`)
  else:
    if defined(intonacoStrict):
      error("effect: at least one dep has no resolvable compile-time " &
            "height — declare the source via `signals:` or wrap the read " &
            "in `dynamic:`", origDeps)
    result = quote do:
      effectC(`deps`, proc() = `bodyOut`)

macro effect*(deps: untyped, body: untyped): untyped =
  ## `effect [d1, d2, ...]: body` — same shape as `computed`, side-effect
  ## only (no output binding).
  expectKind(deps, nnkBracket)
  var wrapped = nnkBracket.newTree()
  for d in deps:
    wrapped.add quote do: Subscribable(`d`)
  result = quote do:
    effectInner(`wrapped`, `body`, `deps`)

# --- Introspection helper ---------------------------------------------------

macro bakedHeight*(b: typed): int =
  ## Read `b`'s baked `{.height.}` pragma at sem time as an int literal. `-1`
  ## if the binding has no pragma (i.e. it fell to the runtime tier). Used by
  ## tests to verify that the macros baked heights at compile time, not just
  ## computed them correctly at runtime.
  let h = heightOf(b)
  newLit(if h.isSome: h.get else: -1)
