## Confirm the real refactor: set (via setRaw) injects SignalWrite, and the
## forbids levers catch real read/write through the public API.
import std/[effecttraits, macros]
import intonaco/reactive/signal
let s = signal(0, label = "s")
proc writesS() = s.set(5)
proc readsS(): int = s()
macro rep(): untyped =
  proc t(n: string, sym: NimNode) =
    var ts: seq[string]
    for x in getTagsList(sym):
      if x.repr in ["SignalRead", "SignalWrite"]: ts.add x.repr
    echo "  ", n, " signal-effects -> ", ts
  t("writesS (real set)", bindSym"writesS")
  t("readsS  (real get)", bindSym"readsS")
  result = newStmtList()
rep()
static:
  echo "  forbids[SignalWrite] rejects real set: ",
    not compiles((proc() {.forbids: [SignalWrite].} = s.set(5)))
  echo "  forbids[SignalRead]  rejects real get: ",
    not compiles((proc(): int {.forbids: [SignalRead].} = s()))
