# CHANGES

Review of `atomic-arch-check.sh` and the test harness added around it. Each change lists the reason and the evidence. Items that were checked and deliberately left alone are in [Left unchanged](#left-unchanged-with-reasons). `CHANGES.patch` is the exact diff.

Committed in a git repository (branch `main`). The tag `as-received` marks the files exactly as received; the commits after it hold this review. `git diff as-received -- 89711a81273ba16660b459a2033d26d8-019a280a5cc23cb9ec498d7526826d58c72fbbad/atomic-arch-check.sh` shows the same change as `CHANGES.patch`.

## Method

- Baseline: the script as received. A pristine copy was kept outside the project and is the reference for `CHANGES.patch`.
- `bash -n` on the modified script: clean.
- `tests/run-tests.sh` (52 checks) run against both the original and the modified script.
- Each defect was shown to fail on the original first, then fixed, then shown to pass.
- Not available here: Arch Linux, real bpftool, sudo, and a terminal. Anything that depends on those is marked **read only** below. It was checked by reading, not by running.
- A "CRLF line endings" concern raised during review was a false alarm. `tr -cd '\r' | wc -c` returns 0; the file is LF throughout and `bash -n` is clean.

## Results

| Script | Passed | Failed |
|---|---|---|
| Original (as received) | 21 | 31 |
| Modified | 52 | 0 |

Diff size: 104 lines added, 32 removed (`CHANGES.patch`).

## Changes to the script

### 1. Long files missed under `pipefail` (detection)

- **Before:** `_deobf "$1" | grep -Eq ...`. With `set -o pipefail`, `grep -q` exits at its first match and kills the writer with SIGPIPE. The pipeline then reports failure, so the match is discarded.
- **Change:** `grep -Eq ... < <(_deobf "$1")` (process substitution) in `pm_match` and `pkgbuild_match`.
- **Evidence:** "npm in an install scriptlet over 64 KiB" and "IOC dep name in a PKGBUILD over 64 KiB" are misses on the original and hits now.
- **Why it matters:** a long scriptlet is a plausible place to hide a payload, and the miss was silent.

### 2. Quote-spliced exec mechanisms missed (detection)

- **Before:** the machinery regex ran on raw text only. `curl ... | "sh"` and `base64 -"d"` do not match raw, because the quotes break the pattern. `_deobf` removed the quotes, but the machinery check never saw the de-obfuscated text.
- **Change:** `pm_match` also tests `OBF_MACHINERY` against the de-obfuscated text. The raw-text match is kept, because `_deobf` strips backslashes and would break the `$'\xNN'` forms.
- **Evidence:** "curl | \"sh\"" and "base64 -\"d\"" are misses on the original and hits now. The controls (plain `| sh`, a write to `/etc/bash.bashrc`) still hit.

### 3. `_why` gave no reason for some matches, and its output was garbled (output)

- **Before:** `_why` searched raw text only for `[machinery]`, so a match found only after de-obfuscation printed no reason. The sed prefix also had no space after the tag, so the line number ran into it (`[machinery]1:`).
- **Change:** fall back to the de-obfuscated text; pad all tags to one width; add the space.
- **Evidence:** "_why names [machinery] ... number not glued to the tag" fails on the original and passes now.

### 4. `foo` reported as AUR because of `foo-bar` (false attribution)

- **Before:** `grep -Fwf`. GNU grep's `-w` treats `-` as a word boundary, so an installed AUR package `foo` matched a log line for the official package `foo-bar`.
- **Change:** exact-name match on field 2 of each event, using awk with `$2 in names`.
- **Evidence:** the fixture log has `installed foo-bar` (official) and `installed foo` (AUR). The original reports `foo-bar`. The modified script reports `foo` only.

### 5. systemd units in two locations were not checked (coverage)

- **Before:** only `/etc/systemd/system/*.service` and `~/.config/systemd/user/*.service`. systemd also loads user units from `/etc/systemd/user` and from `$XDG_CONFIG_HOME/systemd/user`. That path differs from `~/.config` whenever `XDG_CONFIG_HOME` is set.
- **Change:** check all three locations and honour `XDG_CONFIG_HOME`, falling back to `~/.config`.
- **Evidence:** the fixture units `xdgunit.service` and `globalunit.service` are not flagged on the original and are flagged now. The unrelated `normal.service` is not flagged in either version.
- The fingerprint itself (`Restart=always` plus `RestartSec=30`) is unchanged.

### 6. Known-package list: silent failure, and no record that it did not run (honesty of output)

- **Before:** a failed or empty download printed nothing after the prompt, so the check looked complete. The final summary also did not mention that the list was not checked.
- **Change:** on a failed or empty download, print `Download failed or empty: known-list check NOT performed.`. Add a `list_ran` flag, and have the summary print `Known-impacted package list was NOT checked.` when it did not run.
- **Evidence:** "clean: known-list skip is disclosed" fails on the original and passes now (non-terminal path). The failed-download message is in the interactive branch: **read only**.

### 7. Wrong skip reason for the eBPF check (message accuracy)

- **Before:** `SKIPPED (needs root)` whenever there is no terminal. The scanner runs as a normal user and asks for sudo itself, so root is not what is missing. The real reason is the absence of a terminal.
- **Change:** `SKIPPED (non-interactive: run from a terminal to get the sudo prompt)`.
- **Evidence:** "clean: no misleading 'needs root' skip message" fails on the original and passes now.

### 8. Heuristic matches labelled as confirmed compromise (wording)

- **Before:** `FOUND (COMPROMISED)`, `[!] Malicious install-time code; see remediation below.`, and `/!\ IMPACTED /!\`.
- **Change:** `FOUND (SUSPICIOUS - heuristic match; verify each)`, `[!] Verify each entry; if one is real, see remediation below.`, and `/!\ POSSIBLE IMPACT /!\`.
- **Reason:** the rules are heuristic. A scriptlet that runs npm can be legitimate, and the output should not declare compromise for it. The remediation block is unchanged and still shown on a finding.
- **Evidence:** "finding is labelled as a heuristic (SUSPICIOUS)" and "verdict is POSSIBLE IMPACT" fail on the original and pass now.

### 9. Exit status always 0 (scripting)

- **Before:** the script ended with an `echo`, so it exited 0 even with findings. Any automation would read a finding as clean.
- **Change:** `exit 0` when `nb_hits` is 0, otherwise `exit 1`. Skipped checks do not change the status; the summary still lists them.
- **Evidence:** "infected: exit status 1" fails on the original (`got 0`) and passes now. The clean tree exits 0 in both.

### 10. eBPF check reported "nothing unexpected" when it had not checked (false reassurance)

Three separate paths, all reporting a result they had not established:

- **(a) `bpftool map list` fails** (no permission, or the kernel lacks bpf). Empty output was counted as zero maps and reported as "all maps belong to known system services."
  - **Fix:** capture the exit status. On failure, report `NOT VERIFIED` and do not print a count.
- **(b) bpffs not mounted.** The function returned early, before trying bpftool. That contradicted the script's own comment that bpftool "sees them whether or not they're pinned to bpffs." The summary then still said the maps were all known.
  - **Fix:** try bpftool first. bpffs is required only for the `stat()` fallback.
- **(c) bpftool absent (stat() fallback).** The fallback checks three known pin names, but the summary said "all maps belong to known system services," which was never checked.
  - **Fix:** a separate mode for each outcome, with wording that says a partial check was done.

- **Implementation:** the function now prints a `__METHOD__=` marker (`bpftool`, `stat`, `failed`, or `none`). The caller maps each marker to a precise message, in both the findings path and the final summary. The old `ebpf_ran` flag is replaced by `ebpf_mode`.
- **Evidence:** nine unit tests exercise `ebpf_scan` with a stub `bpftool` and stub `mountpoint`. On the original, seven fail. The other two ("known systemd map is not listed" and "failing bpftool prints no triage count") pass there only because the original prints no markers at all, so they say little on their own.
- **Read only:** the sudo-path messages in the findings branch are not executed by the harness.

### 11. Header comment (documentation)

- **Added:** `Read-only heuristic scan: writes no files. Exit 0 = no findings, 1 = findings. See ../README.md.`
- **Reason:** the behaviour was undocumented in the file. The "writes no files" claim was checked: no executable line redirects output to a file or runs a file-changing command (`tee`, `mv`, `rm`, `cp`, `chmod`, `mkdir`, `touch`). Matches were inside regex strings, `->` text, and comments.

### 12. Exec-mechanism comment corrected (documentation)

- **Before:** the comment said the matching was "spelling-independent". That was false for quote-spliced forms (change 2).
- **Change:** the comment now says matching runs on raw and de-obfuscated text, and that the `$'\xNN'` forms match raw text only. Comment only, no behaviour change.

### 13. Payload hook `lib/install-deps.mjs` added to `IOC_NAMES` (detection)

- **Reason:** requested by the owner on 2026-11-05. Sonatype names `./lib/install-deps.mjs` as the preinstall hook of the second-wave npm packages (`js-digest`, `lockfile-js`). A PKGBUILD, `.install`, or `.hook` that copies or runs it points at the same payload.
- **Change:** `lib/install-deps\.mjs` appended to `IOC_NAMES`. It is matched on de-obfuscated text, so quote-spliced forms are caught.
- **Evidence:** four new unit tests. Before the change the three hit tests failed (PKGBUILD, scriptlet, quote-spliced) and the miss test (`./scripts/install-deps.sh`) passed. After it all four pass.
- **Limits:** the string was confirmed on the raw Sonatype page (`"preinstall": "./lib/install-deps.mjs"`, in `lockfile-js`, which does not ship the `lib` directory). The Arch thread shows no PKGBUILD or scriptlet that contains it, so this is a precaution, not a rule seen firing on a real sample. The package names are already matched.

### 14. ExecStart binary hashed against the analysed payload (detection)

- **Reason:** requested by the owner on 2026-11-05 ("hashes and network indicators"). ioctl.fail publishes SHA-256 `6144d433...c98b` (3,040,376 bytes) for the ELF payload. The systemd check already finds the persistence unit; hashing its `ExecStart` binary turns "confirm you installed this" into a definite match when it is the analysed payload.
- **Change:** `PAYLOAD_SHA256`, `payload_hash_match` and `_exec_path` added above `nb_hits=0`. In the systemd loop, a matching unit's binary is hashed and a `[!] binary matches the SHA-256 of the analysed payload` note is appended. It adds no new finding and does not change the exit status. If `sha256sum` is missing, nothing is reported.
- **Evidence:** 13 new tests (hash equal, different, missing, directory, real constant versus a fixture, `ExecStart` prefixes, and three integration runs). Before the change the harness aborted at `PAYLOAD_SHA256: unbound variable`. After it all pass.
- **Limits:** one sample. The hash was read from the raw ioctl.fail page and its format is checked by a test, but the on-host binary may differ per build or be rewritten, so a mismatch proves nothing. Never run on a real host. The MD5 ioctl.fail also lists was not added.

### Network indicators: not added

Read from the raw ioctl.fail page: `temp.sh`, `POST /api/agent`, `POST /upload` and the onion host appear inside the ELF payload. The page says there are "no package-layer references" to them, so they are absent from PKGBUILDs, `.install` and `.hook` files, which are the only text the script scans. A rule could not fire on this campaign, and `temp.sh` or `/api/agent` as bare substrings could match legitimate scripts. The same applies to `scales.bpf.c` (named in the `lockfile-js` package.json). Network logs are outside the script's scope; ioctl.fail's own advice is to review HTTP/proxy logs for `temp.sh` and `POST /upload`.

### 15. Contact and support details added (documentation)

- **Reason:** requested by the owner on 2026-11-19: add the contact link, the Ko-fi link, and the BTC, ETH, and XMR addresses to the docs and program "as appropriate".
- **Change:** new "Contact and support" section at the end of `README.md`; two comment lines in the script header (contact and Ko-fi, with a pointer to the README for the crypto addresses). No code or behaviour change.
- **Not done, on purpose:** the script does not print any of this at run time. It is a read-only check that may run in automation, and its output may be logged or parsed. An unrequested banner is noise, and payment addresses printed by a security tool are a bigger trust problem than the same addresses in a README.
- **Evidence:** `bash -n` clean; `tests/run-tests.sh` still 52/52. Each link and address in `README.md` was compared character for character with the text the owner supplied. This is a documentation and comment change with no behaviour to test, like changes 11 and 12, so there is no failing-first test.
- **Checksums:** the Bitcoin address passes the bech32m checksum (BIP 350, prefix `sp`); the Ethereum address passes its EIP-55 mixed-case checksum; the Monero address passes its base58 checksum and is a standard mainnet address (network byte 42). A valid checksum shows the text was copied without a typo. It does not show who controls the wallet.
- **Limits:** nothing was checked on a network, and the wallets' ownership was not verified.

## Test harness (new file, not a change to the scanner)

`tests/run-tests.sh` was written for this review. It has 52 checks.

- **Unit tests** source the detection rules (lines before the first state-changing line, `nb_hits=0`) and call them on fixture files. The eBPF function is extracted with `sed` and tested with stubs.
- **Integration tests** run a copy of the whole script with its absolute system paths rewritten into a temp tree. `HOME` and the XDG directories point into the same temp tree. A stub `pacman` is first on PATH.

Two weaknesses in the harness were found and fixed during the work:

- **Weak assertion.** The eBPF-reason check first matched the known-list line's text, so it passed on the original. It now matches the exact eBPF wording.
- **Stub shebang.** Stubs used `#!/usr/bin/env bash`. Where PATH is set to the stub directory alone, `env` cannot find `bash`, so the stub exited 127. The `mountpoint` stub was affected: the stat test failed for that reason, and the no-bpffs test passed only because 127 reads as "not mounted". Stubs now use `#!/bin/sh`.

## Privacy check (2026-11-19)

Requested by the owner. Scope: the 8 tracked files, the full content of all commits (`git log -p --all`), untracked and ignored files, and `.git/config`.

- **Searched for:** the Windows account name, the git handle, personal email domains, any `@` address, home and drive paths (`C:\Users`, `E:\`, `/Users/`, `/home/`), the parent folder names, and the new contact and donation strings.
- **Result:** no personal email, local path, account name, or hostname in any tracked file or in history. The only `@` matches are the public mailing-list address `aur-general@lists.archlinux.org`, inside source URLs.
- **Commit identity:** every commit uses a pseudonymous handle with a GitHub noreply address (`...@users.noreply.github.com`), not a personal email. That handle and address become public if the repository is pushed.
- **Outside the repository, not a leak:** the Windows account name appears in file ownership and in the path of the global git config. Neither is stored in the repository.
- **Choice for the owner:** the Ko-fi handle in the README differs from the handle on the commits. Publishing the repository puts both in one place and links them. This file deliberately does not name either handle.
- **Limits:** a pattern search. It cannot find personal data it was not told to look for, such as a real name written in prose.

## Left unchanged, with reasons

1. **bpftool owner triage can be spoofed.** The owner name comes from the process `comm`, which a process controls. Validating the executable path differs from one distribution to another and could not be tested here. The effect is limited to triage of maps that are not IOC names, and the output already says triage is "not necessarily malicious."
2. **IOC names match as unanchored substrings.** Anchoring could miss variants of the names. Each match shows its line through `_why`, so false positives are visible rather than hidden. Accepted trade-off.
3. **`PM_ACTION` omits node, corepack, and deno.** These appear often in legitimate install scripts. Adding them would produce many false positives. This is a judgement; it was not measured against a real package database.
4. **`set -uo pipefail` without `-e` is intentional.** A failing check should not end the run. The scan should report every check and then give a verdict. With `-e`, one failing command would stop the run before any verdict.
5. **Build-date rule** ("built before the campaign, so likely safe"). Kept, with the caveat in the README. A later rebuild of an older version is flagged, so the rule errs toward flagging.
6. **The sudo `bash -c` call.** Only the function's own text is passed (`declare -f`). No user data is interpolated. Reviewed, no change.
7. **Running as root skips AUR caches** because `$HOME` becomes `/root`. Not changed: finding the invoking user's home (for example from `SUDO_USER`) would be new behaviour that cannot be tested here. The README tells the user to run it without sudo.
8. **Cosmetic text** such as `(Worth checking) :` and the first-person comment on the campaign start date. No behavioural effect; changing them would only add churn.
9. **`RestartSec=30` is matched exactly.** Narrow on purpose. Broadening the fingerprint would add noise.
10. **`[ -t 0 ]` gating kept.** The script must never prompt during automation.
11. **Hard-coded `LIST_URL` and `CAMPAIGN_START`.** Kept. The script comments say to edit them when they change.

## Open items (not verifiable here)

- The interactive branches (known-list `y/N` download, eBPF `[y]es`, `[s]how`, `[N]o` handling) were checked by reading only.
- bpftool output was assumed from the standard `bpftool map list` layout (`N: type name ...` followed by `pids owner(pid)`). Not run against a real bpftool.
- The package name `bpf` in the script's install hint has not been checked against a live Arch system.
- The `pacman -Qmq`, `-Q`, `-Qo` usage was checked against the test stub only.
- Source re-check, 2026-11-05 (partial, see "Source re-check" below). Later the same day ioctl.fail and Sonatype were read as raw text (changes 13 and 14).

## Source re-check (2026-11-05)

No script change came out of this. Rule 1 (a change needs a stated reason and a test that fails before it) was not met by any candidate.

**Confirmed**
- `IOC_NAMES`, `CAMPAIGN_START`, and `LIST_URL` match the original gist exactly (fetched twice).
- `atomic-lockfile` and `src/hooks/deps`: ioctl.fail. `atomic-lockfile` also: Sonatype and the Arch thread.
- `js-digest` and `lockfile-js`: Sonatype (second wave) and the Arch aur-general thread. The thread says `lockfile-js` was renamed from `atomic-lockfile`.
- `LIST_URL` loads as a plain-text list of about 2,000 names. It was not compared against anything here.
- Real install lines from the thread, each written to a temp file and passed to `pm_match`, are all flagged, and a clean scriptlet is not: `npm install atomic-lockfile ...` in an `.install` file, `/bin/sh -c 'cd /tmp && npm install atomic-lockfile ... 2>/dev/null; exit 0'` in a `.hook` file, `bun add execa js-digest commander`, and `npm install lockfile-js ...`.

**Not confirmed**
- **`nextfile-js`** appears only in the gist. It is absent from the first page of the Arch thread, from Sonatype, and from ioctl.fail. Kept, because it costs nothing and removing it needs evidence that it is wrong.
- **`CAMPAIGN_START='2026-06-09'`**: no readable source gives a start date. The first message in the thread is 11 Jun 2026, 8:47 p.m.; Sonatype and ioctl.fail date publication to 11 and 12 June. The gist's value is its author's "earliest observed" note. Nothing contradicts it, nothing confirms it. Kept.
- Package counts disagree (about 1,500 Sonatype, "1500+" gist, about 2,000 list). All are estimates.
- The Arch thread's later pages did not load through the pager, so only its first page (up to 13 Jun) was read. Both aur-general pages were blocked for the research subagent by an Anubis check and loaded in the built-in browser.

**Candidates not adopted** (update: `lib/install-deps.mjs` was adopted on request, see change 13; the owner declined `minimist`/`chalk`; hashes were adopted as change 14; network indicators were not, see change 14)
- **`./lib/install-deps.mjs`** (Sonatype: the preinstall hook inside `js-digest` and `lockfile-js`). That file lives in the npm package, not in a PKGBUILD, `.install`, or `.hook` file, which are what the script scans. The package names are already matched. The Arch thread shows the malicious lines as plain `npm install`/`bun add` commands. No test can fail on it, so no rule.
- **File hashes, `scales.bpf.c`, `temp.sh`, `POST /api/agent`, `.onion` host, generated service names.** Not artefacts of the files or pins this script reads.
- **`minimist` and `chalk`.** Cover packages installed with `atomic-lockfile`, also used by legitimate software. Matching them would give false positives.
- **Version pinning** (`atomic-lockfile 1.4.2`). The IOC match is name-only on purpose.

## Files

| Path | Status |
|---|---|
| `89711a81273ba16660b459a2033d26d8-019a280a5cc23cb9ec498d7526826d58c72fbbad/atomic-arch-check.sh` | Modified (changes 1–12) |
| `tests/run-tests.sh` | New |
| `README.md` | New |
| `CHANGES.md` | New (this file) |
| `CHANGES.patch` | New (diff of the script against the version as received) |
| `.gitattributes` | New (keeps `*.sh` and `*.patch` LF; `core.autocrlf=true` on this machine would otherwise check them out with CRLF) |
