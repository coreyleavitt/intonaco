## Substrate-template authoring kit — M-α.3.
##
## The kit extracts the orchestration that's duplicated across the substrate's
## DSL macros (`binding.nim`, `scan.nim`, `derive.nim`) so future substrate
## templates — sinopia's tracing bindings, per-direction modality macros
## (refinement / substructural / transactions / guarded), domain-specific
## sugar — can be built without re-implementing the substrate plumbing.
##
## Two layers of API:
##
## ### High-level orchestrator (for computed/effect-shape templates)
##
##   `compileBindingInner(name, deps, body, origDeps, primitive, emission, strictKind)`
##   collapses the ~30-line inner-typed-macro pattern to one call. A new
##   substrate template family is ~7 lines:
##
##     macro tracedInner(name: untyped, deps: typed, body: untyped, origDeps: untyped): untyped =
##       compileBindingInner(name, deps, body, origDeps,
##                           bindSym"tracedC", ekComputedShape, "traced")
##     macro traced*(name, deps, body): untyped =
##       wrapDepsForInner(bindSym"tracedInner", name, deps, body)
##
## ### Low-level helpers (for specialized templates: scan, derive, etc.)
##
##   `extractDepSyms`, `buildShadowLets`, `rewriteAndAnalyze` are exposed for
##   templates whose height policy or dep structure differs from the
##   computed/effect default. scan.nim and derive.nim use these directly.

                                  # in `buildShadowLets` resolves `peek` against
                                  # this module's scope (where it's unambiguous),
                                  # not the consumer call-site (where chronos's
                                  # `peek(Channel)` may also be visible and
                                  # shadow under generic instantiation).

type EmissionKind* = enum
  ekComputedShape   ## `let name {.height: H.} = primitive(deps, proc(): auto = bodyOut, fixedHeight=H)`
  ekEffectShape     ## `primitive(deps, proc() = bodyOut, fixedHeight=H)` (no name, no withHeight)

# --- Low-level helpers ------------------------------------------------------

proc extractDepSyms*(deps: NimNode): seq[NimNode] {.compileTime.} =
  ## Walk a typed bracket of `Subscribable(<sym>)` calls; unwrap through
  ## implicit-conversion wrappers; return the dep syms in declared order.
  for d in deps:
    var sym = d
    if sym.kind in {nnkCall, nnkHiddenCallConv, nnkHiddenStdConv, nnkConv} and
       sym.len >= 2:
      sym = sym[^1]
    sym = depSymUnwrap(sym)
    result.add sym

proc buildShadowLets*(depSyms: seq[NimNode]): NimNode {.compileTime.} =
  ## Emit `let dep = dep.peek()` for each dep, returning the StmtList.
  result = newStmtList()
  for sym in depSyms:
    let lhs = newIdentNode(if sym.kind == nnkSym: sym.strVal else: $sym)
    result.add quote do:
      let `lhs` = `sym`.peek()

proc rewriteAndAnalyze*(body: NimNode, depSyms: seq[NimNode],
                        depsBracket: NimNode): NimNode {.compileTime.} =
  ## rewriteDepRefs(body) + wrap result in runAnalysis(rewritten, depsBracket).
  ## The two steps that ALL binding-shape macros must do at the same point.
  let rewritten = rewriteDepRefs(body, depSyms)
  result = quote do:
    runAnalysis(`rewritten`, `depsBracket`)

# --- High-level orchestrator ------------------------------------------------

proc compileBindingInner*(
    name: NimNode,
    deps: NimNode,
    body: NimNode,
    origDeps: NimNode,
    primitive: NimNode,
    emission: EmissionKind,
    strictKind: string
  ): NimNode {.compileTime.} =
  ## The orchestration that was duplicated in computedInner/effectInner. Use
  ## from the inner-typed macro of a two-macro pattern.
  ##
  ## - `name`: binding name (for ekComputedShape); ignored for ekEffectShape
  ## - `deps`: typed Subscribable-wrapped bracket from the outer macro
  ## - `body`: user's untyped body
  ## - `origDeps`: original untyped deps bracket — for strict-mode error site
  ## - `primitive`: bindSym of the runtime primitive (computedC, effectC, ...)
  ## - `emission`: which shape (computed-shape baked-let vs effect-shape call)
  ## - `strictKind`: keyword for the strict-mode error message ("computed", "effect")
  let depSyms = extractDepSyms(deps)
  let shadows = buildShadowLets(depSyms)
  let analyzed = rewriteAndAnalyze(body, depSyms, deps)
  var bodyOut = newStmtList()
  for s in shadows: bodyOut.add s
  bodyOut.add analyzed
  let staticH = composeHeight(depSyms)
  case emission
  of ekComputedShape:
    if staticH.isSome:
      let h = staticH.get
      let hLit = newLit(h)
      let ctor = quote do:
        `primitive`(`deps`, proc(): auto = `bodyOut`, fixedHeight = `hLit`)
      result = nnkLetSection.newTree(
        nnkIdentDefs.newTree(withHeight(name, h), newEmptyNode(), ctor))
    else:
      error(strictKind & ": at least one dep has no resolvable compile-time " &
            "height — declare the source via `signals:` / `collections:`, or " &
            "wrap the read in `dynamic name: body` for the ◇-modality " &
            "escape", origDeps)
  of ekEffectShape:
    if staticH.isSome:
      let hLit = newLit(staticH.get)
      result = quote do:
        `primitive`(`deps`, proc() = `bodyOut`, fixedHeight = `hLit`)
    else:
      error(strictKind & ": at least one dep has no resolvable compile-time " &
            "height — declare the source via `signals:` / `collections:`, or " &
            "wrap the read in `dynamic name: body` for the ◇-modality " &
            "escape", origDeps)

proc wrapDepsForInner*(innerSym: NimNode, name, deps, body: NimNode):
    NimNode {.compileTime.} =
  ## Outer-untyped-macro helper: wrap each dep in `Subscribable(...)` to
  ## homogenize the bracket for the inner typed macro's sem check, then emit
  ## the inner-typed-macro call.
  ##
  ## Use from the OUTER macro of a two-macro pattern.
  expectKind(deps, nnkBracket)
  let subSym = bindSym("Subscribable")
  var wrapped = nnkBracket.newTree()
  for d in deps:
    wrapped.add nnkCall.newTree(subSym, d)
  result = quote do:
    `innerSym`(`name`, `wrapped`, `body`, `deps`)

proc wrapDepsForInnerNoName*(innerSym: NimNode, deps, body: NimNode):
    NimNode {.compileTime.} =
  ## Variant of `wrapDepsForInner` for effect-shape templates (no name).
  expectKind(deps, nnkBracket)
  let subSym = bindSym("Subscribable")
  var wrapped = nnkBracket.newTree()
  for d in deps:
    wrapped.add nnkCall.newTree(subSym, d)
  result = quote do:
    `innerSym`(`wrapped`, `body`, `deps`)
