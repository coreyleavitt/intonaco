{.experimental: "callOperator".}

## Selective port of fresco's tests/unit/test_reactive.nim (the pre-split
## original reactive substrate tests) — only the tests whose coverage the
## current intonaco suite lacks.
##
## Overlap analysis against intonaco's suite (2026-08):
##
## PORTED (no intonaco equivalent found):
##   - the whole "scope" suite: no intonaco test asserts Scope lifecycle
##     semantics directly (no test file uses `onCleanup` at all) —
##     parentless/parented construction, cleanup ordering (reverse
##     registration), dispose idempotence, child-before-parent cascade,
##     the #68-family N>=3 children cascade, and createRoot's
##     cleanup-on-dispose contract.
##   - "setting to the same value short-circuits": setCore's equal-value
##     early-return is asserted nowhere else.
##   - "does not re-run for untracked signal changes": the runtime tier's
##     dynamic-tracking negative case (static-tier tests declare deps
##     explicitly, so it never arises there).
##   - "observer that adds a new observer fires next cycle, not this
##     one": structural observer-set mutation mid-notify for signals
##     (the iterRO contract) is otherwise unasserted.
##   - "observer that disposes itself during run doesn't break siblings":
##     test_collection.nim's #68 test pins the sibling-dispose pattern
##     for eachDelta handlers only, not for signal observers.
##   - "computed disposes with its scope": computed teardown + hold-last-
##     value after dispose is otherwise unasserted.
##
## COVERED (not ported), by:
##   - signal read/write, call-syntax read → test_binding.nim,
##     test_effect_feedback.nim (pervasive).
##   - effect runs once + re-runs on change → test_kit.nim ("effect-shape
##     macro"), test_binding.nim test 1, test_effect_feedback.nim.
##   - effect tracks multiple signals → test_speculative_reentrancy.nim
##     ("effect reads A and B"), test_binding.nim test 4a.
##   - scope dispose stops the effect → test_dynamic_tier.nim D7,
##     test_collection.nim ("eachDelta handlers unregister on scope
##     dispose").
##   - dynamic dependencies drop a no-longer-read signal →
##     test_speculative_reentrancy.nim ("conditional read" — asserts the
##     subscription is dropped and re-acquired).
##   - #68 N>=3 observers on one signal all re-fire →
##     test_depth_and_backfeedback.nim ("wider diamond: one apex over
##     many height-1 mirrors"), test_binding.nim test 5.
##   - computed derives/stays in sync + observable by effects →
##     test_depth_and_backfeedback.nim, test_effect_feedback.nim.

import std/unittest
include intonaco/reactive_internal

suite "scope (legacy)":

  test "newScope without parent has none":
    let s = newScope()
    check s.parent == nil
    check not s.disposed

  test "newScope with parent registers as child":
    let p = newScope()
    let c = newScope(p)
    check c.parent == p
    dispose(p)
    check c.disposed

  test "dispose runs cleanups in reverse registration order":
    var log: seq[int] = @[]
    let s = newScope()
    withScope(s):
      onCleanup proc() = log.add 1
      onCleanup proc() = log.add 2
      onCleanup proc() = log.add 3
    dispose(s)
    check log == @[3, 2, 1]

  test "dispose is idempotent":
    var calls = 0
    let s = newScope()
    withScope(s):
      onCleanup proc() = inc calls
    dispose(s)
    dispose(s)
    check calls == 1

  test "dispose cascades to children before parent cleanups":
    var log: seq[string] = @[]
    let p = newScope()
    withScope(p):
      onCleanup proc() = log.add "parent"
      let c = newScope(p)
      withScope(c):
        onCleanup proc() = log.add "child"
    dispose(p)
    check log == @["child", "parent"]

  test "#68-family: dispose cascades through N>=3 children, every cleanup runs":
    # Sibling of the #68 family. scope.dispose does `let childSnap =
    # s.children; s.children.setLen(0); for i in countdown(...):
    # dispose(childSnap[i])` — a snapshot-then-clear-then-iterate
    # pattern. If cursor inference made childSnap an alias of
    # s.children, the `setLen(0)` would zero its length and the
    # for-loop would skip every child's dispose entirely.
    var rootRan = false
    var c0Ran, c1Ran, c2Ran = false
    let root = newScope()
    withScope(root):
      onCleanup proc() = rootRan = true
      let c0 = newScope(root)
      withScope(c0): onCleanup proc() = c0Ran = true
      let c1 = newScope(root)
      withScope(c1): onCleanup proc() = c1Ran = true
      let c2 = newScope(root)
      withScope(c2): onCleanup proc() = c2Ran = true
    dispose(root)
    check c0Ran
    check c1Ran
    check c2Ran
    check rootRan

  test "createRoot returns a usable disposable scope":
    var ran = false
    let root = createRoot:
      onCleanup proc() = ran = true
    check not ran
    dispose(root)
    check ran

suite "signal (legacy)":

  test "setting to the same value short-circuits (no re-runs)":
    let s {.height: 0.} = signalC(7)
    var runs = 0
    discard createRoot:
      createEffect proc() =
        discard s()
        inc runs
    check runs == 1
    s.set(7)
    check runs == 1
    s.set(8)
    check runs == 2

suite "createEffect (legacy)":

  test "does not re-run for untracked signal changes":
    let tracked {.height: 0.} = signalC(0)
    let untracked {.height: 0.} = signalC(0)
    var runs = 0
    discard createRoot:
      createEffect proc() =
        discard tracked()
        inc runs
    untracked.set(99)
    check runs == 1
    tracked.set(1)
    check runs == 2

suite "createEffect: shared-signal reentrancy (legacy)":

  test "observer that adds a new observer fires next cycle, not this one":
    # Contract: structural mutations to the observer set during a
    # notify cycle are visible on subsequent cycles, never the
    # current one. Encoded in ObserverList.iterRO.
    var sig = signalC(0)
    var initialRuns = 0
    var newObserverRuns = 0
    discard createRoot:
      createEffect proc() =
        discard sig()
        inc initialRuns
        if initialRuns == 2:
          # second run of the initial observer adds a new observer
          createEffect proc() =
            discard sig()
            inc newObserverRuns
    check initialRuns == 1
    sig.set(1)                    # triggers initial-observer rerun
    # The newly-created observer ran once on its own creation
    # (createEffect always invokes the body immediately), but it
    # should NOT have been included in the current notify cycle.
    check initialRuns == 2
    check newObserverRuns == 1    # only the initial-creation run

  test "observer that disposes itself during run doesn't break siblings":
    let sig {.height: 0.} = signalC(0)
    var aRuns, bRuns, cRuns = 0
    var aScope: Scope
    let root = createRoot:
      aScope = newScope(parent = currentScope.value)
      withScope(aScope):
        createEffect proc() =
          discard sig()
          inc aRuns
          if aRuns >= 2: dispose(aScope)
      createEffect proc() =
        discard sig()
        inc bRuns
      createEffect proc() =
        discard sig()
        inc cRuns
    check aRuns == 1 and bRuns == 1 and cRuns == 1
    sig.set(1)                    # a disposes itself; b and c must still fire
    check aRuns == 2
    check bRuns == 2
    check cRuns == 2
    sig.set(2)                    # a is disposed; b and c continue
    check aRuns == 2              # frozen
    check bRuns == 3
    check cRuns == 3
    dispose(root)

suite "createComputed (legacy)":

  test "computed disposes with its scope":
    let count {.height: 0.} = signalC(0)
    var computed: Signal[int]
    let root = createRoot:
      computed = createComputed proc(): int = count() * 3
    check computed.get() == 0
    dispose(root)
    # After dispose the computed stops tracking; it holds its last value.
    count.set(7)
    check computed.get() == 0
