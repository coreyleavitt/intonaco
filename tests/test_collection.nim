{.experimental: "callOperator".}

## intonaco's own CollectionSignal coverage — the substrate must be validated on
## its own, not only through fresco (and this is the safety net for the
## ReactiveCollection base extraction that `derive` rides on). Ported from
## fresco's test_collection.nim — port now complete: this file is the full
## union of both (delta-emission + speculative core, granular speculative
## inverses/nesting, edge cases, journal integration). Where fresco had
## granular per-op delta tests, the condensed versions below cover them.

import std/unittest
include intonaco/reactive_internal

suite "CollectionSignal: core delta emission":

  test "empty initial state":
    let c = collectionC[int]()
    check c.len == 0
    check c.get() == newSeq[int]()

  test "push appends and emits dkInsert":
    let c = collectionC[string]()
    var deltas: seq[Delta[string]] = @[]
    discard createRoot:
      eachDelta c, d:
        deltas.add d
    c.push("a"); c.push("b"); c.push("c")
    check c.get() == @["a", "b", "c"]
    check deltas.len == 3
    for i, d in deltas:
      check d.kind == dkInsert
      check d.insertIdx == i

  test "pop / insert / remove / setAt / clear / set emit the right deltas":
    let c = collectionC(@[1, 2, 3])
    var deltas: seq[Delta[int]] = @[]
    discard createRoot:
      eachDelta c, d:
        deltas.add d
    discard c.pop();   check deltas[^1].kind == dkRemove and deltas[^1].removeIdx == 2
    c.insert(0, 0);    check deltas[^1].kind == dkInsert and deltas[^1].insertIdx == 0
    c.setAt(1, 99);    check deltas[^1].kind == dkUpdate and deltas[^1].updateVal == 99
    c.remove(0);       check deltas[^1].kind == dkRemove
    c.clear();         check deltas[^1].kind == dkClear
    c.set(@[7, 8]);    check deltas[^1].kind == dkReplace and deltas[^1].replaceVal == @[7, 8]

  test "eachDelta handlers unregister on scope dispose":
    let c = collectionC[int]()
    var deltas: seq[Delta[int]] = @[]
    let root = createRoot:
      eachDelta c, d:
        deltas.add d
    c.push(1); check deltas.len == 1
    dispose(root)
    c.push(2); check deltas.len == 1

  test "multiple handlers all receive deltas":
    let c = collectionC[int]()
    var a, b = 0
    discard createRoot:
      eachDelta c, d:
        if d.kind == dkInsert: a += d.insertVal
      eachDelta c, d:
        if d.kind == dkInsert: b += d.insertVal
    c.push(3); c.push(7)
    check a == 10 and b == 10

  test "#68-family: N>=3 delta handlers all fire on push":
    # Sibling of #68's Signal-observer fix at the deltaConsumers
    # site. `deliver` uses the same snapshot-then-iterate-while-
    # callbacks-may-mutate pattern that needed fixing for
    # Signal.observers — N=3 ensures we exercise the same regime.
    let c = collectionC[int]()
    var seenA, seenB, seenC = 0
    discard createRoot:
      eachDelta c, d:
        if d.kind == dkInsert: seenA = d.insertVal
      eachDelta c, d:
        if d.kind == dkInsert: seenB = d.insertVal
      eachDelta c, d:
        if d.kind == dkInsert: seenC = d.insertVal
    c.push(42)
    check seenA == 42
    check seenB == 42
    check seenC == 42

  test "#68: a handler disposing a sibling scope mid-fanout doesn't break iteration":
    let c = collectionC[int]()
    var aFired, cFired = 0
    var bScope: Scope
    let root = createRoot:
      eachDelta c, d:
        inc aFired; dispose(bScope)
      bScope = newScope(parent = currentScope.value)
      withScope(bScope):
        eachDelta c, d:
          discard d
      eachDelta c, d:
        inc cFired
    c.push(1)
    check aFired == 1
    check cFired == 1
    dispose(root)

  test "plain reactive observers re-fire on every delta kind":
    collections:
      c = @[1, 2, 3]
    var runs = 0
    discard createRoot:
      effect [c]:
        discard c; inc runs
    let base = runs
    c.push(4);      check runs == base + 1
    c.setAt(1, 99); check runs == base + 2
    c.remove(0);    check runs == base + 3
    c.set(@[1, 2]); check runs == base + 4
    c.clear();      check runs == base + 5

  test "plain reactive observers re-fire on collection changes":
    # Regression: CollectionSignal previously wasn't Subscribable and
    # never called notify(), so `createEffect` / `bindRows` reading
    # the items never re-ran on push/pop/etc.
    collections:
      c = @["a"]
    var runs = 0
    var lastLen = 0
    discard createRoot:
      effect [c]:
        lastLen = c.len
        inc runs
    check runs == 1
    check lastLen == 1
    c.push("b")
    check runs == 2
    check lastLen == 2
    c.push("c")
    check runs == 3
    check lastLen == 3
    c.pop()
    check runs == 4
    check lastLen == 2

suite "CollectionSignal: speculative rollback":

  test "mutations roll back when the block falls off without commit":
    let c = collectionC(@[1, 2, 3])
    discard speculative:
      c.push(4); c.push(5)
      check c.len == 5
    check c.get() == @[1, 2, 3]

  test "mutations stick on commit":
    let c = collectionC(@[1, 2, 3])
    discard speculative:
      c.push(4); c.setAt(0, 99); commit()
    check c.get() == @[99, 2, 3, 4]

  test "M mutations + rollback fire ONE batched dkRollback with the right inverses":
    let c = collectionC(@[10, 20, 30])
    var deltas: seq[Delta[int]] = @[]
    discard createRoot:
      eachDelta c, d:
        deltas.add d
    discard speculative:
      c.push(40); c.setAt(0, 99); discard c.pop()
    # Forward deltas fired during the block; one dkRollback fires on exit.
    check deltas.len == 4    # 3 forward + 1 batched rollback
    check deltas[^1].kind == dkRollback
    check deltas[^1].rollbackOps.len == 3
    # The DELIVERED inverse kinds must survive the height-scheduled buffer (a
    # plain seq COPY of the recursive Delta variant zeroed them under ORC):
    check deltas[^1].rollbackOps[0].kind == dkRemove   # inverse-of-push
    check deltas[^1].rollbackOps[1].kind == dkUpdate   # inverse-of-setAt (restores 10)
    check deltas[^1].rollbackOps[1].updateVal == 10
    check deltas[^1].rollbackOps[2].kind == dkInsert   # inverse-of-pop
    check c.get() == @[10, 20, 30]

  test "clear inside speculative is reversed by a dkReplace inverse":
    let c = collectionC(@["a", "b", "c"])
    discard speculative:
      c.clear()
      check c.len == 0
    check c.get() == @["a", "b", "c"]

  test "set (wholesale replace) rolls back":
    let c = collectionC(@[1, 2, 3])
    discard speculative:
      c.set(@[10, 20, 30])
      check c.get() == @[10, 20, 30]
    check c.get() == @[1, 2, 3]

  test "pop inside speculative + rollback restores the popped value":
    let c = collectionC(@["a", "b", "c"])
    discard speculative:
      let v = c.pop()
      check v == "c"
      check c.get() == @["a", "b"]
    check c.get() == @["a", "b", "c"]

  test "setAt rollback restores prior value via dkUpdate inverse, not dkReplace":
    let c = collectionC(@[1, 2, 3])
    var deltas: seq[Delta[int]] = @[]
    discard createRoot:
      eachDelta c, d:
        deltas.add d
    discard speculative:
      c.setAt(1, 99)
    # Two deltas total: forward dkUpdate, batched dkRollback containing one dkUpdate
    check deltas[^1].kind == dkRollback
    check deltas[^1].rollbackOps.len == 1
    check deltas[^1].rollbackOps[0].kind == dkUpdate
    check deltas[^1].rollbackOps[0].updateVal == 2
    check c.get() == @[1, 2, 3]

  test "nested: inner commit promotes inverses, outer rollback drains both":
    let c = collectionC(@[0])
    var batches: seq[Delta[int]] = @[]
    discard createRoot:
      eachDelta c, d:
        if d.kind == dkRollback: batches.add d
    discard speculative:
      c.push(1)             # outer
      discard speculative:
        c.push(2)           # inner
        c.push(3)           # inner
        commit()
      c.push(4)             # outer (after inner committed)
    # Inner commit fired NO rollback batch.
    # Outer rollback fired ONE batch with all 4 mutations' inverses.
    check batches.len == 1
    check batches[0].rollbackOps.len == 4
    check c.get() == @[0]

  test "nested: inner rollback fires its own batch; outer mutations intact":
    let c = collectionC(@[0])
    var batches: seq[Delta[int]] = @[]
    discard createRoot:
      eachDelta c, d:
        if d.kind == dkRollback: batches.add d
    discard speculative:
      c.push(1)             # outer — sticks (commit on outer)
      discard speculative:
        c.push(2)           # inner — gets rolled back
        c.push(3)           # inner — gets rolled back
      # inner rolled back here; outer continues
      c.push(4)             # outer — sticks
      commit()
    # One rollback batch from inner; nothing on outer (it committed).
    check batches.len == 1
    check batches[0].rollbackOps.len == 2
    check c.get() == @[0, 1, 4]

  test "multiple collections in same scope each emit their own dkRollback":
    let a = collectionC[int]()
    let b = collectionC[int]()
    var aBatches, bBatches: seq[Delta[int]] = @[]
    discard createRoot:
      eachDelta a, d:
        if d.kind == dkRollback: aBatches.add d
      eachDelta b, d:
        if d.kind == dkRollback: bBatches.add d
    discard speculative:
      a.push(1); a.push(2)
      b.push(10); b.push(20); b.push(30)
    check aBatches.len == 1
    check aBatches[0].rollbackOps.len == 2
    check bBatches.len == 1
    check bBatches[0].rollbackOps.len == 3
    check a.get().len == 0
    check b.get().len == 0

suite "CollectionSignal: edge cases":

  test "clear() on empty is a silent no-op (no delta, no observer fire)":
    collections:
      c = newSeq[int]()
    var observerRuns = 0
    discard createRoot:
      effect [c]:
        discard c.len
        inc observerRuns
    let baseline = observerRuns
    c.clear()    # already empty
    check observerRuns == baseline   # no fire

  test "delta handler that mutates during rollback fanout doesn't corrupt state":
    # Reentrancy guard: when a rollback hook fires the dkRollback delta
    # to handlers, a handler may legitimately call `push`/`setAt`/etc
    # on the same collection (e.g., to record the rollback in a sibling
    # collection, or trigger a state-machine transition). Those calls
    # re-enter `captureInverse`. The protection is in speculative.nim:
    # `scope.committed` is set BEFORE onRollbackHooks fire, so
    # `captureInverse`'s `not committed` gate short-circuits and no
    # orphan rollback entry is pushed onto `c.rollbackHead`.
    #
    # Without this protection, the head pop at the end of the rollback
    # hook would pop the *new* (mid-hook) entry, leaving the original
    # entry stuck on the head — a memory leak and a state-machine bug
    # waiting for the next scope's rollback.
    let c = collectionC[int]()
    var sawReentrantInsert = false
    var firedOnce = false
    eachDelta c, d:
      if d.kind == dkRollback and not firedOnce:
        # Mid-rollback: mutate the same collection. Must not crash,
        # must not leave c.rollbackHead non-nil. Fire only on the
        # FIRST rollback the handler sees, otherwise subsequent
        # cycles would keep re-injecting 999.
        firedOnce = true
        c.push(999)
      elif d.kind == dkInsert and d.insertVal == 999:
        sawReentrantInsert = true
    discard speculative:
      c.push(1)
      c.push(2)
    check sawReentrantInsert            # handler's reentrant push fired
    check c.get() == @[999]             # rolled-back to [], then push(999)
    # Second rollback cycle: if the first had left an orphan entry on
    # c.rollbackHead, captureInverse's "head.scope !=
    # currentSpeculative.value" check would still see the stale entry
    # and the inverses for this scope's writes would attach to it — the
    # rollback would either no-op or pop the wrong batch.
    discard speculative:
      c.push(50)
      c.push(60)
    check c.get() == @[999]             # both pushes rolled back cleanly

  test "pop on empty asserts":
    let c = collectionC[int]()
    expect AssertionDefect:
      discard c.pop()

  test "insert at out-of-bounds asserts":
    let c = collectionC(@[1, 2, 3])
    expect AssertionDefect:
      c.insert(99, 4)    # idx > len

  test "remove on out-of-bounds asserts":
    let c = collectionC(@[1, 2])
    expect AssertionDefect:
      c.remove(5)

  test "setAt on out-of-bounds asserts":
    let c = collectionC(@[1])
    expect AssertionDefect:
      c.setAt(2, 99)

suite "CollectionSignal: journal integration":

  setup:
    resetJournal()
    discard useJournal()

  teardown:
    resetJournal()

  test "labeled push emits ekCollectionDelta with insert op":
    let c = collectionC[int](@[], label = "items")
    c.push(42)
    let evs = globalJournal.byKind(ekCollectionDelta)
    check evs.len == 1
    check evs[0].collectionLabel == "items"
    check evs[0].collectionOp == "insert"
    check evs[0].collectionIdx == 0
    check evs[0].collectionRepr == "42"

  test "remove / update / clear / replace each emit the right op":
    let c = collectionC(@[1, 2, 3], label = "nums")
    c.remove(0)
    c.setAt(0, 99)
    c.clear()
    c.set(@[7, 8])
    let evs = globalJournal.byKind(ekCollectionDelta)
    check evs.len == 4
    check evs[0].collectionOp == "remove"
    check evs[0].collectionIdx == 0
    check evs[1].collectionOp == "update"
    check evs[2].collectionOp == "clear"
    check evs[2].collectionIdx == -1
    check evs[3].collectionOp == "replace"
    check evs[3].collectionRepr == "2"     # replace records the new length

  test "unlabeled collections skip journaling":
    let c = collectionC[int]()   # no label
    c.push(1)
    c.push(2)
    check globalJournal.byKind(ekCollectionDelta).len == 0

  test "rollback writes exactly ONE ekCollectionRollback per affected collection":
    let c = collectionC[int](@[], label = "items")
    discard speculative:
      c.push(1)
      c.push(2)
      c.push(3)
    let forwards = globalJournal.byKind(ekCollectionDelta)
    let rollbacks = globalJournal.byKind(ekCollectionRollback)
    check forwards.len == 3     # forward mutations still journal
    check rollbacks.len == 1    # one boundary event
    check rollbacks[0].rollbackLabel == "items"
    check rollbacks[0].rollbackCount == 3
    # opsRepr: ";".join three "r:idx" tokens
    check rollbacks[0].rollbackOpsRepr.contains("r:")

  test "two labeled collections in one rollback → two rollback events":
    let a = collectionC[int](@[], label = "a")
    let b = collectionC[int](@[], label = "b")
    discard speculative:
      a.push(1)
      b.push(2)
      b.push(3)
    let rbs = globalJournal.byKind(ekCollectionRollback)
    check rbs.len == 2
    let byLabel = block:
      var t: tuple[a, b: int]
      for ev in rbs:
        if ev.rollbackLabel == "a": t.a = ev.rollbackCount
        elif ev.rollbackLabel == "b": t.b = ev.rollbackCount
      t
    check byLabel.a == 1
    check byLabel.b == 2

  test "unlabeled collection rollback skips journal":
    let c = collectionC[int]()   # no label
    discard speculative:
      c.push(1)
      c.push(2)
    check globalJournal.byKind(ekCollectionRollback).len == 0

  test "commit does NOT write a rollback event":
    let c = collectionC[int](@[], label = "x")
    discard speculative:
      c.push(1)
      commit()
    check globalJournal.byKind(ekCollectionRollback).len == 0
