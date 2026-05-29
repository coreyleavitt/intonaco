{.experimental: "callOperator".}

## runAfterPropagation: the substrate's "decide then act" seam.
##
## An effect body that needs to invoke opaque/async work (task spawn,
## journal-driven I/O) does NOT call it directly — the walker would reject
## any opaque callee. Instead the body decides, then schedules the work via
## runAfterPropagation. The deferred action runs after the worklist drains.

import std/unittest
include intonaco/reactive_internal

suite "runAfterPropagation":

  test "outside propagation: action runs immediately":
    var ran = false
    runAfterPropagation(proc() {.closure.} = ran = true)
    check ran

  test "inside an effect body: action runs after the worklist drains":
    var actionRan = false
    var actionRanBeforeEffectBody = false
    let trigger = signalC(0)
    discard createRoot:
      effect [trigger]:
        let _ = trigger    # decide (silence walker)
        if actionRan: actionRanBeforeEffectBody = true
        runAfterPropagation(proc() {.closure.} =
          actionRan = true)
    # Initial firing on subscribe ran the effect once + the deferred action.
    check actionRan
    check not actionRanBeforeEffectBody   # action observed AFTER body

  test "action that writes a signal re-enters propagation; observer sees new value":
    var lastObserved: int = -1
    let counter = signalC(0)
    let echoSig = signalC(0)
    discard createRoot:
      effect [counter]:
        let v = counter
        runAfterPropagation(proc() {.closure.} =
          echoSig.set(v * 10))
      effect [echoSig]:
        lastObserved = echoSig
    # Initial fire: counter=0 → deferred sets echoSig=0 → observer sees 0
    check lastObserved == 0
    counter.set(3)
    check lastObserved == 30    # deferred batch ran; observer caught up

  test "actions enqueued within a deferred action run in the NEXT batch":
    var trace: seq[string] = @[]
    let s = signalC(0)
    discard createRoot:
      effect [s]:
        let _ = s
        runAfterPropagation(proc() {.closure.} =
          trace.add "first"
          runAfterPropagation(proc() {.closure.} =
            trace.add "nested"))
    s.set(1)
    # Initial fire + the s.set firing produce: first, nested, first, nested
    check trace == @["first", "nested", "first", "nested"]
