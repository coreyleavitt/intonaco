## M-ε.4 — `eachDelta` public substrate primitive.
##
## Observes each delta of a collection as it fires. The substrate's
## public seam for "side-effect-on-delta": when a consumer (e.g.
## fresco's bindCollection) needs to react to individual delta events
## to drive incremental rendering or other imperative wiring, this is
## the named, walker-checked path.

{.experimental: "callOperator".}

import std/unittest
include intonaco/reactive_internal   # uses substrate-internal newDynamicReactive + pushDelta

suite "eachDelta — public delta-observation primitive":

  test "tracer: handler fires once per insert delta":
    var observed: seq[int] = @[]
    discard createRoot:
      collections:
        items = newSeq[int]()
      eachDelta items, d:
        if d.kind == dkInsert:
          observed.add d.insertVal
      items.push(1)
      items.push(2)
      items.push(3)
    check observed == @[1, 2, 3]

  test "modality: works over a DynamicCollection":
    var observed: seq[int] = @[]
    discard createRoot:
      let dyn = newDynamicReactive[int](@[10, 20])
      eachDelta dyn, d:
        if d.kind == dkInsert:
          observed.add d.insertVal
      pushDelta(dyn, Delta[int](kind: dkInsert, insertIdx: 2, insertVal: 30))
      pushDelta(dyn, Delta[int](kind: dkInsert, insertIdx: 3, insertVal: 40))
    check observed == @[30, 40]
