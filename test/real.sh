#!/usr/bin/env bash
# Tests between real machines. test/docker.sh starts them and runs this in
# the lender, as "me", with these on its network:
#
#   host1      sshd; me logs in to its accounts dave and deploy with its key
#   agentbox   sshd; me logs in to its account agent with its key
#   agentc     the container $LEND_SSH_TEST_ID-agentc, running as agent
#   a volume   $LEND_SSH_TEST_ID-home, agent's home, as on agentbox
#
# me's ~/.ssh has its key and known_hosts for host1 and agentbox. The tests
# are the functions named real_* in test/real/*.sh, run in the order of their
# files, or only in the files whose names contain an argument; each starts
# with no lend-ssh config of its own, and leaves the machines as it found
# them.
set -uo pipefail

root=$(cd "${0%/*}/.." && pwd)
# shellcheck disable=SC2034  # the test files use it
lend_ssh=$root/lend-ssh
id=$LEND_SSH_TEST_ID
image=$LEND_SSH_TEST_IMAGE
top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
unset SSH_AUTH_SOCK SSH_AGENT_PID

# shellcheck source=lib.sh source-path=SCRIPTDIR
. "$root/test/lib.sh"

# as_agent WHERE COMMAND...: runs COMMAND as agent: on agentbox, in agentc, or
# with the volume as its home ("volume").
as_agent() {
  local where=$1
  shift
  case $where in
    agentbox | agentc) docker exec -u agent "$id-$where" "$@" ;;
    volume) docker run --rm --network "$id" -u agent -v "$id-home:/home/agent" "$image" "$@" ;;
  esac
}

# agent_ssh [-i KEY] WHERE ACCOUNT COMMAND...: agent logs in from WHERE to
# ACCOUNT on host1 and runs COMMAND, with its usual key and certificate, or
# with only private key KEY there (a path ssh takes, such as ~/acct/id_ed25519)
# and the certificate beside it.
agent_ssh() {
  local -a key=()
  if [[ $1 == -i ]]; then key=(-o IdentitiesOnly=yes -i "$2"); shift 2; fi
  local where=$1 account=$2
  shift 2
  as_agent "$where" ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR ${key[@]+"${key[@]}"} \
    "$account@host1" "$@"
}

# The test files, or with arguments, those whose names contain one.
files=()
for f in "$root"/test/real/*.sh; do
  if (($# == 0)); then files+=("$f"); continue; fi
  for a in "$@"; do [[ ${f##*/} != *"$a"* ]] || { files+=("$f"); break; }; done
done
# shellcheck disable=SC1090  # the test files
for f in "${files[@]}"; do . "$f"; done
for t in $(for f in "${files[@]}"; do sed -n 's/^\(real_[a-z_0-9]*\)() {$/\1/p' "$f"; done); do
  work=$top/$t
  mkdir -p "$work"
  export XDG_CONFIG_HOME=$work/config LEND_SSH_CA=$work/config/lend-ssh/ca
  cd "$work" || exit 1
  "$t"
done

echo "$pass passed, $fail failed, $skip skipped"
((fail == 0))
