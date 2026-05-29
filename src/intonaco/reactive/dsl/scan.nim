## `scan` — fold a collection's delta stream into derived state.
##
## A `CollectionSignal[T]` has two faces: its *value* (`c.get()` — the whole
## seq; integration) and its *delta stream* (`deltas(c)` — the typed changes;
## differentiation). `scan` consumes the delta face as a first-class reactive
## node: it subscribes to the stream (a real graph edge, so the dependency on
## `c` is compile-time-visible and height-ordered), and folds each typed delta
## into an accumulator — O(1) per delta, no whole-seq re-read.
##
## ## Shape
##
##   scan name, coll, [extraDeps], initial, step
##
## The `[extraDeps]` bracket is **mandatory** (use `[]` for no extra deps). It
## lists every Signal / Dynamic the step body reads beyond the delta arg, so
## the scan composes its height correctly (`max(coll.height+1, max(deps)+1)`)
## and so the walker can verify the step is otherwise pure. Inside the step
## body, the deps are shadowed as their peek'd values — `myWeight` in the
## body is `int`, not `Signal[int]`. The walker rejects any reactive read in
## the body that isn't covered by the bracket.
##
## Two-macro pattern (outer untyped → inner typed) so the shadow `let`s in the
## step body lexically precede the body's existing references, letting them
## resolve to the local value bindings instead of the outer Signal-typed syms.

{.experimental: "callOperator".}

import std/[macros, options]
import ../primitives/deltafloor   # deltas / foldDeltas — named by bindSym
import ../primitives/height
import ../primitives/subscribable # `Subscribable` — bindSym'd into the homogenization wrapping
import ../analysis/pass            # runAnalysis
import ../analysis/passes_core     # registers the three core walker passes
import ./kit                       # extractDepSyms — the kit's dep-extraction helper

macro scanInner(name: untyped, coll: typed, deps: typed,
                initial: typed, step: typed,
                origDeps: untyped): untyped =
  ## Inner typed-arg macro. Uses the kit's `extractDepSyms` for dep extraction;
  ## scan's height policy (1 + max(coll.height, max(deps.height))) is
  ## specialized so the kit's high-level orchestrator doesn't apply, but the
  ## helper is shared.
  let ch = heightOf(coll)
  if ch.isNone:
    error("scan: `" & coll.repr & "` has no compile-time height — declare " &
          "the collection via `collections:`", coll)
  var h = ch.get + 1
  for sym in extractDepSyms(deps):
    let dh = heightOf(sym)
    if dh.isNone:
      error("scan: dep `" & sym.repr & "` has no compile-time height — " &
            "declare the source via `signals:` / `collections:`", sym)
    if dh.get + 1 > h: h = dh.get + 1
  let hLit = newLit(h)
  let ctor = quote do:
    foldDeltas(deltas(`coll`), `initial`, `step`, fixedHeight = `hLit`)
  result = nnkLetSection.newTree(
    nnkIdentDefs.newTree(withHeight(name, h), newEmptyNode(), ctor))

macro scan*(name: untyped, coll: untyped, deps: untyped,
            initial: untyped, step: untyped): untyped =
  ## C-shape `scan name, coll, [deps], initial, step`. The deps bracket is
  ## mandatory (use `[]` for none). Walker enforces purity over anything in
  ## the step body not covered by `deps`.
  expectKind(deps, nnkBracket)
  expectKind(step, {nnkLambda, nnkProcDef, nnkFuncDef})
  # Build the shadow `let`s that prepend the step body so the body's existing
  # `dep` references can re-resolve to local value bindings. Fresh nnkIdents
  # on the LHS so Nim's "reintroduced symbol" check doesn't trip; RHS uses
  # the untyped dep ident which resolves to the outer Signal-typed sym.
  var shadows = newStmtList()
  for d in deps:
    let lhs = newIdentNode($d)
    shadows.add quote do:
      let `lhs` = `d`.peek()
  # Wrap the (already-shadowed) body in `noUndeclaredSignals` so the walker
  # fires at sem time on anything still reactive-typed (i.e. NOT declared in
  # the bracket).
  let origBody = step.body
  step.body = newStmtList()
  for s in shadows: step.body.add s
  step.body.add quote do:
    runAnalysis(`origBody`, `deps`)
  # Homogenize deps bracket for the inner typed-arg sem-check. `bindSym` ties
  # the name to scan.nim's import — emitted code resolves regardless of what
  # the consumer module imported.
  let subSym = bindSym"Subscribable"
  var wrappedDeps = nnkBracket.newTree()
  for d in deps:
    wrappedDeps.add nnkCall.newTree(subSym, d)
  result = quote do:
    scanInner(`name`, `coll`, `wrappedDeps`, `initial`, `step`, `deps`)
