{.experimental: "callOperator".}

## De-risk spike: (1) the backward-feedback case the deferred-write design
## was the last possible justification for, and (2) genuine depth>1 graphs —
## the shape the substrate exists to enable, which the real corpus doesn't
## build yet (0 createComputed in fresco+amoxtli) but which the scheduler
## must handle correctly.

import std/unittest
include intonaco/reactive_internal

suite "backward feedback under the uniform worklist":

  test "effect reads deep, writes shallow (cycle); re-settles + terminates":
    # `deep` observes `a` (height 1). The effect observes `deep` (height 2)
    # and writes `a` — a backward edge: a's observer `deep` is at a LOWER
    # height than the writing effect. This is the one case the deferred-
    # write machinery was the last candidate justification for.
    let a = signalC(0)
    let deep = createComputed(proc(): int = a())
    var effectRuns = 0
    createEffect(proc() =
      inc effectRuns
      let d = deep()
      if d < 3: a.set(d + 1))      # contractive: stops at 3
    check a() == 3                  # cascade re-settled correctly to the fixpoint
    check deep() == 3
    echo "  [probe] backward-feedback effect ran ", effectRuns, " times"
    # Multiple fires are CORRECT here (each is a real new value); exactly-once
    # holds only for acyclic graphs. The point: uniform handles it — no
    # deferred-write mechanism needed, terminates for contractive cycles.

suite "depth>1 graphs (the shape the substrate is FOR)":

  test "depth-4 stacked diamonds stay glitch-free and exactly-once":
    #        a              h0
    #       / \
    #      b   c            h1   (both mirror a)
    #       \ /
    #        d = b + c      h2   (diamond-1 apex)
    #       / \
    #      e   f            h3   (both mirror d)
    #       \ /
    #        g (effect)     h4   (diamond-2 apex)
    let a = signalC(0)
    let b = createComputed(proc(): int = a())
    let c = createComputed(proc(): int = a())
    let d = createComputed(proc(): int = b() + c())
    let e = createComputed(proc(): int = d())
    let f = createComputed(proc(): int = d())
    var mismatches = 0
    var gFires = 0
    createEffect(proc() =
      inc gFires
      if e() != f(): inc mismatches)   # e and f both = d → must always agree
    gFires = 0                          # ignore initial run
    a.set(1)
    a.set(2)
    check mismatches == 0               # no glitch at any depth
    check d() == 4                      # 2 + 2
    echo "  [probe] depth-4 apex effect fired ", gFires, " times for 2 changes"
    check gFires == 2                   # exactly once per settled change, at h4

  test "wider diamond: one apex over many height-1 mirrors":
    let a = signalC(0)
    let m1 = createComputed(proc(): int = a())
    let m2 = createComputed(proc(): int = a())
    let m3 = createComputed(proc(): int = a())
    let m4 = createComputed(proc(): int = a())
    var seen: seq[(int, int, int, int)] = @[]
    createEffect(proc() = seen.add (m1(), m2(), m3(), m4()))
    a.set(1)
    a.set(2)
    # every mirror equals a, so every observed tuple must be all-equal
    var glitches = 0
    for t in seen:
      if not (t[0] == t[1] and t[1] == t[2] and t[2] == t[3]): inc glitches
    check glitches == 0
