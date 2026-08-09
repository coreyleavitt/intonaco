## Coroutine-context isolation canaries for intonaco's contextVar keys.
##
## TRIMMED port of fresco's tests/integration/test_context_isolation.nim
## (originally the "load-bearing proof" that chronos's dispatcher
## captures/restores context at every scheduling site, #37). Generic
## dispatcher capture mechanics are now owned by the chronos fork's own
## suite — _deps/chronos/tests/testcontextvarsasync.nim (suites
## "contextvars: async propagation", "scheduling-site capture coverage",
## "fast-path pins", "scheduling scenario pins") — so this file keeps
## only what is intonaco-specific: that the substrate's keys
## (`currentScope`, `currentSpeculative`, `parallelCollector`) hold
## isolated per-task values across interleaved awaits and rollbacks.
##
## Dropped from the original (superseded upstream):
##   - "setTimer callback fires under the scope captured at
##     registration" → chronos "sleepAsync callback fires with the
##     registrant's binding" (the explicit setTimer-site pin) plus the
##     pinsCaptureSite family (callSoon / callIdle / closeHandle / ...).
##   - "Future.addCallback fires under the scope captured at
##     registration" → chronos "addCallback on an already-finished
##     future captures the caller's binding, not the completer's" plus
##     the await-propagation tests ("binding survives multiple
##     sequential awaits", "concurrent tasks with interleaved
##     suspensions each see their own binding"), which exercise the
##     pending-future addCallback capture path every `await` rides.
##
## The keys are first-class `ContextVar[T]` values: reads are
## `key.value`, bindings are `key.withValue(x): body` — `withScope`,
## `speculative:` and `parallel:` wrap that internally. If chronos ever
## rebases away from the contextVar primitive, or a substrate binder
## stops routing through it, these canaries turn red.

import std/[tables, unittest]
include intonaco/reactive_internal

suite "context isolation: currentScope across interleaved awaits":

  setup:
    globalJournal = newJournal()

  teardown:
    resetJournal()

  test "task A writes x and y around await; task B writes z during await; attribution stays separate":
    # The acceptance criterion from #37: journal writes attribute to the
    # taskId of the scope each task was spawned with (`currentScope.value`
    # at write time), not to whichever task last touched the key.
    proc body() {.async: (raises: [Exception]).} =
      proc taskA() {.async.} =
        let x {.height: 0.} = signalC(0, label = "x")
        x.set(1)
        await sleepAsync(20.milliseconds)
        let y {.height: 0.} = signalC(0, label = "y")
        y.set(2)

      proc taskB() {.async.} =
        let z {.height: 0.} = signalC(0, label = "z")
        z.set(3)

      let mA = spawn taskA()
      # Give A a chance to start and reach its sleepAsync, then
      # spawn B during A's suspension.
      await sleepAsync(5.milliseconds)
      let mB = spawn taskB()
      await mB.wait()
      await mA.wait()

      # Group writes by signal label and assert attribution.
      var seen: Table[string, TaskId]
      for e in globalJournal.byKind(ekSignalWrite):
        seen[e.signalLabel] = e.taskId
      check seen["x"] == mA.scope.taskId
      check seen["y"] == mA.scope.taskId
      check seen["z"] == mB.scope.taskId

    waitFor body()

suite "context isolation: currentSpeculative across interleaved awaits":

  setup:
    globalJournal = newJournal()

  teardown:
    resetJournal()

  test "task A's speculative frame doesn't capture task B's writes during await":
    # If the `currentSpeculative` binding leaked across coroutines, B's
    # set() would land in A's frame and get rolled back. Per-task key
    # isolation is what makes B's `currentSpeculative.value` nil (B is
    # outside any speculative: block), independent of A's binding.
    proc body() {.async: (raises: [Exception]).} =
      let a {.height: 0.} = signalC(10)
      let b {.height: 0.} = signalC(20)

      proc taskA(): Future[void] {.async: (raises: [Exception]).} =
        discard speculative:
          a.set(99)
          await sleepAsync(20.milliseconds)
          # Don't commit — the block exits with rollback on a.

      proc taskB() {.async.} =
        # B is OUTSIDE any speculative block. Its write should be
        # canonical and survive A's rollback.
        b.set(77)

      let mA = spawn taskA()
      await sleepAsync(5.milliseconds)
      let mB = spawn taskB()
      await mB.wait()
      await mA.wait()

      check a.peek() == 10     # A rolled back
      check b.peek() == 77     # B survived — wasn't captured by A's frame

    waitFor body()

suite "context isolation: parallelCollector across interleaved awaits":

  setup:
    globalJournal = newJournal()

  teardown:
    resetJournal()

  test "task B's spawn doesn't land in task A's parallel: collector":
    # A is inside parallel:. It spawns one child, awaits, spawns
    # another. Between those spawns, task B (independent) spawns
    # its own work. If the `parallelCollector` binding leaked across
    # coroutines, B's spawn would land in A's collector and A would
    # hang waiting for B's task to complete (it might or might never).
    proc body() {.async: (raises: [Exception]).} =
      var aChildren = 0
      var bRan = false

      proc childA() {.async.} =
        await sleepAsync(2.milliseconds)
        inc aChildren

      proc childB() {.async.} =
        bRan = true

      proc taskA(): Future[void] {.async: (raises: [Exception]).} =
        parallel:
          discard spawn childA()
          await sleepAsync(15.milliseconds)
          discard spawn childA()

      let mA = spawn taskA()
      # During A's mid-parallel sleep, spawn B's independent task.
      await sleepAsync(5.milliseconds)
      let mB = spawn childB()
      await mB.wait()
      await mA.wait()

      check bRan                   # B completed on its own
      check aChildren == 2         # A waited for exactly its 2 children
      # Strong invariant: had B leaked into A's collector, A's
      # parallel: block would have awaited B too — but B had no
      # journal/scope side-effect on A.

    waitFor body()

suite "context isolation: deeper interleaves":

  setup:
    globalJournal = newJournal()

  teardown:
    resetJournal()

  test "three tasks ping-pong with awaits; every write attributes to its origin":
    # A two-task test catches "binding survives one await"; three
    # tasks with each suspending after every write catches "binding
    # was captured fresh on EACH resumption, not reused stale from the
    # last one" — asserted here through intonaco's journal attribution
    # rather than a bare probe (the generic mechanics are pinned
    # upstream in testcontextvarsasync.nim).
    proc body() {.async: (raises: [Exception]).} =
      proc taskN(label: string) {.async.} =
        let s1 = signalC(0, label = label & "1")
        s1.set(1)
        await sleepAsync(2.milliseconds)
        let s2 = signalC(0, label = label & "2")
        s2.set(2)
        await sleepAsync(2.milliseconds)
        let s3 = signalC(0, label = label & "3")
        s3.set(3)

      let mA = spawn taskN("A")
      let mB = spawn taskN("B")
      let mC = spawn taskN("C")
      await mA.wait()
      await mB.wait()
      await mC.wait()

      # For each (task, label-prefix) pair, every write under that
      # prefix must attribute to that task's id — no cross-contamination.
      var byLabel: Table[string, TaskId]
      for e in globalJournal.byKind(ekSignalWrite):
        byLabel[e.signalLabel] = e.taskId
      for suffix in ["1", "2", "3"]:
        check byLabel["A" & suffix] == mA.scope.taskId
        check byLabel["B" & suffix] == mB.scope.taskId
        check byLabel["C" & suffix] == mC.scope.taskId

    waitFor body()
