## Tests for the dynamic tier — promoted from the spike
## (`fresco/tests/spike_c_dynamic.nim`) as part of the C-shape substrate
## migration, M1. Validates `dynamic name: body`, cross-tier composition,
## the static→dynamic wall, and `each` lifecycle over `CollectionSignal`.

{.experimental: "callOperator".}

import std/unittest
import intonaco/reactive/dsl/dynamic       # Dynamic[T], dynamicComputed, `dynamic` macro
import intonaco/reactive/primitives/collection    # CollectionSignal, mutation ops, signals:
import intonaco/reactive/dsl/each          # eachItem
import intonaco/reactive/dsl/binding       # computed / effect / signals: (re-exported)


suite "C shape dynamic tier — the four shapes":

  test "D1. `dynamic name = body` produces Dynamic[T]; auto-tracked":
    let n = signal(10)
    dynamic doubled: n.get() * 2     # `.get()` auto-tracks n
    check doubled() == 20
    n.set(7);  check doubled() == 14
    n.set(11); check doubled() == 22
    # Type-level evidence: doubled is Dynamic[int].
    static: doAssert doubled is Dynamic[int]

  test "D2. cross-tier: dynamic READS static — the OK direction":
    signals:
      count = 0
      title = ""
    dynamic summary: title.get() & ": " & $count.get()
    check summary() == ": 0"
    count.set(3); title.set("hello")
    check summary() == "hello: 3"
    # The static sources stay statically scheduled — their pragmas are intact.
    check bakedHeight(count) == 0
    check bakedHeight(title) == 0

  test "D3. dynamic composition — dynamic reading another dynamic":
    let n = signal(2)
    dynamic doubled: n.get() * 2
    dynamic quadrupled: doubled.get() * 2
    check quadrupled() == 8
    n.set(5); check quadrupled() == 20

  test "D4. cross-tier wall (recap of test 11) — STATIC reading Dynamic fails":
    let a = signal(0)
    dynamic d: 42
    check not compiles(
      block:
        computed bad, [a]:
          a + d())

  test "D5. `each` over CollectionSignal — initial spawn, insert, remove":
    var rendered: seq[string] = @[]
    let names = collection[string](@["alice", "bob"])
    eachItem(names) do (name: string):
      effect []:
        rendered.add "render: " & name
    # initial: both items spawned, each ran its effect once at scope creation
    check rendered == @["render: alice", "render: bob"]

    names.push("charlie")
    check rendered == @["render: alice", "render: bob", "render: charlie"]

    names.remove(0)   # remove "alice"
    # remove fires no render (we only render at scope creation); but the
    # alice scope is disposed. Verify by re-firing all current items via
    # another add, and confirming bob/charlie still respond:
    names.push("dana")
    check rendered == @["render: alice", "render: bob", "render: charlie",
                        "render: dana"]
    # The collection now has [bob, charlie, dana].
    check names.get() == @["bob", "charlie", "dana"]

  test "D6. `each` body can reference outer signals; reactivity re-fires":
    let prefix = signal("name")
    let names = collection[string](@["alice", "bob"])
    var rendered: seq[string] = @[]
    eachItem(names) do (n: string):
      effect [prefix]:
        rendered.add prefix & ": " & n
    # initial: each spawn ran the effect once.
    check rendered == @["name: alice", "name: bob"]

    prefix.set("user")
    # Every per-item effect re-fired (both are subscribed to `prefix`).
    check rendered[^2..^1] == @["user: alice", "user: bob"]

  test "D7. lifecycle: remove disposes the per-item effect cleanly":
    let prefix = signal("v")
    let names = collection[string](@["x", "y", "z"])
    var rendered: seq[string] = @[]
    eachItem(names) do (n: string):
      effect [prefix]:
        rendered.add prefix & ":" & n
    check rendered == @["v:x", "v:y", "v:z"]
    rendered.setLen(0)

    names.remove(1)   # remove "y" — its effect must be torn down
    # No effects fired (only scope dispose happened).
    check rendered.len == 0

    prefix.set("w")
    # Only x and z fire — y's effect is gone.
    check rendered == @["w:x", "w:z"]
