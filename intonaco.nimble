# Package metadata for intonaco — the compile-time-first reactive
# systems substrate. Sibling to fresco (terminal frontend) and the
# planned sinopia (trace frontend). See ../fresco/docs/rfc-intonaco-
# fresco-split.md for the architectural framing.

version       = "0.1.0"
author        = "Corey Leavitt"
description   = "Compile-time-first reactive substrate for Nim — signals/scopes/supervision/journal/caps over a chronos contextvar substrate."
license       = "Apache-2.0"
srcDir        = "src"

requires "nim >= 2.0.0"

# Async runtime: our chronos fork with the contextVar primitive that
# currentScope / currentSpeculative / parallelCollector ride on. NOT
# listed as a nimble `requires` — nimble v0.22.2's vnext SAT solver
# can't resolve chained URL requires. milpa (see ../milpa) fetches it
# from milpa.kdl into _deps/ and emits nim.cfg with the --path: lines.
# Run `milpa fetch` after cloning, then `nimble test`.

# Standalone substrate tests. The substrate is validated on its own —
# not only through fresco — per "intonaco leads; fresco is a canary,
# not a driver." New test files land here as they're written.
task test, "run intonaco's standalone tests":
  let tests = @[
    # C-shape static-tier binding layer (post-M1 migration).
    "tests/test_binding.nim",
    "tests/test_binding_template_compose.nim",
    "tests/test_deferred.nim",
    "tests/test_mountwhen.nim",
    "tests/test_aggregators.nim",
    "tests/test_walker_passes.nim",
    "tests/test_kit.nim",
    "tests/test_diagnostic_emission.nim",
    "tests/test_extension_protocol_example.nim",
    "tests/test_dynamic_tier.nim",
    # Substrate primitives + concept-layers, shape-agnostic.
    "tests/test_diamond_glitch.nim",
    "tests/test_depth_and_backfeedback.nim",
    "tests/test_effect_feedback.nim",
    "tests/test_height.nim",
    "tests/test_verification.nim",
    "tests/test_convergence.nim",
    "tests/test_collection.nim",
    "tests/test_derive.nim",
    "tests/test_scan.nim",
  ]
  for t in tests:
    exec "nim r --hints:off --warnings:off --path:src " & t

task strictcheck, "compile-probe the -d:intonacoStrict guarantees":
  # A strict error can't live in a file the `test` loop runs, so the
  # discipline is regression-checked here via the compiler's exit code.
  const opts = "-d:intonacoStrict --hints:off --warnings:off --path:src "
  # MUST be a hard error under strict (a C-shape binding with unbaked dep):
  for p in ["tests/test_binding_strict_fail.nim"]:
    exec "if nim check " & opts & p &
      "; then echo 'EXPECTED STRICT ERROR: " & p & "'; exit 1; else exit 0; fi"
  # MUST compile under strict (all sources baked via signals:):
  for p in ["tests/test_binding_strict_ok.nim"]:
    exec "nim check " & opts & p
