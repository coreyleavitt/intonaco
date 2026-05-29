{.experimental: "callOperator".}

## mountWhen: reactive conditional mount + the decide/act seam.
##
## Direction (C) of the M10 substrate-design: effect body decides; the
## spawn/cancel runs through runAfterPropagation in a deferred closure.
## The walker accepts because (a) the effect body has no opaque call,
## and (b) the deferred lambda is skipped by the walker.

import std/unittest
import chronos
import intonaco/reactive/primitives/scope
import intonaco/reactive/primitives/signal
import intonaco/task/core
import intonaco/task/mount

proc tick(): Future[void] {.async: (raises: [CancelledError]).} =
  await sleepAsync(0.milliseconds)

suite "mountWhen lifecycle (post-(C) redesign)":

  test "mounts on initial true; cancels on false; remounts on next true":
    proc body() {.async: (raises: [Exception]).} =
      var instantiations = 0
      var lastActive = false
      proc child() {.async: (raises: [Exception]).} =
        inc instantiations
        lastActive = true
        try:
          await sleepAsync(1000.milliseconds)
        finally:
          lastActive = false
      let show = signalC(false)
      let root = createRoot:
        mountWhen(show):
          spawn child()
      # initial false → no mount
      await tick(); await tick()
      check instantiations == 0
      # flip true → spawn through deferred queue
      show.set(true)
      await tick(); await tick()
      check instantiations == 1
      check lastActive
      # flip false → cancel
      show.set(false)
      await tick(); await tick()
      check not lastActive
      # flip true again → second spawn
      show.set(true)
      await tick(); await tick()
      check instantiations == 2
      dispose(root)
    waitFor body()

  test "scope dispose cancels the active mount":
    proc body() {.async: (raises: [Exception]).} =
      var cancelled = false
      proc child() {.async: (raises: [Exception]).} =
        try:
          await sleepAsync(1000.milliseconds)
        except CancelledError:
          cancelled = true
          raise
      let show = signalC(true)
      let root = createRoot:
        mountWhen(show):
          spawn child()
      await tick(); await tick()
      dispose(root)
      await tick(); await tick()
      check cancelled
    waitFor body()
