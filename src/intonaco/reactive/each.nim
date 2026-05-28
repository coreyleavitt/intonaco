## Per-item bindings over a CollectionSignal — the dynamic-tier shape for
## "set dynamism" (lists that grow / shrink at runtime).
##
## Iterates a `CollectionSignal[T]`'s delta stream. For each item present in
## the collection (initially + on insert), runs `body(item)` in a fresh
## scope. On remove, disposes the scope — which cascades `onCleanup` callbacks
## through every reactive binding the body created. Lifecycle is by
## construction; there is no "did I forget to unsubscribe?" surface.
##
## Usage:
##   let todos = collection[Todo]()
##   eachItem(todos) do (todo: Todo):
##     computed display, [pageStyle]:
##       formatTodo(pageStyle, todo)
##     effect [display]:
##       paint(display)
##
## The body's reactive bindings (`computed` / `effect` / nested `eachItem` /
## `dynamic`) attach to the current scope; the scope's disposal on remove
## tears them all down.

import ./subscribable
import ./scope
import ./collection
import ./deltafloor

proc eachItem*[T](src: CollectionSignal[T],
                  body: proc(item: T) {.closure.}) =
  ## Initial seed: for each item currently in `src`, spawn a scope, run
  ## `body(item)` in it, retain the scope. Then subscribe to the collection's
  ## delta stream: on insert, spawn a scope at the insertion index; on remove,
  ## dispose the scope at the removed index and drop the seq slot; on clear,
  ## dispose all scopes; updates / replaces / rollbacks are not handled in
  ## this version (a richer iteration can be added without changing this
  ## interface).
  var scopes: seq[Scope] = @[]
  proc spawnAt(item: T, pos: int) =
    let s = newScope()
    withScope s:
      body(item)
    if pos >= scopes.len: scopes.add s
    else: scopes.insert(s, pos)
  for i, item in src.get():
    spawnAt(item, i)
  onDelta(src, proc(d: Delta[T]) =
    case d.kind
    of dkInsert:
      spawnAt(d.insertVal, d.insertIdx)
    of dkRemove:
      scopes[d.removeIdx].dispose()
      scopes.delete(d.removeIdx)
    of dkClear:
      for s in scopes: s.dispose()
      scopes.setLen(0)
    else:
      discard
  )
