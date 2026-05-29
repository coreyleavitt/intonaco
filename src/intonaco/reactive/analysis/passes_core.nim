## Core walker passes — the three checks the C-shape walker has shipped
## with since intonaco's substrate migration. Ported here from the old
## monolithic `noUndeclaredSignals` macro as three independent registered
## passes.
##
## Importing this module registers all three. Default-binding macros
## (`dsl/binding.nim`, `dsl/scan.nim`, `dsl/derive.nim`) import this file so
## consumers get the core discipline automatically.
##
## Research-direction modules import only `pass.nim` and register their own
## additional passes (refinement, substructural, transactions, guarded
## productivity).
##
## The three passes:
##
## - **NoUndeclaredSignalReadPass**: any nnkSym whose instantiated type is
##   `Signal[_]` or `Dynamic[_]` is an undeclared dep read — declared deps
##   were shadowed to peek-values before sem ran on the body, so a reactive-
##   typed sym remaining in the body IS by construction unbracketed.
##
## - **NoUndeclaredTransitiveReadPass**: any call whose callee carries
##   `ReactiveRead` in its inferred tags (and isn't an untracked accessor
##   like `peek`) reads reactive state indirectly. Forces the helper to be
##   pushed into its own `computed` or to take values not signals.
##
## - **NoOpaqueCalleePass**: any call whose callee has `RootEffect` (method
##   dispatch / async / FFI without `effectsOf`) or whose callee is a proc
##   value (`nskVar`/`nskLet`/`nskParam`) is opaque to the classifier. A
##   reactive read could hide inside. Allowed only with
##   `{.forbids: [ReactiveRead, ReactiveWrite].}` annotation.

import std/[macros, effecttraits]
import ./pass
import ./diagnostic

const safeAccessors = ["peek"]
const reactiveTypes = ["Signal", "Dynamic"]

proc forbidsReactive(callee: NimNode): bool {.compileTime.} =
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

# ---- Pass 1: direct reactive-typed reads -----------------------------------

proc noUndeclaredSignalReadPass*(node: NimNode, ctx: WalkContext): seq[Finding]
                                {.nimcall.} =
  if node.kind != nnkSym: return
  let t = node.getTypeInst
  if t != nil and t.kind == nnkBracketExpr and t.len >= 1 and
     t[0].repr in reactiveTypes:
    result.add Finding(
      severity: sevError,
      message: "`" & node.repr & "`: reactive (" & t[0].repr & "[_]) read " &
               "inside a `computed`/`effect` body that isn't in the deps " &
               "bracket. Add it to the brackets or stop reading it.",
      site: node,
      rule: gtValueRule)

static: registerWalkPass(noUndeclaredSignalReadPass)

# ---- Pass 2: transitive reactive read via helper ---------------------------

proc noUndeclaredTransitiveReadPass*(node: NimNode, ctx: WalkContext):
    seq[Finding] {.nimcall.} =
  if node.kind notin {nnkCall, nnkCommand} or node.len < 1: return
  let callee = node[0]
  if callee.kind != nnkSym: return
  if callee.strVal in safeAccessors: return
  if callee.symKind in {nskVar, nskLet, nskParam}:
    return  # handled by NoOpaqueCalleePass — indirect call
  for tag in getTagsList(callee):
    if tag.repr == "ReactiveRead":
      result.add Finding(
        severity: sevError,
        message: "call to `" & callee.repr & "` transitively reads reactive " &
                 "state (inferred `ReactiveRead`) but isn't reflected in the " &
                 "deps bracket. Convert the helper to take values, or make " &
                 "it its own `computed`.",
        site: node,
        rule: gtValueRule)
      return

static: registerWalkPass(noUndeclaredTransitiveReadPass)

# ---- Pass 3: opaque callee (RootEffect or indirect proc value) -------------

proc noOpaqueCalleePass*(node: NimNode, ctx: WalkContext): seq[Finding]
                       {.nimcall.} =
  if node.kind notin {nnkCall, nnkCommand} or node.len < 1: return
  let callee = node[0]
  if callee.kind != nnkSym: return
  if callee.strVal in safeAccessors: return
  if callee.symKind in {nskVar, nskLet, nskParam}:
    result.add Finding(
      severity: sevError,
      message: "call to `" & callee.repr & "` is an indirect call through " &
               "a proc value — opaque to the classifier. A reactive read " &
               "could hide behind it. Move the call out of the binding " &
               "body, or call a concrete proc with a known effect set.",
      site: node,
      rule: gtRuntimeScheduled)
    return
  var seenRoot = false
  for tag in getTagsList(callee):
    if tag.repr == "RootEffect": seenRoot = true
  if seenRoot and not forbidsReactive(callee):
    result.add Finding(
      severity: sevError,
      message: "call to `" & callee.repr & "` is opaque (method dispatch / " &
               "async / FFI). A reactive read could hide inside; annotate " &
               "it `{.forbids: [ReactiveRead, ReactiveWrite].}` or move " &
               "the call out of the binding body.",
      site: node,
      rule: gtRuntimeScheduled)

static: registerWalkPass(noOpaqueCalleePass)
