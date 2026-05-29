## Static-tier reactive bindings — `computed` and `effect` with explicit deps.
##
## Each binding declares its dependencies syntactically in a bracket; heights
## compose at compile time over each dep's `{.height.}` pragma (see `height`);
## the resulting binding carries its own baked height for downstream
## composition. Under `-d:intonacoStrict` an unbaked dep is a hard compile
## error.
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
## Three stale-footgun patterns are rejected at sem time by the
## `noUndeclaredSignals` walker:
##   1. a `Signal[_]` / `Dynamic[_]` typed reference in the body (the dep
##      list omitted it),
##   2. a call to a helper with inferred `ReactiveRead` (a transitive read
##      not reflected in the brackets),
##   3. an opaque callee (`RootEffect` from method dispatch / async / FFI /
##      indirect call) — allowed only if the callee carries
##      `{.forbids: [ReactiveRead, ReactiveWrite].}`.
##
## The Lean over-approximation lemma (`overApproxSound`, proofs/Consistency.lean)
## says: when the classifier over-collects the read-set and dep heights are
## sound, the baked height dominates the true height. Under the explicit-deps
## shape, `readset ⊆ D` is **true by construction** — the dep list IS the
## read-set. The implication delivers unconditionally.

{.experimental: "callOperator".}

import std/[macros, options, effecttraits]
import ./signal
import ./subscribable
import ./scope
import ./height

export signal      # `Signal[T]`, `signal(...)`, `signals:`, `peek` — the
                   # user-facing static-tier surface composes on top of these
export height      # `heightOf` / `composeHeight` / `withHeight` — needed by
                   # the macros' generated code AND by `bakedHeight`'s callers

# --- Primitives -------------------------------------------------------------

proc maxDepHeight(deps: openArray[Subscribable]): int =
  for d in deps:
    if d.height + 1 > result: result = d.height + 1

proc computedC*[T](deps: openArray[Subscribable],
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
    let outSig = signal(body())
    outSig.height = h
    let comp = Computation(kind: ckComputed, height: h, heightFixed: true)
    comp.run = proc() =
      if comp.disposed: return
      outSig.set(body())
    for d in deps: subscribe(d, comp)
    if currentScope != nil:
      let captured = comp
      onCleanup proc() =
        captured.disposed = true
        unsubscribeAll(captured)
    outSig

proc effectC*(deps: openArray[Subscribable], body: proc() {.closure.},
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
    if currentScope != nil:
      let captured = comp
      onCleanup proc() =
        captured.disposed = true
        unsubscribeAll(captured)

# --- Ergonomic conversions --------------------------------------------------

converter toSubscribable*[T](s: Signal[T]): Subscribable = s.Subscribable
  ## Lets a `[count, doubled]` bracket of `Signal[T]` elements be passed where
  ## `openArray[Subscribable]` is expected.

proc depSymUnwrap*(n: NimNode): NimNode {.compileTime.} =
  ## Walk through implicit-conversion wrappers (`nnkHiddenCallConv` etc.) to
  ## the underlying sym. The macros need this because typed-arg sem inserts
  ## `Subscribable(x)` calls around each dep element.
  result = n
  while result.kind in {nnkHiddenCallConv, nnkHiddenStdConv, nnkConv} and
        result.len >= 2:
    result = result[1]

# --- The walker (rejects undeclared reactive reads at sem time) -------------

macro noUndeclaredSignals*(body: typed): untyped =
  ## Reject undeclared reactive reads in a `computed`/`effect` body — three
  ## patterns, all caught at sem time:
  ##
  ## 1. **Direct undeclared reactive read.** Any `nnkSym` whose instantiated
  ##    type is `Signal[_]` or `Dynamic[_]`. Declared deps were shadowed to
  ##    plain values before sem ran on the body, so any remaining reactive-
  ##    typed sym IS by construction an undeclared read.
  ## 2. **Transitive read via helper.** Any call whose callee has
  ##    `ReactiveRead` in its inferred tags (and isn't an untracked accessor
  ##    like `peek`). Nim's effect inference propagates `ReactiveRead`
  ##    through every helper that transitively reads via `Signal.get` /
  ##    `Dynamic.get`.
  ## 3. **Opaque callee.** Any call whose callee has `RootEffect` (method
  ##    dispatch / async / indirect proc-value / FFI without `effectsOf`).
  ##    A reactive read could hide inside; allowed only if the callee carries
  ##    `{.forbids: [ReactiveRead, ReactiveWrite].}`.
  ##
  ## Passthrough on success.
  const safeAccessors = ["peek"]
  const reactiveTypes = ["Signal", "Dynamic"]
  proc forbidsReactive(callee: NimNode): bool =
    if callee.kind != nnkSym: return false
    let impl = callee.getImpl
    if impl == nil or impl.kind notin {nnkProcDef, nnkFuncDef, nnkConverterDef}:
      return false
    for pr in impl.pragma:
      if pr.kind in {nnkExprColonExpr, nnkCall} and pr.len >= 2 and
         pr[0].eqIdent("forbids"):
        var r, w = false
        for e in pr[1]:
          if e.eqIdent("ReactiveRead"): r = true
          elif e.eqIdent("ReactiveWrite"): w = true
        if r and w: return true
    false
  proc walk(n: NimNode) =
    # Lambda / proc-literal bodies are deferred-execution context — their
    # reads run later, in a separate reactive frame (e.g. inside a
    # `runAfterPropagation` closure or a stored callback). Walker discipline
    # is "all reactive reads from the IMMEDIATE body must be declared." If
    # a user's helper needs reactive reads, they declare those in its own
    # binding's bracket. Skipping lambda descent here is what lets opaque-
    # but-non-reactive substrate work (mountWhen's `spawn` etc.) compose
    # cleanly through the deferred queue.
    if n.kind in {nnkLambda, nnkProcDef, nnkFuncDef, nnkDo}:
      return
    if n.kind == nnkSym:
      let t = n.getTypeInst
      if t != nil and t.kind == nnkBracketExpr and t.len >= 1 and
         t[0].repr in reactiveTypes:
        error("`" & n.repr & "`: reactive (" & t[0].repr & "[_]) read inside " &
              "a `computed`/`effect` body that isn't in the deps bracket. " &
              "Add it to the brackets or stop reading it.", n)
    if n.kind in {nnkCall, nnkCommand} and n.len >= 1 and n[0].kind == nnkSym:
      let callee = n[0]
      if callee.strVal notin safeAccessors:
        # Indirect call via proc-typed var/let/param: callee is a value sym,
        # not a proc sym. Treat as opaque — could dispatch to anything.
        if callee.symKind in {nskVar, nskLet, nskParam}:
          error("call to `" & callee.repr & "` is an indirect call through " &
                "a proc value — opaque to the classifier. A reactive read " &
                "could hide behind it. Move the call out of the binding " &
                "body, or call a concrete proc with a known effect set.", n)
        var seenReactive, seenRoot = false
        for tag in getTagsList(callee):
          if tag.repr == "ReactiveRead": seenReactive = true
          if tag.repr == "RootEffect": seenRoot = true
        if seenReactive:
          error("call to `" & callee.repr & "` transitively reads reactive " &
                "state (inferred `ReactiveRead`) but isn't reflected in the " &
                "deps bracket. Convert the helper to take values, or make " &
                "it its own `computed`.", n)
        if seenRoot and not forbidsReactive(callee):
          error("call to `" & callee.repr & "` is opaque (method dispatch / " &
                "async / FFI). A reactive read could hide inside; annotate " &
                "it `{.forbids: [ReactiveRead, ReactiveWrite].}` or move " &
                "the call out of the binding body.", n)
    for c in n: walk(c)
  walk(body)
  result = body

proc containsDepSym*(node: NimNode, depSyms: openArray[NimNode]): bool
    {.compileTime.} =
  ## True iff `node` (or any descendant) is identity-equal to one of `depSyms`.
  if node.kind == nnkSym:
    for d in depSyms:
      if node == d: return true
    return false
  for c in node:
    if containsDepSym(c, depSyms): return true
  false

proc rewriteDepRefs*(node: NimNode, depSyms: openArray[NimNode]): NimNode
    {.compileTime.} =
  ## Rewrite every reference inside `node` that resolves (via identity-equal
  ## `nnkSym` match) to one of the dep syms, replacing it with a fresh
  ## `nnkIdent` of the same name. The rewritten node is then re-typed in
  ## scope of the prepended `let dep = dep.peek()` shadows — so the body
  ## sees the peeked value, not the outer Signal.
  ##
  ## Without this, an `effect`/`computed` invoked through a template breaks:
  ## template substitution resolves the template's typed `Signal[T]` parameter
  ## to a sym IN the body AST, and the ident-based shadow can't shadow a
  ## typed sym. Hits the user as e.g. `if boolSig:` seeing Signal[bool]
  ## instead of bool in `mountWhen`-style wrappers.
  ##
  ## Identity comparison (`node == dep`) — NOT name comparison — so a body
  ## that legitimately introduces an unrelated local with the same name as
  ## a dep is left untouched.
  if node.kind == nnkSym:
    for dep in depSyms:
      if node == dep:
        return newIdentNode(node.strVal)
    return node
  if node.len == 0:
    return node
  # Fast path: if no descendant matches a dep sym, return the original
  # subtree untouched — preserves all semantic metadata for typed nodes
  # that came via template substitution. Only rebuild when a substitution
  # is actually needed.
  var needsRewrite = false
  for c in node:
    if containsDepSym(c, depSyms):
      needsRewrite = true
      break
  if not needsRewrite:
    return node
  result = node.copyNimNode()
  for c in node:
    result.add rewriteDepRefs(c, depSyms)

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
