## Compile-time height carrier (intonaco#51 / consistency RFC direction 1).
##
## Heights order the glitch-free scheduler: a node fires only after every
## lower-height dependency has settled. The runtime scheduler accumulates
## heights at subscribe time (`subscribable.subscribe`); this module is the
## *compile-time* carrier for the statically-resolvable fragment — a node's
## height is computed at its own macro expansion and baked onto its binding
## as a `{.height: N.}` pragma, so a later (even cross-module) expansion that
## depends on it reads the height back without any runtime bookkeeping.
##
## Three primitives, all `{.compileTime.}`:
##
## - `heightOf(sym)`  — read the baked height. PARTIAL: `none` means "not in
##   the static fragment" (no pragma) — a dependent MUST then fall to the
##   runtime tier, never assume 0 (a false 0 bakes a too-low height and
##   silently reintroduces the glitch the scheduler exists to prevent).
## - `composeHeight(deps)` — `1 + max` over dependency heights, propagating
##   `none` if ANY dependency is unresolvable. Matches the runtime floor's
##   accumulation `max({0} ∪ {h_dep + 1})` so the static and dynamic tiers
##   agree (the cross-tier monotonicity invariant, Lemma B).
## - `withHeight(name, h)` — bake a height onto a binding name (the inverse of
##   `heightOf`).

import std/[macros, options]

template height*(n: int) {.pragma.}
  ## The carrier: `{.height: N.}` on a reactive binding. Read back via
  ## `heightOf` (getImpl + eqIdent — NOT getCustomPragmaVal, which silently
  ## fails when the symbol arrives through a macro's typed parameter).

proc heightOf*(sym: NimNode): Option[int] {.compileTime.} =
  ## `Some(N)` if `sym`'s binding carries `{.height: N.}`, else `none`.
  ## Reads `getImpl(sym)` (an `nnkIdentDefs`) and walks its pragma list with
  ## `eqIdent` — deliberately NOT `getCustomPragmaVal`, which re-resolves the
  ## pragma symbol in the reading macro's scope and returns nil across the
  ## typed-param boundary.
  let impl = sym.getImpl
  if impl == nil or impl.kind != nnkIdentDefs or impl.len == 0: return
  let nameNode = impl[0]
  if nameNode.kind != nnkPragmaExpr: return
  for p in nameNode[1]:
    if p.kind in {nnkExprColonExpr, nnkCall} and p.len >= 2 and
       p[0].eqIdent("height"):
      return some(p[1].intVal.int)

proc composeHeight*(deps: openArray[NimNode]): Option[int] {.compileTime.} =
  ## `Some(max({0} ∪ {h+1 | dep height h}))` iff EVERY dep resolves; `none` if
  ## any dep is unresolvable. The `none`-propagation is the soundness rule: an
  ## unresolvable dependency must force the dependent out of the static
  ## fragment, never silently contribute a `0` (a too-low height = a glitch).
  ## Empty deps → `Some(0)` (a constant / source-equivalent leaf).
  var m = 0
  for d in deps:
    let h = heightOf(d)
    if h.isNone: return none(int)
    if h.get + 1 > m: m = h.get + 1
  some(m)

proc withHeight*(name: NimNode, h: int): NimNode {.compileTime.} =
  ## Wrap an identdef name in `{.height: h.}` (an `nnkPragmaExpr`) so the
  ## emitted binding carries the height for later `heightOf` reads. The inverse
  ## of `heightOf`. `bindSym"height"` binds the pragma to this module's symbol,
  ## so the emitted code needs no particular import in scope.
  nnkPragmaExpr.newTree(
    name,
    nnkPragma.newTree(
      nnkExprColonExpr.newTree(bindSym"height", newLit(h))))
