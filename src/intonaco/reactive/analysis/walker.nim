## The C-shape walker: `noUndeclaredSignals`.
##
## Rejects undeclared reactive reads in a `computed`/`effect` body at sem time.
## Three patterns are checked:
##
## 1. **Direct undeclared reactive read.** Any `nnkSym` whose instantiated type
##    is `Signal[_]` or `Dynamic[_]`. Declared deps were shadowed to plain values
##    before sem ran on the body, so any remaining reactive-typed sym IS by
##    construction an undeclared read.
##
## 2. **Transitive read via helper.** Any call whose callee has `ReactiveRead`
##    in its inferred tags (and isn't an untracked accessor like `peek`). Nim's
##    effect inference propagates `ReactiveRead` through every helper that
##    transitively reads via `Signal.get` / `Dynamic.get`.
##
## 3. **Opaque callee.** Any call whose callee has `RootEffect` (method
##    dispatch / async / indirect proc-value / FFI without `effectsOf`). A
##    reactive read could hide inside; allowed only if the callee carries
##    `{.forbids: [ReactiveRead, ReactiveWrite].}`.
##
## Lambda / proc-literal bodies are NOT descended into — their reads run in a
## separate reactive frame (deferred callbacks, stored handlers, post-settle
## actions). The walker discipline is "all reactive reads from the IMMEDIATE
## body must be declared"; deferred bodies declare their own deps when they
## become bindings.
##
## Passthrough on success.
##
## **Extension point (M-α.2)**: today this is a single monolithic walk with
## three hardcoded checks. The pass-registry milestone replaces this with a
## pluggable `WalkPass` interface; each of the three checks becomes a
## pre-registered pass, and research directions register additional passes
## without touching this file.

import std/[macros, effecttraits]

macro noUndeclaredSignals*(body: typed): untyped =
  ## See module docstring.
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
