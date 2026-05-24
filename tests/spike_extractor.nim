{.experimental: "callOperator".}

## Spike (NOT product): de-risk the #52 dep-extractor before locking its design.
##
## #51 gave us the height CARRIER (heightOf / composeHeight / withHeight, all
## green). #52 is the EXTRACTOR: "which signals does this body read, at what
## heights, and is anything hidden?" This spike implements the extractor three
## ways on one fixture set, to answer two questions empirically:
##
##   1. Can we move forward as hoped? (descent + the #50 oracle + #51 heights
##      compose on real typed ASTs, no Nim-mechanics surprise.)
##   2. What does descend-and-collect actually ENTAIL vs. the cheaper tiers?
##
## Strategies (increasing reach, increasing cost):
##   sBail        any call that transitively reads a signal -> dynamic.
##   sCollectArgs sBail, but a signal-typed ARGUMENT to such a call is a dep
##                (it gets read inside) — resolved at the callsite, no descent.
##   sCollectFull sCollectArgs + descend into helper bodies to resolve FREE
##                (global, non-param) signal reads, with param->arg mapping.
##
## Soundness floor (all strategies): runtime-keyed reads, aliases, and opaque
## calls (method/async/indirect/FFI, via the #50 oracle) force DYNAMIC. Over-
## approximation (e.g. both arms of an `if`) is mandatory and safe; under-
## approximation is fatal (too-low height -> glitch).

import std/[macros, options, strutils, tables]
import intonaco/reactive/signal
import intonaco/reactive/height
import intonaco/reactive/purity

# --- detection primitives (local; from spike_fragment_classifier) -----------

proc isSignalTy(node: NimNode): bool =
  if node == nil or node.kind in {nnkEmpty, nnkNilLit}: return false
  let typ = node.getTypeInst
  typ != nil and typ.kind == nnkBracketExpr and typ.len >= 1 and
    typ[0].repr == "Signal"

proc isSignalRead(n: NimNode): bool =
  ## A TRACKED read is a call to the accessor `()` or `get` on a signal —
  ## keyed on the CALLEE, not the arg type. (Keying on "first arg is signal-
  ## typed" false-matches any helper taking a signal, e.g. `fmtSig(a)`.) `peek`
  ## is excluded: it's an untracked read and creates no dependency (#49).
  n.kind in {nnkCall, nnkCommand} and n.len == 2 and n[0].kind == nnkSym and
    n[0].repr in ["()", "get"] and isSignalTy(n[1])

proc isRoutineCall(n: NimNode): bool =
  n.kind in {nnkCall, nnkCommand} and n.len >= 1 and n[0].kind == nnkSym

proc paramNames(impl: NimNode): seq[string] =
  for i in 1 ..< impl[3].len:
    let idents = impl[3][i]
    for j in 0 ..< idents.len - 2: result.add idents[j].repr

# --- the parameterized extractor --------------------------------------------

type Strategy = enum sBail, sCollectArgs, sCollectFull

proc resolveHeight(body: NimNode, strat: Strategy): Option[int] {.compileTime.} =
  ## Returns Some(N) (static height) or none (dynamic). `deps` accumulates the
  ## directly-named signal symbols whose heights we can resolve; `dynamic` trips
  ## on anything unresolvable.
  var deps: seq[NimNode]
  var dynamic = false
  var visited: seq[string]

  proc walk(n: NimNode, subst: Table[string, NimNode])
  proc addDep(recv: NimNode, subst: Table[string, NimNode]) =
    ## recv is a signal-typed receiver. Map it through the active param->arg
    ## substitution (descent), then either record it as a dep or go dynamic.
    var r = recv
    if r.kind == nnkSym and r.repr in subst: r = subst[r.repr]  # param -> arg
    if r.kind == nnkSym: deps.add r            # directly-named -> resolvable
    else: dynamic = true                       # sigs[i](), alias expr -> dynamic

  proc walk(n: NimNode, subst: Table[string, NimNode]) =
    if dynamic: return
    if isSignalRead(n):
      addDep(n[1], subst)
      for c in n: walk(c, subst)               # args are values; may read too
      return
    if isRoutineCall(n):
      let callee = n[0]
      if reactiveEffects(callee).opaque:        # #50: compiler punted
        dynamic = true; return
      let impl = callee.getImpl
      let reads = reReads in reactiveEffects(callee).effects
      if impl.kind in {nnkProcDef, nnkFuncDef, nnkConverterDef} and reads:
        case strat
        of sBail:
          dynamic = true; return
        of sCollectArgs:
          # The reReads must be explained by signal-typed args (read inside via
          # a param). Collect those; if a signal-typed arg is not directly
          # named, dynamic. A free (global) read can't be seen here -> we must
          # assume one might exist -> but to stay SOUND we still bail unless we
          # can prove every read maps to an arg. The cheap proxy: if the callee
          # reads a free global, sCollectArgs can't know -> bail. We approximate
          # "explained by args" by requiring at least one signal-typed arg AND
          # no free read; detecting "no free read" needs the body, which is the
          # descent. So sCollectArgs alone is unsound for free reads -> it must
          # bail there too. Here we collect signal args AND descend ONLY to
          # check for a free read (not to resolve it).
          var sawSignalArg = false
          for i in 1 ..< n.len:
            if isSignalTy(n[i]):
              sawSignalArg = true
              if n[i].kind == nnkSym: deps.add n[i] else: dynamic = true
          # cheap free-read check via the param-name test on the body:
          let pnames = paramNames(impl)
          var freeRead = false
          proc scanFree(x: NimNode) =
            if isSignalRead(x) and (x[1].kind != nnkSym or x[1].repr notin pnames):
              freeRead = true
            for c in x: scanFree(c)
          scanFree(impl)
          if freeRead or not sawSignalArg: dynamic = true
        of sCollectFull:
          if callee.repr notin visited:
            visited.add callee.repr
            # build param -> arg substitution for this callsite
            var sub = subst
            let pnames = paramNames(impl)
            for i in 0 ..< pnames.len:
              if i + 1 < n.len: sub[pnames[i]] = n[i + 1]
            walk(impl, sub)                     # descend: resolve free + param reads
      for i in 1 ..< n.len: walk(n[i], subst)   # callsite arg values
      return
    for c in n: walk(c, subst)

  walk(body, initTable[string, NimNode]())
  if dynamic: return none(int)
  composeHeight(deps)

# --- reify harness ----------------------------------------------------------

macro hBail(body: typed): int =
  let r = resolveHeight(body, sBail); newLit(if r.isSome: r.get else: -1)
macro hArgs(body: typed): int =
  let r = resolveHeight(body, sCollectArgs); newLit(if r.isSome: r.get else: -1)
macro hFull(body: typed): int =
  let r = resolveHeight(body, sCollectFull); newLit(if r.isSome: r.get else: -1)

# --- fixtures (sources/computeds carry manually-baked heights) ---------------

let a    {.height: 0.} = signal(1, label = "a")
let b    {.height: 1.} = signal(2, label = "b")   # stand-in for a height-1 computed
let cond {.height: 0.} = signal(true, label = "cond")
let e2   {.height: 2.} = signal(0, label = "e2")  # stand-in for a height-2 computed
let g    {.height: 0.} = signal(7, label = "g")
let sigs = @[signal(0, label = "s0"), signal(0, label = "s1")]

proc fmtBar(v: int): string = "[" & $v & "]"      # pure (no signal read)
proc fmtSig(s: Signal[int]): int = s() + 1        # reads its PARAM
proc readsG(): int = g() * 2                       # FREE/global read of g

type Base = ref object of RootObj
type Deriv = ref object of Base
method mth(x: Base): int {.base.} = 0
method mth(d: Deriv): int = g()
proc viaMethod(x: Base): int = mth(x)              # dynamic dispatch -> opaque

import std/unittest

suite "spike: extractor tiers (bail / collect-args / collect-full)":

  test "direct read a() -> 1 in all tiers":
    check hBail(a()) == 1
    check hArgs(a()) == 1
    check hFull(a()) == 1

  test "multi a()+b() -> 2 in all tiers":
    check hBail(a() + b()) == 2
    check hFull(a() + b()) == 2

  test "CONDITIONAL over-approx: if cond(): a() else: e2() -> 3 (both arms)":
    check hBail(if cond(): a() else: e2()) == 3   # 1 + max(cond=0, a=0, e2=2)
    check hFull(if cond(): a() else: e2()) == 3

  test "pure formatter at callsite fmtBar(a()) -> 1 in all tiers":
    check hBail(fmtBar(a())) == 1                 # read is at callsite, not hidden

  test "signal ARG read inside helper fmtSig(a): bail=DYN, args/full=1":
    check hBail(fmtSig(a)) == -1                  # reReads -> conservative bail
    check hArgs(fmtSig(a)) == 1                   # collect the signal-typed arg
    check hFull(fmtSig(a)) == 1

  test "FREE global read readsG(): bail/args=DYN, full=1":
    check hBail(readsG()) == -1
    check hArgs(readsG()) == -1                   # can't see the free read -> bail
    check hFull(readsG()) == 1                    # descent resolves g{0} -> 1

  test "opaque (dynamic dispatch) viaMethod(...) -> DYN in all tiers":
    let d: Base = Deriv()
    check hBail(viaMethod(d)) == -1
    check hFull(viaMethod(d)) == -1

  test "runtime-keyed sigs[1]() -> DYN in all tiers":
    check hBail(sigs[1]()) == -1
    check hFull(sigs[1]()) == -1
