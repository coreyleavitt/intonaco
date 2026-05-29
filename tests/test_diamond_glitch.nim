{.experimental: "callOperator".}

## De-risk spike (consistency RFC, direction 1): does the substrate glitch today?
##
## The diamond:
##
##       a            a = signal
##      / \
##     b   c          b = computed(a),  c = computed(a)   — both mirror a
##      \ /
##       d            d = effect reading both b and c
##
## Because b and c both equal a, an observer of (b, c) must ALWAYS see
## b == c. A glitch is an intermediate state where the effect fires after
## b updated but before c did — observing (b_new, c_old), i.e. b != c, a
## state that never logically existed.
##
## Under the shipping eager depth-first `notify`, writing `a` runs b's
## computation (which notifies d → d sees b_new, c_old), THEN c's. So d
## fires once on the glitch and once correct. This test asserts the glitch
## never happens; it is EXPECTED TO FAIL against the current substrate and
## becomes the red→green target for the height-ordered worklist scheduler.

import std/unittest
import intonaco/reactive

suite "consistency spike — diamond glitch-freedom":

  test "effect never observes a mixed-version (b != c) state":
    signals:
      a = 0
    computed b, [a]: a
    computed c, [a]: a

    var seen: seq[(int, int)] = @[]
    discard createRoot:
      effect [b, c]: seen.add (b, c)

    a.set(1)
    a.set(2)

    # b and c both mirror a, so every observed pair must be equal.
    # A (1,0)/(2,1)-shaped pair is the glitch.
    var glitches: seq[(int, int)] = @[]
    for pair in seen:
      if pair[0] != pair[1]:
        glitches.add pair
    check glitches.len == 0

  test "effect fires once per settled change (no redundant glitch fire)":
    # Corollary: with a glitch, d fires twice per write (once mid-cascade,
    # once settled). Exactly-once is the stronger guarantee the scheduler
    # should restore. Documented here; also expected to fail today.
    signals:
      a = 0
    computed b, [a]: a
    computed c, [a]: a

    var fires = 0
    discard createRoot:
      effect [b, c]: (discard b; discard c; inc fires)

    fires = 0          # ignore the initial run
    a.set(1)
    check fires == 1   # today: 2 (glitch fire + settled fire)
