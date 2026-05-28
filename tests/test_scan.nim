{.experimental: "callOperator".}

## TDD: `scan` over a collection's delta stream (intonaco consistency direction).
## A `CollectionSignal[T]` has two faces — its value (`c.get()`, integration)
## and its delta stream (`deltas(c)`, differentiation). `scan` folds the typed
## deltas into derived state as a first-class, height-scheduled reactive node:
## the dependency on `c` is compile-time-visible, delivery is glitch-free, and
## the fold is O(1) per delta (no whole-seq re-read).

import std/[unittest, macros, options]
import intonaco/reactive/collection
import intonaco/reactive/deltafloor    # deltas / foldDeltas (floor — tests use it directly)
import intonaco/reactive/signal
import intonaco/reactive/dynamic       # dynamicEffect (for the floor-glue tests)
import intonaco/reactive/height
import intonaco/reactive/binding       # `computed` / `signals:` / `collections:` re-exports
import intonaco/reactive/scan

macro heightLit(sym: typed): int =
  ## The baked static height, or -1 if the binding carries no `{.height.}`.
  let r = heightOf(sym)
  newLit(if r.isSome: r.get else: -1)

collections:
  clog = @[1, 2]

suite "scan — fold a collection's deltas into derived state":
  test "1. folds a delta into state when the collection mutates":
    let c = collection[int](@[])
    let total = foldDeltas(deltas(c), 0, proc(acc: int, d: Delta[int]): int =
      if d.kind == dkInsert: acc + d.insertVal else: acc)
    check total() == 0
    c.push(10)
    check total() == 10

  test "2. accumulates across successive mutations (no re-folding)":
    let c = collection[int](@[])
    let total = foldDeltas(deltas(c), 0, proc(acc: int, d: Delta[int]): int =
      if d.kind == dkInsert: acc + d.insertVal else: acc)
    c.push(10)
    c.push(5)
    check total() == 15

suite "collections: bakes a compile-time source height":
  test "3. a collection declared via collections: carries {.height: 0.}":
    check heightLit(clog) == 0
    check clog.get() == @[1, 2]

scan totalLog, clog, [], 0, proc(acc: int, d: Delta[int]): int =
  if d.kind == dkInsert: acc + d.insertVal else: acc

suite "scan macro — static, height-baked collection fold":
  test "4. bakes height = collection + 1 and folds deltas":
    check heightLit(totalLog) == 1     # clog height 0 -> scan height 1
    clog.push(7)
    check totalLog() == 7

signals:
  base = 5
computed mult, [base]:
  base * 2                      # height 1

scan scaled, clog, [mult], 0, proc(acc: int, d: Delta[int]): int =
  if d.kind == dkInsert: acc + d.insertVal * mult else: acc

suite "scan macro — composes the step's declared deps into its height":
  test "5. a step declaring a height-1 dep lifts scan to height 2":
    check heightLit(scaled) == 2

# Diamond: dsrc -> dmid (h1) -> dhi (h2); plus an effect pushing dsrc into a
# collection. The scan's step reads dhi(). dhi and the push both descend from
# dsrc, so the scan must fire only AFTER dhi settles — or it reads a stale dhi
# (the glitch). This only holds if the baked height (3) drives the runtime
# scheduler; if the runtime height stayed at collection+1 (1), the scan fires
# mid-h1 and reads dhi == 0.
collections:
  dc = newSeq[int]()
signals:
  dsrc = 0
computed dmid, [dsrc]:
  dsrc + 0                     # h1
computed dhi, [dmid]:
  dmid + 0                     # h2
dynamicEffect(proc() = dc.push(dsrc()))   # pushes on dsrc change (floor glue)

var observed: seq[int]
scan dprobe, dc, [dhi], 0, proc(acc: int, d: Delta[int]): int =
  if d.kind == dkInsert:
    observed.add dhi
    acc + 1
  else: acc

suite "scan macro — the baked height drives glitch-free scheduling":
  test "6. scan fires after a higher-height dep its step reads (no stale read)":
    observed = @[]          # drop the setup-time push(0)
    dsrc.set(5)
    check observed == @[5]   # dhi settled to 5 before the scan read it

suite "scan macro — refuses what it can't schedule statically":
  test "7. a non-baked collection (plain ctor) is a compile error":
    let plain = collection[int](@[])   # no {.height.} — not via collections:
    check not compiles(scan(bad7, plain, [], 0,
      proc(acc: int, d: Delta[int]): int = acc))
  test "8. a runtime-keyed step is a compile error":
    let sigs = @[signal(1), signal(2)]
    let idx = signal(0)
    check not compiles(scan(bad8, clog, [], 0,
      proc(acc: int, d: Delta[int]): int = acc + sigs[idx()]()))

# A collection mutated from inside an in-flight propagation (an effect on
# `trig` pushes to `nc`). The scan must still receive that delta in the same
# drain — the stream buffers it and the scheduler enqueues the scan, no special
# per-fire slot needed (the soundness claim for nested mutation).
collections:
  nc = newSeq[int]()
signals:
  trig = 0
scan ncount, nc, [], 0, proc(acc: int, d: Delta[int]): int =
  if d.kind == dkInsert: acc + 1 else: acc
dynamicEffect(proc() = (if trig() > 0: nc.push(trig())))

suite "scan macro — nested mutation during propagation":
  test "9. a push from inside a propagation reaches the scan":
    let before = ncount()
    trig.set(1)
    check ncount() == before + 1
