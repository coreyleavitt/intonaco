{.experimental: "callOperator".}

## Regression: `effect`/`computed` body must survive template substitution.
##
## When a template wraps `effect [dep]: body`, the body's `dep` references
## become typed syms (the template's parameter is resolved at substitution).
## The macro's auto-shadow uses ident-based `let dep = dep.peek()` — a fresh
## ident shadow doesn't bind already-typed syms. Without the AST rewrite,
## `if dep:` inside a template wrapper sees the outer Signal[T], not the bool.

import std/unittest
import intonaco/reactive/primitives/scope
import intonaco/reactive/primitives/signal
import intonaco/reactive/dsl/binding

template observeBoolViaTemplate*(boolSig: Signal[bool],
                                  recorder: var seq[bool]): untyped =
  ## Minimal mountWhen-shaped wrapper. The body of `effect` references
  ## `boolSig` directly — through template substitution it becomes a
  ## typed Signal[bool] sym in the body AST. The macro shadow must
  ## rewrite that sym so the body sees the peeked bool.
  effect [boolSig]:
    if boolSig:
      recorder.add true
    else:
      recorder.add false

suite "effect/computed: template-substituted bodies":

  test "effect body inside a template sees the shadowed bool, not the Signal":
    var seen: seq[bool] = @[]
    let sig = signal(false)
    let root = createRoot:
      observeBoolViaTemplate(sig, seen)
    sig.set(true)
    sig.set(false)
    sig.set(true)
    dispose(root)
    # Sequence: initial false; true; false; true
    check seen == @[false, true, false, true]
