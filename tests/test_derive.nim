{.experimental: "callOperator".}

## TDD: `derive` — an incrementally-maintained mapped view of a collection.
## Semantics are PURE: `mapped(c, f).get() === c.get().map(f)` — an ordinary
## dataflow node (in the Lean proof model, no stateful fold). Incrementality
## (apply `f` only to the changed element per delta) is a runtime optimization
## proven equivalent to the wholesale map.

import std/[unittest, sequtils, macros, options]
import intonaco/reactive/collection
import intonaco/reactive/signal
import intonaco/reactive/runtime
import intonaco/reactive/speculative
import intonaco/reactive/height
import intonaco/reactive/derive

macro heightLit(sym: typed): int =
  let r = heightOf(sym)
  newLit(if r.isSome: r.get else: -1)

suite "derive — incremental mapped view of a collection":
  test "1. value is the mapped source; updates on source change":
    let c = collection(@[1, 2, 3])
    let d = mapped(c, proc(x: int): int = x * 10)
    check d.get() == @[10, 20, 30]
    c.push(4)
    check d.get() == @[10, 20, 30, 40]

  test "2. incremental: f runs once per delta, not over the whole collection":
    let c = collection(@[1, 2, 3])
    var fcalls = 0
    let d = mapped(c, proc(x: int): int = (inc fcalls; x * 10))
    check fcalls == 3      # initial map over the 3 items
    c.push(4)
    check fcalls == 4      # +1 for the new element only, NOT a re-map of all 4
    c.push(5)
    check fcalls == 5
    check d.get() == @[10, 20, 30, 40, 50]

  test "4. value equals the wholesale map after every delta kind":
    let c = collection(@[1, 2, 3])
    let f = proc(x: int): int = x * 10
    let d = mapped(c, f)
    template eqWholesale = check d.get() == c.get().map(f)
    eqWholesale
    c.push(4);        eqWholesale     # dkInsert (end)
    c.insert(0, 0);   eqWholesale     # dkInsert (mid, shifts)
    c.setAt(2, 99);   eqWholesale     # dkUpdate
    c.remove(1);      eqWholesale     # dkRemove
    c.set(@[7, 8, 9]); eqWholesale    # dkReplace
    c.clear();        eqWholesale     # dkClear
    # dkRollback: a speculative mutation that reverts must keep d in sync
    c.set(@[1, 2, 3])
    discard speculative:
      c.push(4)
      c.setAt(0, 99)
    eqWholesale                        # after rollback, d mirrors the restored c

let plainColl = collection(@[1, 2, 3])   # plain ctor — NO `collections:`
derive drows, plainColl, proc(x: int): int = x * 10

suite "derive macro — compile-time scheduled, no collections: needed":
  test "5. bakes height = collection+1 for a plain collection() source":
    check heightLit(drows) == 1          # CollectionSignal recognized as height 0
    check drows.get() == @[10, 20, 30]
    plainColl.push(4)
    check drows.get() == @[10, 20, 30, 40]

# Diamond: dc → dd (derive, h1) and dc → g (sibling observer, h1); e reads BOTH
# dd and g's signal (h2). e must never observe dd updated while g's value is
# stale — i.e. derive must fire through the worklist at its height, not eagerly
# inside dc's fanout.
let dc = collection(@[1])
derive dd, dc, proc(x: int): int = x
let gsig = signal(0)
createEffect(proc() = gsig.set(dc.len))     # sibling observer of dc
var glitches = 0
createEffect(proc() = (if dd.get().len != gsig(): inc glitches))

suite "derive macro — glitch-free in a diamond":
  test "6. reading derive + a sibling c-observer never sees a transient":
    glitches = 0
    dc.push(2)
    check glitches == 0

let pc = collection(@[1, 2, 3])
signals:
  theme = 10

suite "derive macro — the map must be pure":
  test "7. an impure map (reads a signal) is a compile error":
    # A delta-only-maintained value can't track an external signal — the macro
    # must reject reactive reads inside `f`.
    check not compiles(derive(badp, pc, proc(x: int): int = x * theme()))
    # the pure form compiles
    check compiles(derive(okp, pc, proc(x: int): int = x * 2))

let cc = collection(@[1, 2, 3])
derive once, cc, proc(x: int): int = x + 1       # [2, 3, 4]
derive twice, once, proc(x: int): int = x * 10   # [20, 30, 40]

suite "derive — emits mapped deltas, and composes":
  test "8. forwards a mapped delta to a consumer":
    let c = collection(@[1, 2, 3])
    let d = mapped(c, proc(x: int): int = x * 10)
    var got: seq[Delta[int]]
    onDelta(d, proc(delta: Delta[int]) = got.add delta)
    c.push(4)
    check got.len == 1
    check got[0].kind == dkInsert
    check got[0].insertIdx == 3
    check got[0].insertVal == 40        # the MAPPED value

  test "9. derive composes over a derived collection":
    check heightLit(twice) == 2          # cc(0) -> once(1) -> twice(2)
    check twice.get() == @[20, 30, 40]
    cc.push(4)
    check twice.get() == @[20, 30, 40, 50]   # ((4+1) * 10)
