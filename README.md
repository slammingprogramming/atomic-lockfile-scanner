# atomic-lockfile-scanner

A read-only, heuristic checker for the "Atomic Arch" AUR/npm campaign on Arch Linux. It looks for the known malicious npm dependency names, the install-time code that pulls them in, leftover systemd and cryptominer artifacts, and (as root, optional) eBPF rootkit maps.

A clean result means "no known indicator was found". It does not prove the machine is clean. See [Limitations](#limitations).

## Files

| Path | What it is |
|---|---|
| `89711a81273ba16660b459a2033d26d8-019a280a5cc23cb9ec498d7526826d58c72fbbad/atomic-arch-check.sh` | The scanner. The only file that runs on your system. |
| `tests/run-tests.sh` | Regression tests for the scanner (52 checks). |
| `CHANGES.md` | Every change made in review, with the reason and the evidence, and what was left alone and why. |
| `CHANGES.patch` | Exact diff of the scanner against the version as received. |
| `link for source.txt` | Link to the original gist. |

## Quick start

```bash
bash "89711a81273ba16660b459a2033d26d8-019a280a5cc23cb9ec498d7526826d58c72fbbad/atomic-arch-check.sh"
echo "exit status: $?"
```

- Run it as your normal user, **not** with `sudo bash ...`. Under sudo, `$HOME` becomes `/root`, so your AUR helper caches are not scanned. The eBPF check asks for sudo by itself when you choose it.
- Run it from a terminal to get the two prompts (the optional known-package list download and the eBPF check). Without a terminal (cron, a pipe, `</dev/null`) both are skipped, and the summary says so.

## Requirements

- Arch Linux with pacman. The script reads `/var/lib/pacman/local`, `/var/log/pacman.log`, and runs `pacman -Qmq`, `pacman -Q`, and `pacman -Qo`.
- bash, GNU coreutils (it uses `date -d`), GNU findutils, grep, sed, tr, and an awk (tested with gawk 5.0.0).
- Optional: `curl` or `wget` (known-package list); `bpftool` and `sudo` (eBPF check); `mountpoint` from util-linux (only for the stat() fallback). The sudo install hint in the script names the package `bpf` for bpftool. That name has not been verified on a live Arch system.

Tested here: Windows 10 with Git Bash (bash 5.2.37, GNU grep 3.0, GNU find 4.10, gawk 5.0.0). Not run on Arch, and not run against a real bpftool.

## What it checks

| Step | What it looks at | Counts as a finding? |
|---|---|---|
| AUR activity note | `installed`/`upgraded` events in `pacman.log` since 2026-06-09, for foreign (AUR) packages that are still installed | No (information only) |
| 1/2 local scan | `install` scriptlets in the pacman local DB; `*.hook` files in `/usr/share/libalpm/hooks` and `/etc/pacman.d/hooks` | Yes: `FOUND (SUSPICIOUS ...)` |
| 1/2 AUR caches | Top-level files for IOC names; `*.install`, `*.hook`, `PKGBUILD` in each cloned repo under yay, paru, pikaur, trizen, aurutils, `~/aur` | Yes |
| 1/2 known-package list | Optional download of the community list, compared with installed foreign packages | Yes, only if a match was built inside the campaign window |
| 2/2 systemd fingerprint | `*.service` in `/etc/systemd/system`, `/etc/systemd/user`, and `$XDG_CONFIG_HOME/systemd/user` (default `~/.config/systemd/user`) with `Restart=always` and `RestartSec=30`. The `ExecStart` binary of each match is also hashed (SHA-256) against the payload analysed by ioctl.fail | No: `TO REVIEW`; a hash match adds a `[!] binary matches the SHA-256` note |
| 2/2 cryptominer staging path | `/usr/bin/monero-wallet-gui` exists and no package owns it | Yes |
| 2/2 eBPF maps (root, prompted) | Map names `hidden_pids`, `hidden_names`, `hidden_inodes` | Yes |

Detection rules (`pm_match`, `pkgbuild_match`):

- An install scriptlet or hook runs an npm, npx, pnpm, yarn, or bun command in command position.
- An install scriptlet or hook uses an exec mechanism: `base64`/`base32 -d`, `xxd -r`, `curl`/`wget` piped to a shell, `eval` of a string or substitution, or `$'\xNN'` escapes.
- An install scriptlet or hook writes into a system shell-startup file (`/etc/bash.bashrc`, zsh, fish, `/etc/profile.d`).
- A PKGBUILD or install file contains an IOC dependency name: `atomic-lockfile`, `js-digest`, `lockfile-js`, `nextfile-js`, `src/hooks/deps`, `lib/install-deps.mjs`.

Text is de-obfuscated before matching (quotes and backslashes removed, `$IFS` turned into spaces), so `| "sh"` and `base64 -"d"` are caught too.

## Output and exit status

Each finding lists the file and the matched line(s), tagged by rule (`[pkg-mgr]`, `[ioc-name]`, `[machinery]`, `[shell-rc]`), so a false positive can be judged from the output.

The final verdict is one of:

- `LIKELY CLEAN`, followed by any checks that did not run.
- `POSSIBLE IMPACT`, followed by remediation steps.

Exit status: `0` means no findings; `1` means at least one finding. Skipped checks do not change the status, so read the summary before treating `0` as clean.

## Limitations

- **Heuristic.** It matches known IOC names and known delivery mechanisms. A payload that uses other names or other mechanisms is not found.
- **Installed packages only** for the AUR activity note. A package installed and later removed does not appear.
- **Helper caches only.** The AUR-cache check covers the helper directories listed above. A package built by hand elsewhere is covered only if it is installed (the pacman DB scan).
- **Known-package list** is community-maintained and may be incomplete. The download needs a terminal and a `y` answer.
- **Systemd fingerprint is narrow**: exact `Restart=always` plus `RestartSec=30`. The payload hash is checked only for units that match it, and only against one analysed sample. A mismatch proves nothing.
- **eBPF check** needs root and a terminal.
  - With bpftool, the owner-based triage can be fooled, because a process controls the name bpftool shows for it. IOC-name hits do not depend on the owner.
  - Without bpftool, it falls back to `stat()` on three known pin names. That is a partial check and can miss hidden pins.
- **Build-date rule.** A package built before 2026-06-09 is reported as "likely safe". That is a judgement, not a proof. The rule is conservative in one direction: a later rebuild of an older version gets a new build date and is flagged for inspection.
- **Date handling** uses GNU `date -d`. With a non-GNU `date`, the build-date comparison fails and the entry shows `TO INSPECT`.

## False positives

- Legitimate install scriptlets that pipe `curl`/`wget` into a shell, decode base64, or run `npm`/`bun` (for example, packages that bootstrap a JavaScript toolchain).
- Documentation or comments that mention an IOC name. IOC names are matched as substrings, so an `[ioc-name]` line may just be a README reference.
- Packages that write into `/etc/profile.d/` from a scriptlet.

Each finding shows the matched line, so these can be checked by eye.

## Safety

- The scanner reads files and runs read-only pacman and bpftool queries. It never runs package code. Executable code contains no file-writing redirects and no file-changing commands; the only matches were inside strings and comments (see `CHANGES.md`).
- The only network access is the optional known-package list: one GET to a fixed URL. Nothing from your system is sent.
- The eBPF check runs `sudo bash -c "$(declare -f ebpf_scan); ebpf_scan"`. Only the function's own text is passed, and no user data is interpolated. Choosing `[s]how` displays that exact text before you approve.
- The remediation text is advice. Nothing is removed, changed, or rotated for you.

## Tests

```bash
bash tests/run-tests.sh                               # scans the copy next to it
bash tests/run-tests.sh path/to/atomic-arch-check.sh  # or a given copy
KEEP=1 bash tests/run-tests.sh                        # keep the temp tree for inspection
```

The 52 checks are split into:

- **Unit tests** that source the detection rules (everything before the first state-changing line, `nb_hits=0`) and call them on fixture files, plus the eBPF function with stubbed `bpftool` and `mountpoint`.
- **Integration tests** that run a copy of the whole script with its system paths redirected into a temp tree, with a stub `pacman` first on PATH. One clean tree and one infected tree. Nothing outside the temp directory is read or written.

Not covered by the tests: the interactive prompts (the known-list `y/N` and the eBPF sudo path), real pacman, real bpftool, and Arch paths beyond the redirected fixture tree.

Results: the current script passes 52/52. The version as received passes 21 and fails 31 (some "no match" checks pass there only because the function they call does not exist). The failures are the defects listed in `CHANGES.md`.

## Sources

- Campaign reports and analysis, as linked in the header of the script:
  - https://lists.archlinux.org/archives/list/aur-general@lists.archlinux.org/thread/FGXPCB3ZVCJIV7FX323SBAX2JHYB7ZS4/
  - https://www.sonatype.com/blog/atomic-arch-npm-campaign-adds-malicious-dependency
  - https://ioctl.fail/preliminary-analysis-of-aur-malware/
- Known-package list the script downloads (when you say yes): https://md.archlinux.org/s/SxbqukK6IA/download
- Original gist: see `link for source.txt`.
