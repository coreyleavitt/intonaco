## animationsIdle — read-only frame-animation probe.
##
## Black-box: imports the public consumer surface (`intonaco/reactive`),
## not the animation module internals directly, so this test also proves
## the accessor actually reaches consumers through the include-based
## seal's export chain (reactive.nim -> reactive_internal.nim -> included
## reactive/dsl/animation.nim).
##
## Polarity note (RFC rfc-headless-quiescence.md §Vocabulary): the accessor
## is `animationsIdle`, deliberately NOT `animationsPending` — idle-positive
## polarity uniform with `reactiveIdle`/`surfaceIdle`, so consumer
## conjunctions are a flat AND with no hand negation. Do not invert it.
##
## Deterministic by construction: driving a tween to completion needs the
## real frame clock (real sleeps), so "idle again" is exercised via
## `stopFrameClock()` — a synchronous, public disposal path
## (`frameAnimations.setLen(0)`) — rather than a timed wait.

{.experimental: "callOperator".}

import std/unittest
import chronos
import intonaco/reactive

suite "animationsIdle":

  teardown:
    stopFrameClock()

  test "1. idle at rest — before any animation exists":
    check animationsIdle()

  test "2. not idle while a tween is registered":
    let s {.height: 0.} = signalC(0.0)
    discard tween(s, 1.0, 100.milliseconds, esLinear)
    check not animationsIdle()

  test "3. idle again once the live animation is disposed":
    let s {.height: 0.} = signalC(0.0)
    discard tween(s, 1.0, 100.milliseconds, esLinear)
    check not animationsIdle()
    stopFrameClock()
    check animationsIdle()

  test "4. not idle while a spring is registered, idle again once disposed":
    let s {.height: 0.} = signalC(0.0)
    check animationsIdle()
    discard spring(s, 1.0)
    check not animationsIdle()
    stopFrameClock()
    check animationsIdle()
