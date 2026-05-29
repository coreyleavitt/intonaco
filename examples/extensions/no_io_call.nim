## Worked example: a third-party walker pass rejecting I/O calls in binding
## bodies (M-α.5).
##
## **What this pass enforces**: a `computed`/`effect` body should remain pure —
## any call carrying Nim's `IOEffect` tag (echo, file ops, stdout writes, etc.)
## is a discipline violation. Use the decide/act seam (`runAfterPropagation`)
## to host I/O that responds to reactive change instead of fusing it into the
## binding body.
##
## **What this example demonstrates** (pedagogically):
## - The `PassCheck` proc signature
## - Tag-based callee inspection via `getTagsList` (the same pattern
##   `noOpaqueCalleePass` uses, but for a different effect)
## - `Finding` construction with all four semantic fields
##   (subject, symptom, fix, breaksPreconditionOf)
## - Vocabulary discipline: symptom and fix avoid the contract's internal
##   terms (height / SCC / tier / worklist / etc.)
## - The `static:` registration block
##
## **How to use this pass in your own code**:
##
##   import intonaco/examples/extensions/no_io_call
##
## Just importing registers the pass; every `computed`/`effect` in the same
## compilation unit gets the check.
##
## **The contract** (see `intonaco/docs/extension-protocol.md` for full
## treatment):
## - Pass MUST be pure compile-time (no Nim state mutation)
## - Pass MUST own a `GlossaryTerm` (consequence vocabulary, exhaustive)
## - Pass MUST phrase symptom/fix in user-facing terms (no proof internals)
## - Pass MAY use `ctx.deps` / `ctx.body` for cross-node analysis
## - Pass MAY return zero, one, or many findings per node

import std/[macros, strutils, effecttraits]
import intonaco/reactive/analysis/pass
import intonaco/reactive/analysis/diagnostic

proc noIOCallPass*(node: NimNode, ctx: WalkContext): seq[Finding]
                  {.nimcall.} =
  ## Reject any call whose callee carries an `IOEffect`-family tag (the
  ## parent `IOEffect` itself or any subtype: `WriteIOEffect`, `ReadIOEffect`,
  ## etc.). The consequence is consistency-family (an I/O call in a binding
  ## body breaks the propagation discipline: the dispatcher can re-fire
  ## bindings, but I/O shouldn't be repeated on each re-fire).
  ##
  ## We match by tag-name suffix to catch every IOEffect descendant; Nim's
  ## `getTagsList` returns the literal tag names without hierarchy resolution.
  ##
  ## Note: `echo` is a magic proc — it carries no effect tags, so this pass
  ## doesn't catch it. Real-program I/O (`stdout.write`, file ops, network
  ## calls) DOES carry tags and gets caught.
  if node.kind notin {nnkCall, nnkCommand}: return
  if node.len < 1 or node[0].kind != nnkSym: return
  let callee = node[0]
  for tag in getTagsList(callee):
    if tag.repr.endsWith("IOEffect"):
      result.add Finding(
        severity: sevError,
        rule: gtRuntimeScheduled,
        subject: SignalId(callee.repr),
        symptom: "the call performs I/O — binding bodies should remain pure",
        fix: "move the I/O out of the binding body, or use the deferred-action " &
             "seam (`runAfterPropagation`) to host opaque work post-settle",
        site: node)
      return

registerWalkPass(noIOCallPass)
