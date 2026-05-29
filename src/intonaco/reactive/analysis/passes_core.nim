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
const reactiveTypes = ["Signal", "Dynamic", "DynamicCollection"]
  ## Types whose undeclared read inside a static binding body is a
  ## walker error. `DynamicCollection` added at M-δ for modal symmetry
  ## with `Dynamic`: a ◇-typed value (collection or scalar) cannot
  ## appear in a □-typed binding without an explicit modality cast.
  ## `CollectionSignal` is deliberately excluded — its reads are
  ## expected to flow through `derive`/`keep`/`fold`/`scan` macros, not
  ## raw binding bodies, but raw reads aren't rejected today (a
  ## separate gap not in M-δ scope).

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
      rule: gtRuntimeScheduled,
      subject: SignalId(node.repr),
      symptom: "reactive read inside a binding body that isn't in the deps bracket",
      fix: "add `" & node.repr & "` to the deps bracket or stop reading it",
      site: node)

registerWalkPass(noUndeclaredSignalReadPass)

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
        rule: gtRuntimeScheduled,
        subject: SignalId(callee.repr),
        symptom: "the call transitively reads reactive state but isn't " &
                 "reflected in the deps bracket",
        fix: "convert the helper to take values, or make it its own `computed`",
        site: node)
      return

registerWalkPass(noUndeclaredTransitiveReadPass)

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
      rule: gtRuntimeScheduled,
      subject: SignalId(callee.repr),
      symptom: "indirect call through a proc value — a reactive read could " &
               "hide behind it",
      fix: "use a concrete proc with a known effect set, or move the call " &
           "out of the binding body",
      site: node)
    return
  var seenRoot = false
  for tag in getTagsList(callee):
    if tag.repr == "RootEffect": seenRoot = true
  if seenRoot and not forbidsReactive(callee):
    result.add Finding(
      severity: sevError,
      rule: gtRuntimeScheduled,
      subject: SignalId(callee.repr),
      symptom: "opaque call (async / dispatch / FFI) — a reactive read " &
               "could hide inside",
      fix: "annotate the callee `{.forbids: [ReactiveRead, ReactiveWrite].}` " &
           "or move the call out of the binding body",
      site: node)

registerWalkPass(noOpaqueCalleePass)
