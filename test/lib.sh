# shellcheck shell=bash
# Helpers for test/run.sh and test/real.sh, which source this file.

pass=0 fail=0 skip=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
not_ok() { fail=$((fail + 1)); echo "FAIL $1"; [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/     /'; }

# expect NAME STATUS PATTERN COMMAND...: COMMAND exits with STATUS (a number,
# or "fail" for any but 0) and its combined output matches the extended regex
# PATTERN.
expect() {
  local name=$1 want=$2 pattern=$3 out status
  shift 3
  out=$("$@" 2>&1)
  status=$?
  if [[ $want == fail && $status -eq 0 ]] || [[ $want != fail && $status -ne $want ]]; then
    not_ok "$name" "exit $status: $out"
  elif ! grep -Eq -- "$pattern" <<<"$out"; then
    not_ok "$name" "output didn't match /$pattern/: $out"
  else
    ok "$name"
  fi
}

# check NAME COMMAND...: COMMAND succeeds.
check() {
  local name=$1
  shift
  if "$@"; then ok "$name"; else not_ok "$name"; fi
}

make_ca() {
  mkdir -p "${LEND_SSH_CA%/*}"
  ssh-keygen -q -t ed25519 -N '' -f "$LEND_SSH_CA"
}

keygen() { ssh-keygen -q -t ed25519 -N '' -C test -f "$1"; }
