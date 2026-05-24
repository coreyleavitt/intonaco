{.experimental: "callOperator".}

## TDD: Architecture-B construction macros (intonaco#53). `computed`/`effect`/
## `dynamic` classify at construction, bake static heights, fall to the runtime
## floor (with a warning / strict error) otherwise.

import std/[unittest, macros, options]
import intonaco/reactive/signal
import intonaco/reactive/height
import intonaco/reactive/classify
import intonaco/reactive/construct

# --- harness ----------------------------------------------------------------
macro heightLit(sym: typed): int =
  let r = heightOf(sym)
  newLit(if r.isSome: r.get else: -1)

# --- fixtures ----------------------------------------------------------------
let a {.height: 0.} = signal(1, label = "a")
computed b: a()       # should bake {.height: 1.}
computed c: b()       # reads b's baked pragma -> {.height: 2.}

let sigs = @[signal(10, label = "s0"), signal(20, label = "s1")]
let idx {.height: 0.} = signal(0, label = "idx")
computed d: sigs[idx()]()   # runtime-keyed -> DYNAMIC -> runtime floor
dynamic e: sigs[idx()]()    # same pattern via the explicit escape hatch

signals:
  src = 5
computed usesSrc: src()     # static iff src carries a baked height

# Simple symmetric diamond via the macros (heights resolve via accumulation too).
signals:
  da = 0
computed db: da()
computed dc: da()

# Conditional node: baked height 3 (over-approx over BOTH arms), but runtime
# accumulation alone sees only the taken `then` branch -> 2. The baked height
# must drive the scheduler, or the else-branch read glitches.
signals:
  src4 = 5
computed cond4: src4() >= 0   # 1
computed e4:    src4() * 10    # 1
computed e24:   e4() + 1       # 2
computed v4:                   # 3 = 1 + max(cond4=1, e24=2)
  if cond4(): 0 else: e24()

suite "computed macro — static bake + composition":
  test "1. bakes height; composes a{0} -> b{1} -> c{2}":
    check heightLit(b) == 1
    check heightLit(c) == 2
    check b() == 1     # runtime still works
    check c() == 1

suite "archBAction policy (pure decision)":
  test "2a. STATIC -> bake(height)":
    let r = archBAction(Classification(tier: tStatic, height: 3), false, false)
    check r.kind == abBakeStatic
    check r.height == 3
  test "2b. DYNAMIC, non-strict -> floor + warn":
    let r = archBAction(Classification(tier: tDynamic, reason: "x"), false, false)
    check r.kind == abFloor
    check r.warn
  test "2c. DYNAMIC, strict -> error":
    let r = archBAction(Classification(tier: tDynamic, reason: "x"), false, true)
    check r.kind == abError
  test "2d. escape hatch -> floor, silent":
    let r = archBAction(Classification(tier: tDynamic, reason: "x"), true, false)
    check r.kind == abFloor
    check not r.warn
  test "2e. escape hatch overrides STATIC -> floor, silent":
    let r = archBAction(Classification(tier: tStatic, height: 3), true, false)
    check r.kind == abFloor
    check not r.warn

suite "computed macro — DYNAMIC falls to the runtime floor":
  test "3. dynamic computed still runs + re-runs via the floor":
    check d() == 10
    idx.set(1)
    check d() == 20

suite "dynamic: escape hatch":
  test "5. compiles a genuinely-dynamic pattern, runs via the floor":
    idx.set(0)
    check e() == 10
    idx.set(1)
    check e() == 20

suite "signals: bakes source heights":
  test "6. sources are {.height:0.}; computeds over them are static":
    check heightLit(src) == 0
    check heightLit(usesSrc) == 1

signals:
  ec = 0
var observed: seq[int]
effect:
  observed.add ec()

suite "effect: macro":
  test "8. effect runs immediately and re-runs on dependency change":
    observed = @[]
    ec.set(1)
    check observed == @[1]

suite "glitch cross-check (baked heights drive the scheduler)":
  test "4a. diamond built via macros is glitch-free":
    var seen: seq[(int, int)]
    createEffect(proc() = seen.add (db(), dc()))
    da.set(1); da.set(2)
    var glitches = 0
    for pair in seen:
      if pair[0] != pair[1]: inc glitches
    check glitches == 0
  test "4b. baked over-approx height drives the runtime (accumulation gives 2)":
    check heightLit(v4) == 3     # compile-time over-approx (both arms)
    check v4.height == 3         # runtime computation height == the baked height
