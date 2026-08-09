## Journal ↔ Scope glue templates. Substrate-internal — these tie the
## scope-coupled bookkeeping (currentScope.lastEventId advancement) to
## the journal layer's bare append. Kept in the include-set rather than
## in `journal/log.nim` because the templates depend on `Scope` and
## `currentScope`, which are substrate types; the journal package
## itself stays scope-agnostic.

template journalEvent*(body: untyped) =
  ## Write a journal event under the active scope's identity, then
  ## advance `currentScope.lastEventId` to the new event id. Silent
  ## no-op when no journal is installed. Failures during append are
  ## swallowed — the journal is an audit trail, not a critical path.
  ##
  ## Inside `body`, three names are `{.inject.}`'d into scope:
  ##   `jrnl`      — the active journal (non-nil)
  ##   `taskTid`   — current scope's TaskId, or RootTask if no scope
  ##   `parentEvt` — current scope's lastEventId, or NoEvent if no scope
  ##
  ## `body` must evaluate to an `EventId` (typically a `jrnl.logXxx`
  ## call).
  if globalJournal != nil:
    let jrnl {.inject.} = globalJournal
    let taskTid {.inject.} = if currentScope.value != nil: currentScope.value.taskId else: RootTask
    let parentEvt {.inject.} = if currentScope.value != nil: currentScope.value.lastEventId else: NoEvent
    try:
      let frescoEvtId = body
      if currentScope.value != nil: currentScope.value.lastEventId = frescoEvtId
    except CatchableError: discard

template journalEventOnScope*(scope: Scope, body: untyped) =
  ## Like `journalEvent` but attributes the event to a specific scope
  ## rather than `currentScope`. Used at callback sites where the
  ## dispatcher's `currentScope` is unrelated to the event's logical
  ## owner.
  ##
  ## Advances `scope.lastEventId` to the new event id. Silent no-op
  ## without a journal; CatchableError from the log call is swallowed.
  if globalJournal != nil:
    let jrnl {.inject.} = globalJournal
    let taskTid {.inject.} = if scope != nil: scope.taskId else: RootTask
    let parentEvt {.inject.} = if scope != nil: scope.lastEventId else: NoEvent
    try:
      let frescoEvtId = body
      if scope != nil: scope.lastEventId = frescoEvtId
    except CatchableError: discard
