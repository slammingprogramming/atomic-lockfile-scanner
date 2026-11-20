# Contributing

Bug reports, false-positive reports, and new indicators are welcome. A new indicator needs a link to the source that names it.

## Rules for changes to the scanner

1. Every change needs a stated reason and evidence, recorded in `CHANGES.md`. Do not make improvements without a reason.
2. For a defect or a new rule, write the test first and confirm it fails on the current script, then make the change and confirm it passes.
3. Run `bash -n` on the script and `bash tests/run-tests.sh`. It must end with `0 failed`.
4. Keep shell scripts and the patch LF-only (`.gitattributes` enforces this).

## What the test harness depends on

- Unit tests load every line of the script before the first line `nb_hits=0`. Put detection rules above that line and state-changing code below it.
- The eBPF test extracts the function with `sed -n '/^  ebpf_scan() {/,/^  }$/p'`. Keep its two-space indentation and the closing `  }`.
- Test stubs use `#!/bin/sh`, not `#!/usr/bin/env bash`. With PATH set to the stub directory alone, `env` cannot find bash and a stub can pass for the wrong reason.

## Pull requests

Keep them small and say what the reason and the evidence are. Do not include personal information, tokens, or paths from your own machine. Signed commits are appreciated.

Questions and private reports: see `SECURITY.md`.
