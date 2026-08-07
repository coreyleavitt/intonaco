## reactiveIdle / reactivePendingCount — read-only scheduler probes.
##
## Black-box: imports the public consumer surface (`intonaco/reactive`),
## not the scheduler internals directly, so this test also proves the
## accessors actually reach consumers through the include-based seal's
## export chain (reactive.nim -> reactive_internal.nim -> included
## scheduler.nim).
##
## intonaco propagation is synchronous: a `.set()` drains the
## height-ordered worklist (gQueue) AND the deferred-action queue
## (gDeferred) on the writer's stack before returning. So `reactiveIdle()`
## is only ever observably false from INSIDE propagation (an effect body
## fired mid-drain); from outside propagation it is always true once a
## `.set()` call has returned.

{.experimental: "callOperator".}

import std/unittest
import intonaco/reactive

suite "reactiveIdle / reactivePendingCount":

  test "1. idle at rest — before any signal activity, and after a plain set() returns":
    check reactiveIdle()
    check reactivePendingCount() == 0

    let a {.height: 0.} = signalC(0)
    a.set(1)
    check reactiveIdle()
    check reactivePendingCount() == 0

  test "2. not idle for the whole span of an effect body fired during propagation":
    var idleObservedInsideBody = true    # poisoned true; the body must flip it
    let trigger {.height: 0.} = signalC(0)
    effect [trigger]:
      let _ = trigger    # decide (silence the walker)
      idleObservedInsideBody = reactiveIdle()
    # The initial subscribe-time fire happens outside `notify`'s drain (no
    # write is in flight yet), so it does not exercise gPropagating. Reset
    # and drive a real write, which does.
    idleObservedInsideBody = true
    trigger.set(1)
    check not idleObservedInsideBody   # gPropagating covered it
    check reactiveIdle()               # settled again once set() returned
    check reactivePendingCount() == 0

  test "3. pendingCount counts a sibling observer still queued behind the running one":
    var order: seq[string] = @[]
    var pendingSeenInsideFirst = -1
    let a {.height: 0.} = signalC(0)
    effect [a]:
      let _ = a
      order.add "first"
      pendingSeenInsideFirst = reactivePendingCount()
    effect [a]:
      let _ = a
      order.add "second"
    # Both effects fired once at subscribe time (outside propagation); reset
    # instrumentation and drive a real write so both are height-ordered into
    # gQueue together and the first observes the second still pending.
    order = @[]
    pendingSeenInsideFirst = -1
    a.set(1)
    check order == @["first", "second"]
    check pendingSeenInsideFirst == 1   # the "second" effect, still queued
    check reactiveIdle()
    check reactivePendingCount() == 0
