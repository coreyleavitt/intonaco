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

  test "a value already dequeued by the getter when cancel is processed is not lost":
    ## Targets Window 2 (`if getFut.completed: putNoWait(getFut.read)` in
    ## mailbox.nim). Pushing immediately before cancelling — same tick, no
    ## intervening await — gives the raw `AsyncQueue` getter a chance to
    ## dequeue the value before the cancellation is delivered to
    ## `nextEvent`'s own future, so `nextEvent` still unwinds through
    ## `except CancelledError` with a getter that already has a value in
    ## hand rather than one still parked on the queue (Window 1).
    ##
    ## Which exact branch fires isn't observable from the public API (future
    ## internals aren't exposed), so this pins the black-box invariant the
    ## fix guarantees instead: a value can never be lost across a cancel
    ## that races a push, regardless of ordering.
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[int]()
      let f = m.nextEvent()
      m.push(42)
      f.cancelSoon()
      await sleepAsync(20.milliseconds)
      check f.cancelled
      let g = m.nextEvent()
      let ok = await g.withTimeout(1.seconds)
      check ok
      if ok: check g.read == 42
    waitFor body()

  test "a push landing while a losing nextEvent unwinds through cancelAndWait is not dropped, and no stray CancelledError surfaces later":
    ## Cancel a `nextEvent()` parked on an EMPTY mailbox (so it takes the
    ## `await getFut.cancelAndWait()` path — Window 1's entry point), then
    ## push at varying delays relative to the cancel so the push can land at
    ## different points during the unwind: same tick, and after 1-3 event
    ## loop turns. Across every offset the pushed value must reach a live
    ## waiter, and the subsequent unrelated `nextEvent`/`withTimeout` await
    ## must complete cleanly rather than raise a stray `CancelledError` (the
    ## accumulation symptom mailbox.nim's docstring describes).
    proc body() {.async: (raises: [Exception]).} =
      for delayTicks in 0 .. 3:
        let m = newMailbox[int]()
        let f = m.nextEvent()
        f.cancelSoon()
        for _ in 0 ..< delayTicks:
          await sleepAsync(0.milliseconds)
        m.push(200 + delayTicks)
        await sleepAsync(20.milliseconds)
        check f.cancelled
        let g = m.nextEvent()
        let ok = await g.withTimeout(1.seconds)
        check ok
        if ok: check g.read == 200 + delayTicks
    waitFor body()

  test "two parked consumers: cancelling one and pushing delivers to the live consumer, not the cancelled one":
    ## Two `nextEvent()` calls parked on the same mailbox (`f1` registered
    ## before `f2`, so `f1`'s getter is FIFO-ahead). Cancelling `f1` then
    ## pushing must not let the abandoned getter FIFO-absorb the value ahead
    ## of the live `f2` — this is Window 1's `cancelAndWait` doing its job
    ## with a live second waiter present instead of zero waiters. A second
    ## push must independently reach a fresh third consumer.
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[int]()
      let f1 = m.nextEvent()
      let f2 = m.nextEvent()
      f1.cancelSoon()
      m.push(7)
      await sleepAsync(20.milliseconds)
      check f1.cancelled
      check f2.completed
      if f2.completed: check f2.read == 7
      let f3 = m.nextEvent()
      m.push(8)
      let ok3 = await f3.withTimeout(1.seconds)
      check ok3
      if ok3: check f3.read == 8
    waitFor body()

  test "close() completes a single parked nextEvent with MailboxClosedError":
    ## The close() path — previously exercised by no intonaco test. A
    ## `nextEvent` parked on an empty mailbox is racing `race(getFut,
    ## m.closing)`; `close()` completing `m.closing` must win that race and
    ## surface `MailboxClosedError` to the waiter.
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[int]()
      let f = m.nextEvent()
      m.close()
      let settled = await f.withTimeout(1.seconds)
      check settled
      check f.failed
      if f.failed: check f.error of MailboxClosedError
    waitFor body()

  test "close() completes ALL concurrently-parked nextEvents with MailboxClosedError":
    ## Same close() path, multiple waiters: `close()` must complete every
    ## parked `nextEvent`, not just the FIFO-first one.
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[int]()
      let f1 = m.nextEvent()
      let f2 = m.nextEvent()
      let f3 = m.nextEvent()
      m.close()
      let ok1 = await f1.withTimeout(1.seconds)
      let ok2 = await f2.withTimeout(1.seconds)
      let ok3 = await f3.withTimeout(1.seconds)
      check ok1 and ok2 and ok3
      check f1.failed and f2.failed and f3.failed
      if f1.failed: check f1.error of MailboxClosedError
      if f2.failed: check f2.error of MailboxClosedError
      if f3.failed: check f3.error of MailboxClosedError
    waitFor body()

  test "after close(), push is silently dropped and a fresh nextEvent raises immediately":
    ## The other half of the close() contract: `push` after `close()` is a
    ## no-op (not queued for a later waiter), and `nextEvent` called after
    ## `close()` raises `MailboxClosedError` at entry rather than parking.
    proc body() {.async: (raises: [Exception]).} =
      let m = newMailbox[int]()
      m.close()
      m.push(99)
      let f = m.nextEvent()
      let ok = await f.withTimeout(1.seconds)
      check ok
      check f.failed
      if f.failed: check f.error of MailboxClosedError
    waitFor body()
