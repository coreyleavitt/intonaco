## Mailbox cancel-safety: a losing arm of a multi-source `receive:` cancels
## a source's `nextEvent` while it is parked on an EMPTY mailbox.
##
## `nextEvent` awaits `race(getFut, closing)` where `getFut` is a raw
## chronos `AsyncQueue` getter. chronos `race()` does NOT cancel its
## children, so cancelling the (outer) `nextEvent` future leaves `getFut`
## dangling on the queue's FIFO waiter list. `AsyncQueue.wakeupNext`
## serves getters FIFO and skips only *finished* waiters — so the next
## `push` wakes the ABANDONED getter (whose continuation is already dead)
## instead of a live, re-parked getter, and the event is silently dropped.
## A second symptom of the same leak: once ≥2 dead getters accumulate, a
## stray `CancelledError` can surface later at an unrelated `waitFor`.
##
## This is the general primitive-level bug behind amoxtli's off-stream
## permission ask being dropped while a slash-command menu was open (its
## receive loop consumes a key on `stream`, making the mailbox the
## cancelled loser, then re-parks and expects the next off-stream push to
## win). It is not amoxtli-specific — any `while true: receive: … on mbox …`
## loop where the mailbox loses a race then later wins hits it.

import std/unittest
import chronos
import intonaco/reactive

suite "Mailbox.nextEvent cancel-safety (dangling AsyncQueue getter)":

  test "a push after an empty nextEvent is cancelled reaches the next waiter, not the abandoned getter":
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[int]()
      # Turn 1: park a `nextEvent` on an EMPTY mailbox (the getter registers
      # on the queue), then cancel it the way the multi-source `receive`
      # macro cancels a losing source's `nextEvent` (via `cancelSoon`).
      let f1 = m.nextEvent()
      f1.cancelSoon()
      await sleepAsync(20.milliseconds)   # let the cancellation fully settle
      check f1.cancelled
      # Turn 2: re-park on a fresh `nextEvent`, then push a value.
      let f2 = m.nextEvent()
      m.push(42)
      # Pre-fix: `push` wakes the abandoned turn-1 getter (FIFO); `f2` never
      # completes and this times out. Post-fix: `f2` receives 42.
      let ok = await f2.withTimeout(1.seconds)
      check ok
      if ok: check f2.read == 42
    waitFor body()

  test "consecutive cancelled empty nextEvents don't corrupt a later successful receive":
    ## Accumulation guard (the stray-CancelledError symptom): two cancelled
    ## empty getters in a row, then a push must still land cleanly on a live
    ## waiter and `waitFor` must return normally.
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[int]()
      let a = m.nextEvent()
      a.cancelSoon()
      await sleepAsync(10.milliseconds)
      let b = m.nextEvent()
      b.cancelSoon()
      await sleepAsync(10.milliseconds)
      let c = m.nextEvent()
      m.push(7)
      let ok = await c.withTimeout(1.seconds)
      check ok
      if ok: check c.read == 7
    waitFor body()
