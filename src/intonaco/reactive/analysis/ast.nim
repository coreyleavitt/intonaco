## Compile-time AST utilities for the C-shape analysis layer.
##
## Three helpers used by the substrate-template orchestration in
## `dsl/binding.nim`, `dsl/scan.nim`, `dsl/derive.nim`, and (eventually)
## the M-α.3 authoring kit (`dsl/kit.nim`):
##
## - `depSymUnwrap`: walk through implicit-conversion wrappers to the underlying
##   sym. Used because typed-arg sem inserts `Subscribable(x)` calls around
##   each dep element.
## - `containsDepSym`: identity-equality search through an AST subtree for any
##   of the declared dep syms. Backs `rewriteDepRefs`'s fast path.
## - `rewriteDepRefs`: replace identity-equal dep-sym references in a body with
##   fresh idents of the same name. Required for template-substituted bodies
##   (a template's typed `Signal[T]` parameter resolves to a typed sym in the
##   body; the ident-based shadow can't bind already-typed syms).

import std/macros

proc depSymUnwrap*(n: NimNode): NimNode {.compileTime.} =
  ## Walk through implicit-conversion wrappers (`nnkHiddenCallConv` etc.) to
  ## the underlying sym. The macros need this because typed-arg sem inserts
  ## `Subscribable(x)` calls around each dep element.
  result = n
  while result.kind in {nnkHiddenCallConv, nnkHiddenStdConv, nnkConv} and
        result.len >= 2:
    result = result[1]

proc containsDepSym*(node: NimNode, depSyms: openArray[NimNode]): bool
    {.compileTime.} =
  ## True iff `node` (or any descendant) is identity-equal to one of `depSyms`.
  if node.kind == nnkSym:
    for d in depSyms:
      if node == d: return true
    return false
  for c in node:
    if containsDepSym(c, depSyms): return true
  false

proc rewriteDepRefs*(node: NimNode, depSyms: openArray[NimNode]): NimNode
    {.compileTime.} =
  ## Rewrite every reference inside `node` that resolves (via identity-equal
  ## `nnkSym` match) to one of the dep syms, replacing it with a fresh
  ## `nnkIdent` of the same name. The rewritten node is then re-typed in
  ## scope of the prepended `let dep = dep.peek()` shadows — so the body
  ## sees the peeked value, not the outer Signal.
  ##
  ## Without this, an `effect`/`computed` invoked through a template breaks:
  ## template substitution resolves the template's typed `Signal[T]` parameter
  ## to a sym IN the body AST, and the ident-based shadow can't shadow a
  ## typed sym. Hits the user as e.g. `if boolSig:` seeing Signal[bool]
  ## instead of bool in `mountWhen`-style wrappers.
  ##
  ## Identity comparison (`node == dep`) — NOT name comparison — so a body
  ## that legitimately introduces an unrelated local with the same name as
  ## a dep is left untouched.
  if node.kind == nnkSym:
    for dep in depSyms:
      if node == dep:
        return newIdentNode(node.strVal)
    return node
  if node.len == 0:
    return node
  # Fast path: if no descendant matches a dep sym, return the original
  # subtree untouched — preserves all semantic metadata for typed nodes
  # that came via template substitution. Only rebuild when a substitution
  # is actually needed.
  var needsRewrite = false
  for c in node:
    if containsDepSym(c, depSyms):
      needsRewrite = true
      break
  if not needsRewrite:
    return node
  result = node.copyNimNode()
  for c in node:
    result.add rewriteDepRefs(c, depSyms)
