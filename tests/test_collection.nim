{.experimental: "callOperator".}

## intonaco's own CollectionSignal coverage — the substrate must be validated on
## its own, not only through fresco (and this is the safety net for the
## ReactiveCollection base extraction that `derive` rides on). Ported from
## fresco's test_collection.nim (the delta-emission + speculative core).

import std/unittest
import intonaco/reactive/scope
import intonaco/reactive/signal
import intonaco/reactive/runtime        # createEffect (the floor — tests may use it)
import intonaco/reactive/collection
import intonaco/reactive/deltafloor      # onDelta (the floor — tests subscribe directly)
import intonaco/reactive/speculative

suite "CollectionSignal: core delta emission":

  test "empty initial state":
    let c = collection[int]()
    check c.len == 0
    check c.get() == newSeq[int]()

  test "push appends and emits dkInsert":
    let c = collection[string]()
    var deltas: seq[Delta[string]] = @[]
    discard createRoot:
      onDelta(c, proc(d: Delta[string]) = deltas.add d)
    c.push("a"); c.push("b"); c.push("c")
    check c.get() == @["a", "b", "c"]
    check deltas.len == 3
    for i, d in deltas:
      check d.kind == dkInsert
      check d.insertIdx == i

  test "pop / insert / remove / setAt / clear / set emit the right deltas":
    let c = collection(@[1, 2, 3])
    var deltas: seq[Delta[int]] = @[]
    discard createRoot:
      onDelta(c, proc(d: Delta[int]) = deltas.add d)
    discard c.pop();   check deltas[^1].kind == dkRemove and deltas[^1].removeIdx == 2
    c.insert(0, 0);    check deltas[^1].kind == dkInsert and deltas[^1].insertIdx == 0
    c.setAt(1, 99);    check deltas[^1].kind == dkUpdate and deltas[^1].updateVal == 99
    c.remove(0);       check deltas[^1].kind == dkRemove
    c.clear();         check deltas[^1].kind == dkClear
    c.set(@[7, 8]);    check deltas[^1].kind == dkReplace and deltas[^1].replaceVal == @[7, 8]

  test "onDelta handlers unregister on scope dispose":
    let c = collection[int]()
    var deltas: seq[Delta[int]] = @[]
    let root = createRoot:
      onDelta(c, proc(d: Delta[int]) = deltas.add d)
    c.push(1); check deltas.len == 1
    dispose(root)
    c.push(2); check deltas.len == 1

  test "multiple handlers all receive deltas":
    let c = collection[int]()
    var a, b = 0
    discard createRoot:
      onDelta(c, proc(d: Delta[int]) = (if d.kind == dkInsert: a += d.insertVal))
      onDelta(c, proc(d: Delta[int]) = (if d.kind == dkInsert: b += d.insertVal))
    c.push(3); c.push(7)
    check a == 10 and b == 10

  test "#68: a handler disposing a sibling scope mid-fanout doesn't break iteration":
    let c = collection[int]()
    var aFired, cFired = 0
    var bScope: Scope
    let root = createRoot:
      onDelta(c, proc(d: Delta[int]) = (inc aFired; dispose(bScope)))
      bScope = newScope(parent = currentScope)
      withScope(bScope):
        onDelta(c, proc(d: Delta[int]) = discard d)
      onDelta(c, proc(d: Delta[int]) = inc cFired)
    c.push(1)
    check aFired == 1
    check cFired == 1
    dispose(root)

  test "plain reactive observers re-fire on every delta kind":
    let c = collection(@[1, 2, 3])
    var runs = 0
    discard createRoot:
      createEffect proc() = (discard c.get(); inc runs)
    let base = runs
    c.push(4);      check runs == base + 1
    c.setAt(1, 99); check runs == base + 2
    c.remove(0);    check runs == base + 3
    c.set(@[1, 2]); check runs == base + 4
    c.clear();      check runs == base + 5

suite "CollectionSignal: speculative rollback":

  test "mutations roll back when the block falls off without commit":
    let c = collection(@[1, 2, 3])
    discard speculative:
      c.push(4); c.push(5)
      check c.len == 5
    check c.get() == @[1, 2, 3]

  test "mutations stick on commit":
    let c = collection(@[1, 2, 3])
    discard speculative:
      c.push(4); c.setAt(0, 99); commit()
    check c.get() == @[99, 2, 3, 4]

  test "M mutations + rollback fire ONE batched dkRollback with the right inverses":
    let c = collection(@[10, 20, 30])
    var deltas: seq[Delta[int]] = @[]
    discard createRoot:
      onDelta(c, proc(d: Delta[int]) = deltas.add d)
    discard speculative:
      c.push(40); c.setAt(0, 99); discard c.pop()
    check deltas[^1].kind == dkRollback
    check deltas[^1].rollbackOps.len == 3
    # The DELIVERED inverse kinds must survive the height-scheduled buffer (a
    # plain seq COPY of the recursive Delta variant zeroed them under ORC):
    check deltas[^1].rollbackOps[0].kind == dkRemove   # inverse-of-push
    check deltas[^1].rollbackOps[1].kind == dkUpdate   # inverse-of-setAt
    check deltas[^1].rollbackOps[2].kind == dkInsert   # inverse-of-pop
    check c.get() == @[10, 20, 30]
