{.experimental: "callOperator".}

## TDD: the hybrid reactive-body classifier (intonaco#52). Compile-time
## verdict reified into a runtime int the unittest checks: the static height,
## or -1 for DYNAMIC (the test_height / test_purity pattern).

import std/[unittest, macros, options]
import intonaco/reactive/signal
import intonaco/reactive/height
import intonaco/reactive/classify

# --- harness ----------------------------------------------------------------
macro staticHeight(body: typed): int =
  let c = classify(body)
  newLit(if c.tier == tStatic: c.height else: -1)

# --- fixtures (signals carry manually-baked heights, as #53 will auto-bake) --
let a    {.height: 0.} = signal(1, label = "a")
let b    {.height: 1.} = signal(2, label = "b")
let cond {.height: 0.} = signal(true, label = "cond")
let e2   {.height: 2.} = signal(0, label = "e2")
let sigs = @[signal(0, label = "s0"), signal(0, label = "s1")]
let unbaked = signal(5, label = "unbaked")   # NO {.height.} -> not in fragment
let g    {.height: 0.} = signal(7, label = "g")
proc fmtBar(v: int): string = "[" & $v & "]"  # pure formatter (no signal read)
proc readsG(): int = g() * 2                   # helper reads a FREE global signal

type Base = ref object of RootObj
type Deriv = ref object of Base
method mth(x: Base): int {.base.} = 0
method mth(d: Deriv): int = g()
proc viaMethod(x: Base): int = mth(x)          # dynamic dispatch -> opaque
let dv: Base = Deriv()

proc readingCb(): int = g()
proc cNoEf(cb: proc(): int): int {.importc: "c_no_ef".}  # callback, NO effectsOf

suite "classify — static taxonomy":
  test "1. direct read a() -> STATIC(1)":         check staticHeight(a()) == 1
  test "2. multi a()+b() -> STATIC(2)":           check staticHeight(a() + b()) == 2
  test "3. callsite formatter -> STATIC(1)":      check staticHeight(fmtBar(a())) == 1
  test "4. conditional over-approx -> STATIC(3)": check staticHeight(if cond(): a() else: e2()) == 3
  test "5. peek is not a read -> STATIC(0)":      check staticHeight(a.peek()) == 0

suite "classify — DYNAMIC (soundness: dangerous reads never static)":
  test "6. runtime-keyed sigs[1]() -> DYNAMIC":   check staticHeight(sigs[1]()) == -1
  test "7. hidden global via helper -> DYNAMIC":  check staticHeight(readsG()) == -1
  test "8. opaque (dynamic dispatch) -> DYNAMIC": check staticHeight(viaMethod(dv)) == -1
  test "9. unannotated-callback FFI -> DYNAMIC":  check staticHeight(cNoEf(readingCb)) == -1
  test "10. unbaked dependency -> DYNAMIC":       check staticHeight(unbaked()) == -1
  test "11. mixed direct + hidden read -> DYNAMIC (one disqualifier poisons)":
    check staticHeight(a() + readsG()) == -1
