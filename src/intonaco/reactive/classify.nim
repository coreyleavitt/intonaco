## Reactive-body classifier (intonaco#52 / consistency RFC direction 1).
##
## Decides whether a reactive body can be scheduled at compile time (STATIC,
## with a resolved height) or must fall to the sound runtime tier (DYNAMIC,
## with a reason). It composes the pieces:
##
##   - read DETECTION (which directly-named signals does the body read) — a
##     callee-based AST walk (a read is a call to the `()`/`get` accessor;
##     `peek` is untracked and excluded). NOT keyed on "first arg is signal-
##     typed", which false-matches any helper taking a signal.
##   - the OPACITY GATE — the #50 purity oracle: a call the compiler punted on
##     (method/async/indirect → `reactiveEffects.opaque`) or an FFI binding
##     `getTagsList` is blind to (`opaqueReactiveCalls`) could hide a read of
##     unknown height → DYNAMIC.
##   - HEIGHT RESOLUTION — #51 `composeHeight`/`heightOf` over the collected
##     deps; an unbaked dep makes `composeHeight` `none` → DYNAMIC (the
##     downward-closure that secures cross-tier soundness, Lemma B).
##
## v1 is BAIL-FIRST: any call that transitively reads a signal (other than a
## direct accessor at the callsite) → DYNAMIC. The larger static fragment
## (descend-and-collect) is the measurement-gated enhancement #57.
##
## SOUNDNESS is the spec: over-approximation (e.g. both arms of an `if`) is
## mandatory and safe; under-approximation (a missed read → too-low height) is
## a glitch. The dangerous reads — runtime-keyed, hidden, opaque, unbaked —
## must NEVER classify static.

import std/[macros, options]
import ./height
import ./purity

type
  Tier* = enum tStatic, tDynamic

  DynReasonKind* = enum
    ## WHY a body falls to the runtime tier — a structured verdict, NOT prose.
    ## Developer-facing phrasing lives in the Diagnostic layer (construct's
    ## `dynReasonSymptom`), the single place it can be audited against the
    ## `verification` internal-vocabulary contract.
    drRuntimeKeyed     ## reads a signal chosen at runtime (e.g. `sigs[i]()`)
    drHiddenRead       ## a call transitively reads a signal not passed to it
    drOpaque           ## a call the compiler can't see into (method/async/indirect)
    drForeign          ## an FFI binding that could read a signal through a callback
    drUnscheduledDep   ## depends on a value not resolved at compile time
    drExplicit         ## explicitly marked `dynamic:` (the escape hatch)

  DynReason* = object
    kind*: DynReasonKind
    callee*: string      ## the offending call's name where applicable, else ""

  Classification* = object
    case tier*: Tier
    of tStatic:  height*: int
    of tDynamic: reason*: DynReason

proc isSignalTy(node: NimNode): bool {.compileTime.} =
  if node == nil or node.kind in {nnkEmpty, nnkNilLit}: return false
  let typ = node.getTypeInst
  typ != nil and typ.kind == nnkBracketExpr and typ.len >= 1 and
    typ[0].repr == "Signal"

proc isSignalRead(n: NimNode): bool {.compileTime.} =
  ## A tracked read: a call to the accessor `()`/`get` on a signal — keyed on
  ## the CALLEE, not the arg type. `peek` is excluded (untracked, no dep).
  n.kind in {nnkCall, nnkCommand} and n.len == 2 and n[0].kind == nnkSym and
    n[0].repr in ["()", "get"] and isSignalTy(n[1])

proc isRoutineCall(n: NimNode): bool {.compileTime.} =
  n.kind in {nnkCall, nnkCommand} and n.len >= 1 and n[0].kind == nnkSym

proc classify*(body: NimNode, strict = false): Classification {.compileTime.} =
  # FFI gate (#50): an `importc` binding `getTagsList` is blind to (returns
  # @[], so neither the `opaque` flag nor `reReads` catches it) could read a
  # signal through a callback. `opaqueReactiveCalls` flags those structurally.
  let ffi = opaqueReactiveCalls(body, strict)
  if ffi.len > 0:
    let callee = if ffi[0].node.kind in {nnkCall, nnkCommand} and
                    ffi[0].node.len >= 1: ffi[0].node[0].repr else: ""
    return Classification(tier: tDynamic,
      reason: DynReason(kind: drForeign, callee: callee))
  var deps: seq[NimNode]
  var dyn = false
  var reason: DynReason
  proc walk(n: NimNode) =
    if dyn: return
    if isSignalRead(n):
      let recv = n[1]
      if recv.kind == nnkSym: deps.add recv          # directly-named -> resolvable
      else: dyn = true; reason = DynReason(kind: drRuntimeKeyed)  # sigs[i](), alias
      for c in n: walk(c)                            # args are values; may read
      return
    if isRoutineCall(n):
      let eff = reactiveEffects(n[0])
      # Opacity gate (#50): the compiler punted on this call (method dispatch /
      # async body / indirect proc value -> bare RootEffect), so a read of
      # unknown height could be hidden behind it.
      if eff.opaque:
        dyn = true
        reason = DynReason(kind: drOpaque, callee: n[0].repr)
        return
      # bail-first (#57 is the descend-and-collect enhancement): a call that
      # transitively reads a signal — other than the accessor handled above —
      # could read one whose height we can't account for here.
      if reReads in eff.effects:
        dyn = true
        reason = DynReason(kind: drHiddenRead, callee: n[0].repr)
        return
      for c in n: walk(c)                            # pure call: args may read
      return
    for c in n: walk(c)
  walk(body)
  if dyn: return Classification(tier: tDynamic, reason: reason)
  let h = composeHeight(deps)
  if h.isSome: Classification(tier: tStatic, height: h.get)
  else: Classification(tier: tDynamic, reason: DynReason(kind: drUnscheduledDep))
