## Static-tier reactive bindings — the `computed` / `effect` macros.
## (Promoted from `fresco/tests/spike_c_shape.nim` as part of the C-shape
## substrate migration, M1.)

{.experimental: "callOperator".}

import std/unittest
import intonaco/reactive/subscribable   # for `Subscribable(x).height` runtime-field tests
import intonaco/reactive/dynamic        # for the cross-tier wall test
import intonaco/reactive/binding

# ---- The four core behaviors, in the SUGARED form -----------------------

suite "C shape (sugared): the four core behaviors":

  test "1. counter — source + derived + effect":
    var rendered: seq[string] = @[]
    let count = signal(0)
    computed doubled, [count]:
      count * 2
    effect [count, doubled]:
      rendered.add "count=" & $count & " doubled=" & $doubled
    count.set(1); count.set(2)
    check rendered == @[
      "count=0 doubled=0",
      "count=1 doubled=2",
      "count=2 doubled=4",
    ]

  test "2. diamond — glitch-free":
    let a = signal(0)
    computed b, [a]: a
    computed c, [a]: a
    var seen: seq[(int, int)] = @[]
    effect [b, c]:
      seen.add (b, c)
    a.set(1); a.set(2)
    for p in seen: check p[0] == p[1]
    check seen.len == 3

  test "3. heights compose without inference (4-deep)":
    let a = signal(0)
    computed b, [a]: a
    computed c, [b]: b
    computed d, [c]: c
    check Subscribable(b).height == 1
    check Subscribable(c).height == 2
    check Subscribable(d).height == 3
    a.set(42); check d.peek() == 42

  test "4a. missed dep DIRECT → COMPILE ERROR (the stale footgun is closed)":
    let a = signal(10)
    let b = signal(100)
    # Pre-fix: declaring `[a]` while the body reads `b` was a silent stale
    # bug surface. The `noUndeclaredSignals` walker now rejects it at sem
    # time — `b` resolves to a `Signal[int]` (declared deps were shadowed
    # to int, so any remaining Signal-typed sym is by construction an
    # undeclared read).
    check not compiles(
      block:
        effect [a]:
          discard a + b.peek())
    # Correct: declare both. Both shadowed as int; no Signal-typed syms
    # remain in the body; compiles cleanly.
    var rendered: seq[int] = @[]
    effect [a, b]:
      rendered.add (a + b)
    check rendered == @[110]
    b.set(200); check rendered == @[110, 210]
    a.set(20);  check rendered == @[110, 210, 220]

  test "4c. opaque callee in body → COMPILE ERROR (RootEffect gate)":
    let a = signal(0)
    # An indirect call via a proc value: the compiler can't see through it,
    # so the inferred tag set falls to `RootEffect`. A reactive read could
    # be hiding inside. The walker rejects it unless the callee declares
    # `{.forbids: [ReactiveRead, ReactiveWrite].}`.
    var fn: proc(): int = proc(): int = 42
    check not compiles(
      block:
        effect [a]:
          discard a + fn())

  test "4b. missed dep TRANSITIVE (helper reads a signal) → COMPILE ERROR":
    let hidden = signal(7)
    proc readsHidden(): int = hidden.get() + 1   # tag-inferred ReactiveRead
    let a = signal(10)
    # The body never names `hidden` directly — the transitive read is hidden
    # inside `readsHidden`. The walker catches it via Nim's effect inference:
    # `readsHidden` has `ReactiveRead` in its inferred tags, and isn't `peek`.
    check not compiles(
      block:
        effect [a]:
          discard a + readsHidden())

# ---- A panel-shaped example: the maintenance feel -----------------------

suite "C shape (sugared): a small fresco-style panel":

  test "5. todo-progress panel — 2 sources, 3 computeds, 1 render":
    var painted: seq[string] = @[]
    let items = signal(10)
    let done  = signal(3)

    computed remaining, [items, done]:
      items - done
    computed pct, [items, done]:
      if items == 0: 0 else: (100 * done) div items
    computed label, [items, done, pct]:
      $done & " of " & $items & " done (" & $pct & "%)"

    effect [label]:
      painted.add label

    check painted == @["3 of 10 done (30%)"]
    done.set(5);   check painted[^1] == "5 of 10 done (50%)"
    done.set(10);  check painted[^1] == "10 of 10 done (100%)"
    items.set(12); check painted[^1] == "10 of 12 done (83%)"
    check remaining.peek() == 2

  test "6. refactor: thread a new `prefix` source through the panel":
    ## The maintenance feel. Compared to test 5, three lines change and one
    ## new binding appears — the diff IS the dependency-graph delta.
    ##
    ##     computed remaining, [items, done]: items - done             (unchanged)
    ##     computed pct,       [items, done]: ...                      (unchanged)
    ##   - computed label, [items, done, pct]:
    ##   + computed label, [items, done, pct, prefix]:
    ##         prefix & ": " & ...                                     (uses new dep)
    ##   + computed summary, [label, items]:    label & "  [" & $items & " total]"
    ##   - effect [label]: painted.add label
    ##   + effect [summary]: painted.add summary
    ##
    ## No hidden subscriptions to discover. No inference to re-verify. No
    ## stale-bug surface beyond the visible brackets.
    var painted: seq[string] = @[]
    let items  = signal(10)
    let done   = signal(3)
    let prefix = signal("TASKS")   # new source

    computed remaining, [items, done]:
      items - done
    computed pct, [items, done]:
      if items == 0: 0 else: (100 * done) div items
    computed label, [items, done, pct, prefix]:                # +prefix
      prefix & ": " & $done & "/" & $items & " (" & $pct & "%)"
    computed summary, [label, items]:                          # NEW
      label & "  [" & $items & " total]"

    effect [summary]:
      painted.add summary

    check painted == @["TASKS: 3/10 (30%)  [10 total]"]
    prefix.set("DONE")
    check painted[^1] == "DONE: 3/10 (30%)  [10 total]"
    done.set(7)
    check painted[^1] == "DONE: 7/10 (70%)  [10 total]"
    items.set(12)
    check painted[^1] == "DONE: 7/12 (58%)  [12 total]"

  test "7. heights through the panel — composition is transparent":
    let items  = signal(0)
    let done   = signal(0)
    let prefix = signal("")
    computed remaining, [items, done]:                  # h=1
      items - done
    computed pct, [items, done]:                        # h=1
      if items == 0: 0 else: (100 * done) div items
    computed label, [items, done, pct, prefix]:         # h=2 (pct is h=1)
      prefix & " " & $done & "/" & $items & " (" & $pct & "%)"
    computed summary, [label, items]:                   # h=3 (label is h=2)
      label & "  [" & $items & " total]"
    check Subscribable(remaining).height == 1
    check Subscribable(pct).height == 1
    check Subscribable(label).height == 2
    check Subscribable(summary).height == 3

# ---- The HEADLINE: heights resolved at COMPILE TIME, baked as pragmas ----

suite "C shape: COMPILE-TIME height resolution (the real goal)":

  test "8. baked sources compose statically through `computed`":
    ## With baked sources (via `signals:`), the macros resolve each dep's
    ## `{.height.}` pragma at sem time, compose, and bake the result onto
    ## the new binding. `static:` blocks below FAIL COMPILATION if the
    ## pragmas aren't there — proving the resolution is compile-time, not
    ## runtime. (-1 means no pragma was baked.)
    signals:
      count = 0
      title = ""
    computed doubled, [count]:
      count * 2
    computed labeled, [count, title]:
      title & ": " & $count
    computed summary, [count, doubled, title]:
      title & ": " & $count & " (x2=" & $doubled & ")"
    # `bakedHeight` is a macro emitting an int literal at SEM TIME — these
    # checks therefore compare COMPILE-TIME-KNOWN values, not runtime fields.
    check bakedHeight(count) == 0
    check bakedHeight(doubled) == 1
    check bakedHeight(labeled) == 1
    check bakedHeight(summary) == 2
    # Runtime sanity:
    count.set(7); title.set("count")
    check summary.peek() == "count: 7 (x2=14)"

  test "9. a 5-deep chain bakes correct heights all the way down":
    signals:
      a = 0
    computed b, [a]: a
    computed c, [b]: b
    computed d, [c]: c
    computed e, [d]: d
    check bakedHeight(a) == 0
    check bakedHeight(b) == 1
    check bakedHeight(c) == 2
    check bakedHeight(d) == 3
    check bakedHeight(e) == 4
    a.set(42); check e.peek() == 42

  test "11. cross-tier wall: a static `computed` can't read a `Dynamic[T]`":
    ## The dynamic tier already exists in intonaco as `Dynamic[T]` — a
    ## value built on the runtime floor. The walker generalizes to flag any
    ## `Signal[_]` OR `Dynamic[_]` sym in a static body. Reading a Dynamic
    ## value from a static `computed`/`effect` is a compile error — the
    ## type-level quarantine that keeps the static fragment sound.
    let d: Dynamic[int] = dynamicComputed(proc(): int = 42)
    let a = signal(0)
    check not compiles(
      block:
        computed bad, [a]:
          a + d())

  test "10. unbaked source → runtime fallback (non-strict path)":
    ## A plain `signal(5)` carries no `{.height.}` pragma. Under non-strict
    ## the macro falls back to runtime composition (no pragma baked on the
    ## result either — it leaves the static fragment). Glitch-free at runtime
    ## either way; just not provably compile-time-scheduled.
    let raw = signal(5)
    computed doubled, [raw]:
      raw * 2
    check bakedHeight(doubled) == -1       # not in the static fragment
    check doubled.peek() == 10
    raw.set(20); check doubled.peek() == 40
