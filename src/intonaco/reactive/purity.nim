## Reactive-effect analysis (intonaco#50 / consistency RFC direction 1).
##
## Two primitives, by the soundness boundary of `std/effecttraits`:
##
## - `reactiveEffects(procOrBody)` — the transitive reactive-effect set, via
##   `getTagsList`. Sound, transitive, and `effectsOf`-complete *because it is
##   queried at the granularity of the whole proc/body* (an `effectsOf` read
##   is callsite-dependent and invisible on a bare callee — so the classifier
##   queries the body, not per-call).
##
## - `opaqueReactiveCalls(body)` — the AST audit for what `getTagsList` reports
##   as `@[]` but *cannot actually see through*: unannotated-callback FFI and
##   indirect proc-value calls. These are the cases where `reactiveEffects`
##   might under-report. The classifier trusts `reactiveEffects` iff this is
##   empty; otherwise it forces annotation / `dynamic:`.
##
## Analysis only — *policy* lives in the classifier that consumes this.

import std/[macros, effecttraits]
import ./signal   # SignalRead / SignalWrite tags

type
  ReactiveEffect* = enum
    reReads   ## transitively reads a signal (SignalRead)
    reWrites  ## transitively writes a signal (SignalWrite)

  Reactivity* = object
    effects*: set[ReactiveEffect]  ## specific reactive effects (sound when not opaque)
    opaque*: bool                  ## compiler punted (bare RootEffect): a method
                                   ## dispatch / async body / indirect call hid an
                                   ## effect. `effects` may under-report — don't trust.

  OpaqueCall* = object
    ## An FFI call site `getTagsList` reports as `@[]` (blind to the C body),
    ## so it shows neither a specific effect nor `RootEffect`. The lone opacity
    ## the `opaque` flag can't catch — detected structurally instead.
    node*: NimNode
    reason*: string

proc reactiveEffects*(n: NimNode): Reactivity {.compileTime.} =
  ## Reactive-effect profile of proc/body `n`, from the compiler's inferred
  ## `tags`. Transitive and `effectsOf`-aware via effecttraits — provided `n`
  ## is the whole proc/body (not a bare callee). A bare `RootEffect` means the
  ## compiler couldn't resolve some call (dynamic dispatch, async, indirect) →
  ## `opaque`. (`set` is firewalled so it does NOT leak `RootEffect`; bare
  ## RootEffect therefore reliably means "punted", not "wrote a signal".)
  for t in getTagsList(n):
    case t.repr
    of "SignalRead": result.effects.incl reReads
    of "SignalWrite": result.effects.incl reWrites
    of "RootEffect": result.opaque = true
    else: discard

proc forbidsReactive(impl: NimNode): bool {.compileTime.} =
  ## True if the routine declares `{.forbids: [...].}` listing both SignalRead
  ## and SignalWrite — a developer-vouched "touches no signal" contract. On an
  ## `importc` proc this is unverifiable (the C body is invisible) but it's an
  ## explicit, greppable promise the classifier can trust, expressed in the
  ## same effect vocabulary as the read/write levers.
  for pr in impl.pragma:
    if pr.kind in {nnkExprColonExpr, nnkCall} and pr.len >= 2 and
       pr[0].eqIdent("forbids"):
      var hasR, hasW = false
      for e in pr[1]:
        if e.eqIdent("SignalRead"): hasR = true
        elif e.eqIdent("SignalWrite"): hasW = true
      if hasR and hasW: return true
  false

proc ffiOpacity(callee: NimNode, strict: bool): (bool, string) {.compileTime.} =
  ## `getTagsList` is blind to `importc` C bodies (returns `@[]`), so FFI is the
  ## one opacity the `opaque` flag can't see. An FFI call is trustworthy only
  ## via an explicit reactive contract on the binding:
  ##   - callback param  -> needs `{.effectsOf: cb.}` (propagates the callback's
  ##     reads). Without it: flagged ALWAYS — the realistic "C reaches a signal
  ##     through a Nim callback" path.
  ##   - no callback     -> can reach a signal only via a hardcoded Nim
  ##     `exportc` reader (exotic). Trusted by default; under `strict`, must
  ##     carry `{.forbids: [SignalRead, SignalWrite].}` to stay in the static
  ##     fragment.
  if callee.kind != nnkSym: return (false, "")
  let impl = callee.getImpl
  if impl.kind notin {nnkProcDef, nnkFuncDef, nnkConverterDef}: return (false, "")
  var isImportc, hasEffectsOf, hasCallback = false
  for pr in impl.pragma:
    let nm = if pr.kind in {nnkExprColonExpr, nnkCall}: pr[0] else: pr
    if nm.eqIdent("importc"): isImportc = true
    elif nm.eqIdent("effectsOf"): hasEffectsOf = true
  if not isImportc: return (false, "")
  for i in 1 ..< impl.params.len:
    if impl.params[i][^2].kind == nnkProcTy: hasCallback = true
  if hasCallback:
    if hasEffectsOf: return (false, "")
    return (true, "FFI binding `" & callee.repr &
      "` takes a callback but lacks {.effectsOf.} — can't prove it doesn't " &
      "read/write a signal through it")
  if forbidsReactive(impl): return (false, "")           # vouched pure
  if strict:
    return (true, "FFI binding `" & callee.repr &
      "` has no reactive contract; under -d:intonacoStrict, annotate it " &
      "{.forbids: [SignalRead, SignalWrite].} or wrap the call in dynamic:")
  (false, "")                                            # non-strict trusts it

proc opaqueReactiveCalls*(body: NimNode, strict = false): seq[OpaqueCall]
    {.compileTime.} =
  ## Walk `body` for the one opacity `reactiveEffects.opaque` can't catch: FFI
  ## (`getTagsList` is blind to C bodies). Indirect calls, dynamic-dispatch
  ## methods, and async bodies all surface as `RootEffect` and are caught by
  ## the `opaque` flag instead. A body is trustworthy iff `not opaque` AND this
  ## is empty. `strict` (← `defined(intonacoStrict)`) forces a reactive
  ## contract on every FFI call, closing the exotic no-callback gap.
  var acc: seq[OpaqueCall]
  proc walk(n: NimNode) =
    if n.kind in {nnkCall, nnkCommand} and n.len >= 1:
      let (opaque, reason) = ffiOpacity(n[0], strict)
      if opaque: acc.add OpaqueCall(node: n, reason: reason)
    for c in n: walk(c)
  walk(body)
  acc
