## TDD: reactive-effect analysis (intonaco#50 / T1).
## Compile-time primitives, tested via macros that reify a verdict into a
## runtime value the unittest checks.

import std/[unittest, macros]
import intonaco/reactive/signal
import intonaco/reactive/purity

let s = signal(0, label = "s")

# --- harness ----------------------------------------------------------------
macro effectsOf(callee: typed): untyped =
  # reify reactiveEffects(callee).effects into a typed runtime set
  let r = reactiveEffects(callee)
  let acc = genSym(nskVar, "acc")
  let body = newStmtList()
  body.add nnkVarSection.newTree(nnkIdentDefs.newTree(
    acc, nnkBracketExpr.newTree(ident"set", ident"ReactiveEffect"), newEmptyNode()))
  if reReads in r.effects: body.add newCall(ident"incl", acc, ident"reReads")
  if reWrites in r.effects: body.add newCall(ident"incl", acc, ident"reWrites")
  body.add acc
  result = nnkBlockStmt.newTree(newEmptyNode(), body)

macro opaqueOf(callee: typed): untyped = newLit(reactiveEffects(callee).opaque)
macro opaqueCount(body: typed): untyped = newLit(opaqueReactiveCalls(body).len)
macro opaqueCountStrict(body: typed): untyped = newLit(opaqueReactiveCalls(body, strict = true).len)

# --- fixtures ----------------------------------------------------------------
proc readsSig(): int = s()
proc viaHelper(): int = readsSig() + 1
proc pureFn(): int = 21 * 2
proc writesSig() = s.set(5)
proc peeksOnly(): int = s.peek()
proc readingCb(): int = s()
proc hof(f: proc(): int): int {.effectsOf: f.} = f()
proc usesHof(): int = hof(readingCb)
proc readsAndWrites(): int = (s.set(s() + 1); s())

proc cNoEf(cb: proc(): int): int {.importc: "c_no_ef".}        # callback, NO effectsOf
proc cWithEf(cb: proc(): int): int {.importc: "c_ef", effectsOf: cb.}
proc cNoCb(x: cint): cint {.importc: "c_no_cb".}               # no callback, no contract
proc cVouched(x: cint): cint {.importc: "c_vouch", forbids: [ReactiveRead, ReactiveWrite].}

let fnVar: proc(): int = readsSig
proc usesIndirect(): int = fnVar()                             # indirect (RootEffect)
type Base = ref object of RootObj
type Deriv = ref object of Base
method mth(b: Base): int {.base.} = 0
method mth(d: Deriv): int = s()                                # override reads
proc usesMethod(b: Base): int = mth(b)                         # dynamic dispatch (RootEffect)

suite "reactiveEffects (specific effects via effecttraits)":
  test "1. direct signal reader -> {reReads}":        check effectsOf(readsSig) == {reReads}
  test "2. transitive reader (helper) -> {reReads}":  check effectsOf(viaHelper) == {reReads}
  test "3. pure proc -> {}":                          check effectsOf(pureFn) == {}
  test "4. signal writer (via set) -> {reWrites}":    check effectsOf(writesSig) == {reWrites}
  test "5. peek-only -> {} (untracked is not a dep)": check effectsOf(peeksOnly) == {}
  test "6. effectsOf HOF (containing proc) -> {reReads}": check effectsOf(usesHof) == {reReads}
  test "7. reads and writes -> both":                 check effectsOf(readsAndWrites) == {reReads, reWrites}

suite "reactiveEffects.opaque (bare RootEffect = compiler punted)":
  test "direct reader is NOT opaque":                 check not opaqueOf(readsSig)
  test "pure is NOT opaque":                          check not opaqueOf(pureFn)
  test "writer is NOT opaque (firewall holds)":       check not opaqueOf(writesSig)
  test "indirect proc-value call IS opaque":          check opaqueOf(usesIndirect)
  test "dynamic-dispatch method IS opaque":           check opaqueOf(usesMethod)

suite "opaqueReactiveCalls (the FFI []-case the opaque flag can't see)":
  test "8. unannotated-callback FFI is flagged":      check opaqueCount(cNoEf(readingCb)) == 1
  test "9. effectsOf-annotated FFI is NOT flagged":   check opaqueCount(cWithEf(readingCb)) == 0
  test "10. no-callback FFI is NOT flagged":          check opaqueCount(cNoCb(3.cint)) == 0
  test "12. clean body is empty":                     check opaqueCount((discard readsSig(); discard viaHelper(); discard usesHof())) == 0
  test "13. under strict, bare no-callback FFI is flagged":  check opaqueCountStrict(cNoCb(3.cint)) == 1
  test "14. under strict, forbids-vouched FFI is trusted":   check opaqueCountStrict(cVouched(3.cint)) == 0
