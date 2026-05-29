{.experimental: "callOperator".}

## De-risk probe (consistency RFC): is the deferred-write / cross-propagation-
## quiescence machinery actually needed, or does the *uniform* worklist
## (every write enqueues into the current height-ordered drain, no
## ckEffect-defers-to-a-fresh-propagation) already handle effect-feedback?
##
## The full 569-test suite passed with the uniform model and NO deferred-write
## distinction — a strong hint that a whole section of the RFC is unnecessary
## complexity. These cases probe the patterns the deferred-write design was
## meant to handle. If they're all correct + exactly-once, cut that section.

import std/unittest
include intonaco/reactive_internal

suite "effect-feedback under the uniform worklist":

  test "forward: effect writes a downstream signal a computed reads":
    let a = signalC(0)
    let b = signalC(0)
    createEffect(proc() = b.set(a() * 2))          # effect: b = 2a
    let c = createComputed(proc(): int = b() + 1)  # c = b + 1
    var seen: seq[int] = @[]
    createEffect(proc() = seen.add c())
    a.set(5)
    check b() == 10
    check c() == 11
    check seen[^1] == 11           # final value correct, no stale-b glitch

  test "contractive self-feedback terminates at the bound":
    let a = signalC(0)
    createEffect(proc() =
      let v = a()
      if v < 10: a.set(v + 1))     # increments a toward 10, then stops
    check a() == 10                # ran the cascade to quiescence synchronously

  test "forward chain fires the leaf observer exactly once per change":
    let trigger = signalC(1)
    let mirror = signalC(0)
    createEffect(proc() = mirror.set(trigger()))         # effect side-write
    let doubled = createComputed(proc(): int = mirror() * 2)
    var fires = 0
    createEffect(proc() = (discard doubled(); inc fires))
    fires = 0                       # ignore initial run
    trigger.set(7)
    check mirror() == 7
    check doubled() == 14
    echo "  [probe] leaf observer fired ", fires, " time(s) for one change"
    check fires == 1                # exactly-once through effect→sig→computed→effect

  test "diamond with an effect side-write in one arm stays glitch-free":
    # a feeds b (computed) and an effect that writes b2; d reads b and b2.
    let a = signalC(0)
    let b = createComputed(proc(): int = a())
    let b2 = signalC(0)
    createEffect(proc() = b2.set(a()))     # effect mirrors a into b2
    var glitches = 0
    createEffect(proc() =
      if b() != b2(): inc glitches)        # b and b2 both mirror a → must agree
    a.set(1)
    a.set(2)
    check glitches == 0
