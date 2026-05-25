## EXPERIMENT (#49): does tagging `get` with ReactiveRead actually give the
## classifier what it needs — transitive detection via std/effecttraits,
## correct peek/pure exclusion, effectsOf propagation, and FFI conservatism?

import std/[effecttraits, macros]
import intonaco/reactive/signal

let s = signal(0, label = "s")

proc readsSig(): int = s()                       # direct tracked read
proc readsViaHelper(): int = readsSig() + 1      # transitive (depth 2)
proc peeksOnly(): int = s.peek()                 # untracked — must NOT be ReactiveRead
proc pureFn(): int = 21 * 2                       # pure
proc hof(f: proc(): int): int {.effectsOf: f.} = f()
proc usesHofWithRead(): int = hof(readsSig)      # effectsOf carries the read
proc usesHofPure(): int = hof(pureFn)
proc ffiAbs(x: cint): cint {.importc: "abs", header: "<stdlib.h>".}
proc callsFfi(): int = ffiAbs(-3).int            # FFI — conservative?

macro report(): untyped =
  proc tagsOf(name: string, sym: NimNode) =
    var ts: seq[string]
    for t in getTagsList(sym): ts.add t.repr
    echo "  ", name, " -> ", ts
  echo "=== getTagsList results ==="
  tagsOf("readsSig (direct)        ", bindSym"readsSig")
  tagsOf("readsViaHelper (transit) ", bindSym"readsViaHelper")
  tagsOf("peeksOnly (untracked)    ", bindSym"peeksOnly")
  tagsOf("pureFn                   ", bindSym"pureFn")
  tagsOf("usesHofWithRead (efOf)   ", bindSym"usesHofWithRead")
  tagsOf("usesHofPure (efOf)       ", bindSym"usesHofPure")
  tagsOf("callsFfi (FFI)           ", bindSym"callsFfi")
  result = newStmtList()

report()
echo "compiled."
