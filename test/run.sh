#!/usr/bin/env bash
# Tests for lend-ssh. The end-to-end tests run a throwaway sshd on
# 127.0.0.1 as the current user; they are skipped when no sshd is found.
# test/docker.sh runs them all in a container that has one.
#
#   SSHD                path to sshd (default: sshd on PATH, then /usr/sbin/sshd)
#   SSHD_EXTRA_CONFIG   lines appended to its sshd_config
#   SSHD_PORT           port to listen on (default 2222)
set -uo pipefail

root=$(cd "${0%/*}/.." && pwd)
top=$(mktemp -d)
# The tests run a copy of the clone, which install links to.
clone=$top/clone
mkdir -p "$clone"
cp -R "$root/lend-ssh" "$root/completions" "$clone"
lend_ssh=$clone/lend-ssh
sshd_pids=()
cleanup() {
  [[ ${#sshd_pids[@]} -eq 0 ]] || kill "${sshd_pids[@]}" 2>/dev/null
  rm -rf "$top"
  rm -f /tmp/lend-ssh-test-$$-*
}
trap cleanup EXIT

me=$(id -un)
unset SSH_AUTH_SOCK SSH_AGENT_PID XDG_CONFIG_HOME XDG_DATA_HOME BASH_COMPLETION_USER_DIR
path=$PATH

# run TEST: runs function TEST in a directory, $work, and a HOME of its own.
run() {
  work=$top/$1
  export HOME=$work/home LEND_SSH_CA=$work/ca/ca
  PATH=$path
  mkdir -p "$HOME"
  cd "$work" || exit 1
  "$1"
}

# shellcheck source=lib.sh source-path=SCRIPTDIR
. "$root/test/lib.sh"

# in_tty ANSWER COMMAND...: runs COMMAND in a terminal, answering ANSWER to
# a question that ends "[y/N] ". Needs python3.
in_tty() {
  python3 - "$@" <<'PY'
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
buf = b""
while True:
    try:
        chunk = os.read(fd, 1024)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    if buf.endswith(b"[y/N] "):
        os.write(fd, sys.argv[1].encode() + b"\n")
        buf = b""
    sys.stdout.buffer.write(chunk.replace(b"\r\n", b"\n"))
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
PY
}

# Usage errors exit 2, and other errors 1.
test_cli() {
  expect "help" 0 '^usage: lend-ssh' "$lend_ssh" help
  expect "no command" 2 '^usage:' "$lend_ssh"
  expect "unknown command" 2 "unknown command 'frob'" "$lend_ssh" frob
  expect "unknown option" 2 "^lend-ssh: unknown option --frob \(see 'lend-ssh help'\)$" "$lend_ssh" --frob
  expect "grant without a signing key" 1 "no signing key at .*lend-ssh init" "$lend_ssh" grant -t 4h x dave@a
  expect "account add without a signing key" 1 "no signing key" "$lend_ssh" account add -p dave@a
  expect "account add needs an account" 2 'name at least one \[USER@\]HOST' "$lend_ssh" account add
  expect "account rm needs an account" 2 'name at least one \[USER@\]HOST' "$lend_ssh" account rm
  expect "an account isn't an option" 2 "'-oProxyCommand=x' isn't \[USER@\]HOST" \
    "$lend_ssh" account add -p -- -oProxyCommand=x
  expect "account rm takes no -p" 2 'unknown option -p' "$lend_ssh" account rm -p dave@a
  expect "-k can't hold a quote" 2 "can't contain a single quote" "$lend_ssh" account add -k "it's" dave@a
  expect "... nor --file" 2 "can't contain a single quote" "$lend_ssh" account add --file="it's" dave@a
  expect "unknown account command" 2 "unknown account command 'frob' \(add, reset, rm, or none to list\)" \
    "$lend_ssh" account frob
  expect "revoke needs an agent" 2 'revoke takes an AGENT' "$lend_ssh" revoke
  expect "revoke takes no -k" 2 'unknown option -k' "$lend_ssh" revoke -k f claude dave@a
  expect "account reset needs an account" 2 'name at least one \[USER@\]HOST' "$lend_ssh" account reset
  expect "init takes no arguments" 2 'init takes no arguments' "$lend_ssh" init x
  expect "an unknown long option" 2 "unknown option --tim \(see 'lend-ssh grant -h'\)" "$lend_ssh" grant --tim 1h x a@b
  expect "a long option's missing value" 2 '--time needs a value' "$lend_ssh" grant --time
  expect "a long option that takes no value" 2 '--force takes no value' "$lend_ssh" install --force=yes
  expect "an unknown option in a bundle" 2 'unknown option -x' "$lend_ssh" account add -px dave@a
  expect "an option after the arguments is one" 2 "'-p' isn't \[USER@\]HOST" "$lend_ssh" account add dave@a -p
}

# shellcheck disable=SC2016  # bash -c scripts take their own arguments
test_help() {
  expect "help lists the commands by group" 0 'Set up, once: init create the signing key' \
    bash -c '"$1" help | tr -s " \n" " "' _ "$lend_ssh"
  expect "... and says where to read more" 0 "^'lend-ssh COMMAND -h' shows more about COMMAND.$" "$lend_ssh" help
  expect "a command's -h shows its usage" 0 '^   or: lend-ssh grant -t TIME \[-O' "$lend_ssh" grant -h
  expect "... what it does" 0 '^Signs AGENT.s key with a certificate' "$lend_ssh" grant -h
  expect "... and its options, short and long" 0 '^  -t, --time TIME +how long it lasts' "$lend_ssh" grant -h
  expect "... after other arguments too" 0 '^usage: lend-ssh grant' "$lend_ssh" grant -t 4h claude --help
  expect "... but not after --" 2 "'-h' isn't \[USER@\]HOST" "$lend_ssh" account add -p -- -h
  expect "help COMMAND shows the same" 0 '^usage: lend-ssh agent add \[-f\] NAME KEY' "$lend_ssh" help agent add
  expect "a verb's -h" 0 '^usage: lend-ssh account rm ' "$lend_ssh" account rm -h
  expect "a noun's -h has its usage" 0 '^usage: lend-ssh account$' "$lend_ssh" account -h
  expect "... what it does" 0 '^Lists the accounts set up from here' "$lend_ssh" account -h
  expect "... and its commands" 0 '^  rm \[-k FILE\]' "$lend_ssh" account -h
  expect "an unknown verb doesn't hide -h" 0 '^usage: lend-ssh agent$' "$lend_ssh" agent frob -h
  expect "-h before the command" 0 '^usage: lend-ssh agent show AGENT$' "$lend_ssh" -h agent show
  expect "revoke -h points to account reset for copies" 0 "A copy made before keeps working until it expires, .* 'account reset' stops every certificate" \
    bash -c '"$1" revoke -h | tr -s " \n" " "' _ "$lend_ssh"
  expect "help -h shows help's own page" 0 '^usage: lend-ssh help \[COMMAND\]$' "$lend_ssh" help -h
  expect "help COMMAND -h shows COMMAND's" 0 '^usage: lend-ssh grant$' "$lend_ssh" help grant -h
  expect "help lists lend-ssh's options" 0 '^  -h, --help +show the commands' "$lend_ssh" help
  local page long=''
  for page in '' init 'account add' 'account reset' 'account rm' account 'agent add' 'agent rm' 'agent show' agent grant revoke \
    install uninstall update completion help; do
    # shellcheck disable=SC2086  # a page is words
    long+=$(env -u LEND_SSH_CA "$lend_ssh" help $page | awk -v p="$page" 'length > 80 { print p ": " $0 }')
  done
  check "help fits in 80 columns" test -z "$long"
  expect "help for no such command" 2 "no command 'frob' \(see 'lend-ssh help'\)" "$lend_ssh" help frob
  expect "a usage error says where to read more" 2 "^lend-ssh: name at least one \[USER@\]HOST \(see 'lend-ssh grant -h'\)$" \
    "$lend_ssh" grant -t 4h claude
  expect "... for a verb" 2 "unknown option -x \(see 'lend-ssh account add -h'\)" "$lend_ssh" account add -x
  expect "... and for an unknown command" 2 "unknown command 'frob' \(see 'lend-ssh help'\)" "$lend_ssh" frob
  # The README's Commands section is lend-ssh help's output.
  local readme
  readme=$(awk '/^## Commands/ { on = 1; next } on && /^```$/ { if (inside) exit; inside = 1; next } inside' "$root/README.md")
  if [[ $readme == "$(env -u LEND_SSH_CA "$lend_ssh" help)" ]]; then
    ok "the README lists the commands as help does"
  else
    not_ok "the README lists the commands as help does" "$(diff <(echo "$readme") <(env -u LEND_SSH_CA "$lend_ssh" help))"
  fi
}

test_init() {
  if ! command -v python3 >/dev/null; then
    skip=$((skip + 1)); echo "skip init (needs python3 for a pty)"; return
  fi
  # ssh-keygen asks for the passphrase on the terminal, so give it one.
  local out
  out=$(python3 - "$lend_ssh" <<'PY' 2>&1
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], "init"])
buf = b""
while True:
    try:
        chunk = os.read(fd, 1024)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    if buf.rstrip().endswith(b":"):
        os.write(fd, b"secret\n")
        buf = b""
    sys.stdout.buffer.write(chunk)
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
PY
)
  if [[ $? -eq 0 && -f $LEND_SSH_CA && $out == *"lend-ssh account add [USER@]HOST"* ]]; then
    ok "init creates the signing key and says what's next"
  else
    not_ok "init creates the signing key and says what's next" "$out"
  fi
  expect "the signing key has a passphrase" fail 'incorrect passphrase|load failed' \
    ssh-keygen -y -P '' -f "$LEND_SSH_CA"
  expect "init refuses an existing key" 1 'already exists' "$lend_ssh" init
  rm -rf "${LEND_SSH_CA%/*}"
}

# The certificate's validity, from and to, in seconds.
validity() {
  local shown from to
  shown=$(ssh-keygen -L -f "$1")
  from=$(sed -n 's/.*Valid: from \([^ ]*\) to .*/\1/p' <<<"$shown")
  to=$(sed -n 's/.*Valid: from [^ ]* to \(.*\)/\1/p' <<<"$shown")
  python3 -c 'import sys,datetime as d;f=lambda s:d.datetime.fromisoformat(s);print(int((f(sys.argv[2])-f(sys.argv[1])).total_seconds()))' "$from" "$to" 2>/dev/null
}

# The certificate's end, as ssh-keygen -L shows it.
cert_end() {
  ssh-keygen -L -f "$1" | sed -n 's/.*Valid: from [^ ]* to \(.*\)/\1/p'
}

test_grant() {
  make_ca
  keygen "$work/k"

  expect "account add -p prints the line" 0 '^cert-authority,principals="dave@hosta" ssh-ed25519 ' \
    "$lend_ssh" account add -p dave@hosta
  expect "account add -p prints a line per account" 0 '^2$' \
    bash -c "'$lend_ssh' account add -p dave@hosta deploy@hostb | grep -c '^cert-authority,'"
  if [[ $("$lend_ssh" account add -p dave@hosta) == *" $(cat "$LEND_SSH_CA.pub")" ]]; then
    ok "the line ends with the signing key's public key"
  else
    not_ok "the line ends with the signing key's public key" "$("$lend_ssh" account add -p dave@hosta)"
  fi
  expect "account add -p records the account" 0 '^1$' cat "$HOME/.config/lend-ssh/accounts/dave@hosta"

  expect "grant needs the account set up" 1 \
    "dave@unset isn't set up for agents from here: 'lend-ssh account add dave@unset' sets it up" \
    "$lend_ssh" grant -t 4h "$work/k" dave@unset
  expect "grant a public key, under its comment" 0 '^test: dave@hosta \(new\) until [0-9-]+ [0-9:]+$' \
    "$lend_ssh" grant -t 4h "$work/k.pub" dave@hosta
  expect "agent show by public key" 0 '^ +dave@hosta$' "$lend_ssh" agent show "$work/k.pub"
  expect "only permit-pty by default" 0 'Extensions: *permit-pty *$' \
    bash -c "'$lend_ssh' agent show '$work/k' | tr -s ' \n' ' '"
  expect "with the session deadline, as one line" 0 \
    'Critical Options: force-command \(lend-ssh session deadline, [0-9-]+ [0-9:]+\) Extensions:' \
    bash -c "'$lend_ssh' agent show '$work/k' | tr -s ' \n' ' '"
  expect "ssh-keygen -L shows the deadline's script" 0 "force-command /bin/sh -c 'd=" ssh-keygen -L -f "$work/k-cert.pub"
  expect "key id defaults to the key's comment" 0 'Key ID: "test"' "$lend_ssh" agent show "$work/k-cert.pub"
  rm "$work/k-cert.pub"
  expect "grant by private key path" 0 'dave@hosta \(new\)' "$lend_ssh" grant -t 4h "$work/k" dave@hosta
  check "certificate is written beside the key" test -f "$work/k-cert.pub"

  keygen "$work/w"
  local secs end
  "$lend_ssh" grant -t 2h "$work/w" dave@hosta >/dev/null
  secs=$(validity "$work/w-cert.pub")
  if [[ -z $secs ]]; then
    skip=$((skip + 1)); echo "skip validity window (needs python3)"
  elif ((secs >= 2 * 3600 + 5 * 60 - 2 && secs <= 2 * 3600 + 5 * 60 + 2)); then
    ok "-t 2h is valid from 5 minutes ago to 2 hours ahead"
  else
    not_ok "-t 2h is valid from 5 minutes ago to 2 hours ahead" "$secs seconds"
  fi

  # A grant only adds.
  end=$(cert_end "$work/w-cert.pub")
  expect "a grant keeps the accounts and time already granted" 0 \
    '^test: deploy@hostb \(new\), dave@hosta \(kept\) until ' \
    "$lend_ssh" grant -t 30m "$work/w" deploy@hostb
  expect "... both accounts" 0 'Principals: deploy@hostb dave@hosta Critical' \
    bash -c "'$lend_ssh' agent show '$work/w' | tr -s ' \n' ' '"
  expect "... until the later end" 0 "^$end\$" cert_end "$work/w-cert.pub"
  "$lend_ssh" grant -t 3h "$work/w" dave@hosta >/dev/null
  if [[ $(cert_end "$work/w-cert.pub") > $end ]]; then
    ok "a longer grant extends it"
  else
    not_ok "a longer grant extends it" "$(cert_end "$work/w-cert.pub") isn't after $end"
  fi
  expect "a grant with other options is refused" 1 \
    "certificate allows permit-pty, session deadline, and this grant permit-port-forwarding, permit-pty, session deadline; 'lend-ssh revoke " \
    "$lend_ssh" grant -t 4h -O permit-port-forwarding "$work/w" dave@hosta
  expect "... and without the deadline" 1 "this grant permit-pty; 'lend-ssh revoke " \
    "$lend_ssh" grant -t 4h -D "$work/w" dave@hosta
  "$lend_ssh" revoke "$work/w" >/dev/null
  "$lend_ssh" grant -t 2h -I claude -O permit-port-forwarding "$work/w" dave@hosta deploy@hostb >/dev/null
  local shown
  shown=$("$lend_ssh" agent show "$work/w")
  expect "-I sets the key id" 0 'Key ID: "claude"' echo "$shown"
  expect "-O adds an extension" 0 'permit-port-forwarding' echo "$shown"
  expect "-O force-command needs -D" 2 'force-command needs -D' \
    "$lend_ssh" grant -t 4h -O force-command=uptime "$work/w" dave@hosta
  "$lend_ssh" revoke "$work/w" >/dev/null
  "$lend_ssh" grant -t 4h -D -O force-command=uptime "$work/w" dave@hosta >/dev/null
  expect "-D -O force-command keeps that command" 0 'force-command uptime' "$lend_ssh" agent show "$work/w"
  "$lend_ssh" revoke "$work/w" >/dev/null
  "$lend_ssh" grant --time=2h --id robot --option=permit-port-forwarding --no-deadline "$work/w" dave@hosta >/dev/null
  shown=$("$lend_ssh" agent show "$work/w")
  expect "--id sets the key id" 0 'Key ID: "robot"' echo "$shown"
  expect "--option adds an extension" 0 'permit-port-forwarding' echo "$shown"
  expect "--no-deadline leaves the deadline out" 0 'Critical Options: \(none\)' echo "$shown"
  "$lend_ssh" revoke "$work/w" >/dev/null
  "$lend_ssh" grant -Dt2h -Ime "$work/w" dave@hosta >/dev/null
  expect "short options bundle, with a value attached" 0 'Key ID: "me"' "$lend_ssh" agent show "$work/w"

  expect "grant needs -t" 2 "^lend-ssh: grant needs -t TIME, how long it lasts: 30m, 4h, 1h30m, 2d \(see 'lend-ssh grant -h'\)$" \
    "$lend_ssh" grant "$work/k" dave@hosta
  expect "grant needs an account" 2 'name at least one \[USER@\]HOST' "$lend_ssh" grant -t 4h "$work/k"
  expect "grant with an option needs an agent" 2 'takes an AGENT and the \[USER@\]HOST' "$lend_ssh" grant -t 1h
  expect "accounts are separate arguments" 1 "'a@b,c@d' is .*can't be a name" "$lend_ssh" grant -t 4h "$work/k" a@b,c@d
  expect "bad time" 2 "bad time '2 hours'" "$lend_ssh" grant -t '2 hours' "$work/k" dave@hosta
  expect "unknown option" 2 'unknown option -x' "$lend_ssh" grant -x "$work/k" dave@hosta
  expect "option without a value" 2 '-t needs a value' "$lend_ssh" grant -t
  expect "a missing key file stops grant" 1 \
    "^lend-ssh: '$work/nope' is neither an agent, a key file nor a public key$" \
    "$lend_ssh" grant -t 4h "$work/nope" dave@hosta
  expect "agent show without a certificate" 1 'no certificate at' "$lend_ssh" agent show "$LEND_SSH_CA"

  # A bare host is the account ssh would use: your user name, unless your
  # ssh config sets another. Host names come back in lower case.
  expect "account add takes a bare host" 0 "^cert-authority,principals=\"$me@hosta\" " \
    "$lend_ssh" account add -p hostA
  local bin=$work/config-ssh
  mkdir -p "$bin"
  printf 'Host al\n  HostName Real.Example.com\n  User bob\n' >"$work/config"
  printf '#!/bin/sh\nexec %s -F %s "$@"\n' "$(command -v ssh)" "$work/config" >"$bin/ssh"
  chmod +x "$bin/ssh"
  expect "the name follows your ssh config" 0 '^cert-authority,principals="bob@real.example.com" ' \
    env "PATH=$bin:$PATH" "$lend_ssh" account add -p al
  expect "... and USER@ on the command line" 0 '^cert-authority,principals="joe@real.example.com" ' \
    env "PATH=$bin:$PATH" "$lend_ssh" account add -p joe@al
  keygen "$work/b"
  expect "grant takes a bare host" 0 "^test: $me@hosta \(new\)" "$lend_ssh" grant -t 4h "$work/b" hostA

  local cert rsa
  ssh-keygen -q -t rsa -b 2048 -N '' -f "$work/rsa"
  for rsa in "$(cat "$work/rsa.pub")" "$(cut -d' ' -f2 "$work/rsa.pub")" "$(cut -d' ' -f2 "$work/k.pub")"; do
    cert=$("$lend_ssh" grant -t 4h "$rsa" dave@hosta 2>/dev/null)
    if [[ $cert == ssh-*-cert-v01@openssh.com\ * ]] && ssh-keygen -L -f - <<<"$cert" | grep -q 'dave@hosta'; then
      ok "grant a public key given as '${rsa:0:20}...' to stdout"
    else
      not_ok "grant a public key given as '${rsa:0:20}...' to stdout" "$cert"
    fi
  done
  expect "... and what it did to stderr, under its comment" 0 "^$(cut -d' ' -f3- "$work/rsa.pub"): dave@hosta \(new\) until" \
    bash -c '"$@" 2>&1 >/dev/null' _ "$lend_ssh" grant -t 4h "$(cat "$work/rsa.pub")" dave@hosta
  expect "... or as agent, for a key with no comment" 0 '^agent: dave@hosta \(new\) until' \
    bash -c '"$@" 2>&1 >/dev/null' _ "$lend_ssh" grant -t 4h "$(cut -d' ' -f1-2 "$work/rsa.pub")" dave@hosta
  expect "grant rejects a key it can't read" 1 "can't tell what kind of key 'AAAAzzzz...' is" \
    "$lend_ssh" grant -t 4h AAAAzzzz dave@hosta

  cert=$("$lend_ssh" grant -t 4h - dave@hosta <"$work/k.pub" 2>/dev/null)
  if [[ $cert == ssh-ed25519-cert-v01@openssh.com\ * ]] && ssh-keygen -L -f - <<<"$cert" | grep -q 'Signing CA'; then
    ok "grant - reads stdin and writes the certificate to stdout"
  else
    not_ok "grant - reads stdin and writes the certificate to stdout" "$cert"
  fi
}

# shellcheck disable=SC2016  # bash -c scripts take their own arguments
test_revoke() {
  make_ca
  keygen "$work/r"
  "$lend_ssh" account add -p dave@hosta deploy@hostb dave@hostc >/dev/null
  "$lend_ssh" grant -t 4h -I robot "$work/r" dave@hosta deploy@hostb >/dev/null
  local end
  end=$(cert_end "$work/r-cert.pub")
  expect "revoke one account" 0 \
    "^robot: revoked dave@hosta; keeps deploy@hostb until [0-9-]+ [0-9:]+; a copy of the certificate, and sessions open there now, work until [0-9-]+ [0-9:]+, or until 'lend-ssh account reset dave@hosta'$" \
    "$lend_ssh" revoke "$work/r" dave@hosta
  expect "... leaving the other" 0 'Principals: deploy@hostb Critical' \
    bash -c '"$1" agent show "$2" | tr -s " \n" " "' _ "$lend_ssh" "$work/r"
  expect "... until the same end" 0 "^$end\$" cert_end "$work/r-cert.pub"
  expect "... under the same key id" 0 'Key ID: "robot"' "$lend_ssh" agent show "$work/r"
  expect "... whose session deadline watches only it" 0 "lend-ssh [0-9]+ [^ ]+ deploy@hostb$" \
    ssh-keygen -L -f "$work/r-cert.pub"
  expect "agent show gives the deadline as the certificate's end" 0 \
    "force-command \(lend-ssh session deadline, ${end/T/ }\)" "$lend_ssh" agent show "$work/r"
  expect "grant lists the revoked account until the certificate ends" 0 \
    "^robot: dave@hosta \(revoked\) until ${end/T/ }$" "$lend_ssh" grant
  expect "revoke an account it doesn't have" 1 'robot has no grant for dave@hostc' \
    "$lend_ssh" revoke "$work/r" dave@hostc
  expect "revoke all of an agent's accounts" 0 '^robot: revoked deploy@hostb; ' "$lend_ssh" revoke "$work/r"
  check "... removes its certificate" test ! -e "$work/r-cert.pub"
  expect "... and grant lists both accounts as revoked" 0 \
    "^robot: dave@hosta \(revoked\) deploy@hostb \(revoked\) until ${end/T/ }$" "$lend_ssh" grant
  expect "revoke with nothing granted" 0 '^.*: no grant to revoke$' "$lend_ssh" revoke "$work/r"
  "$lend_ssh" grant -t 4h "$work/r" dave@hosta >/dev/null
  expect "revoking the last account removes the certificate" 0 'revoked dave@hosta' \
    "$lend_ssh" revoke "$work/r" dave@hosta
  check "... too" test ! -e "$work/r-cert.pub"
  expect "after revoke, a shorter grant is fine" 0 'dave@hosta \(new\)' \
    "$lend_ssh" grant -t 10m "$work/r" dave@hosta
  "$lend_ssh" agent add robot "$work/r" >/dev/null
  expect "an agent's grant lists a revoked account that outlasts it" 0 \
    "^robot: dave@hosta until [0-9-]+ [0-9:]+ robot: .*dave@hosta \(revoked\).* until [0-9-]+ [0-9:]+ $" \
    bash -c '"$1" grant | tr "\n" " "' _ "$lend_ssh"
  "$lend_ssh" grant -t 1d robot dave@hosta deploy@hostb >/dev/null
  expect "... but not one a later grant outlasts" 0 '^robot: dave@hosta deploy@hostb until [0-9-]+ [0-9:]+$' \
    "$lend_ssh" grant
  expect "agent rm lists the agent's accounts as revoked" 0 \
    '^robot: dave@hosta \(revoked\) deploy@hostb \(revoked\) until [0-9-]+ [0-9:]+$' \
    bash -c '"$1" agent rm robot >/dev/null && "$1" grant' _ "$lend_ssh"
  "$lend_ssh" agent add robot "$work/r" >/dev/null
  "$lend_ssh" grant -t 10m robot dave@hosta >/dev/null
  "$lend_ssh" agent rm robot >/dev/null
  expect "grant lists a revoked account once, at its latest end" 0 \
    '^robot: dave@hosta \(revoked\) deploy@hostb \(revoked\) until [0-9-]+ [0-9:]+ $' \
    bash -c '"$1" grant | tr "\n" " "' _ "$lend_ssh"
  "$lend_ssh" agent add textual "$(cat "$work/r.pub")" >/dev/null
  "$lend_ssh" grant -t 1h textual dave@hosta >/dev/null 2>&1
  expect "a grant to an agent given as text adds to its certificate" 0 '^textual: deploy@hostb \(new\), dave@hosta \(kept\) until ' \
    bash -c '"$1" grant -t 1h textual deploy@hostb 2>&1 >/dev/null' _ "$lend_ssh"
  expect "revoke an agent given as text prints its new certificate" 0 '^ssh-ed25519-cert-v01@openssh.com ' \
    bash -c '"$1" revoke textual dave@hosta 2>/dev/null' _ "$lend_ssh"
  expect "... which agent lists" 0 '^	deploy@hostb dave@hosta \(revoked\) until [0-9-]+ [0-9:]+$' "$lend_ssh" agent
  expect "revoke the last account of an agent given as text prints what it did" 0 \
    '^textual: revoked deploy@hostb; a copy of the certificate' "$lend_ssh" revoke textual
  expect "... on stderr" 0 '^0$' bash -c '"$1" grant -t 1h textual dave@hosta >/dev/null 2>&1; "$1" revoke textual 2>/dev/null | wc -c | tr -d " "' _ "$lend_ssh"
  "$lend_ssh" agent rm textual >/dev/null
  # An agent from older versions holds the public key itself.
  mkdir -p "$HOME/.config/lend-ssh/agents"
  cat "$work/r.pub" >"$HOME/.config/lend-ssh/agents/textual"
  expect "revoke an agent whose file holds its key" 1 "textual's certificate isn't kept here.*'lend-ssh account reset" \
    "$lend_ssh" revoke textual dave@hosta
  "$lend_ssh" agent rm textual >/dev/null
}

# account and account reset, with ~/.ssh/authorized_keys or -k FILE, through an
# ssh that runs the script here, in a HOME of its own.
# shellcheck disable=SC2016  # bash -c scripts take their own arguments
test_accounts() {
  local bin=$work/fake-ssh host_home=$work/host-home keys=$work/host-home/.ssh/authorized_keys
  mkdir -p "$bin" "$host_home"
  # shellcheck disable=SC2016  # the fake ssh's own $1 and $@
  printf '#!/bin/sh\n[ "$1" = -G ] && exec %s "$@"\nexec env HOME=%s sh -s\n' \
    "$(command -v ssh)" "$host_home" >"$bin/ssh"
  chmod +x "$bin/ssh"
  local -a as_host=(env "PATH=$bin:$PATH" "$lend_ssh")
  make_ca
  keygen "$work/acct-agent"
  "$lend_ssh" agent add acct "$work/acct-agent.pub" >/dev/null

  expect "account add writes ~/.ssh/authorized_keys" 0 '^dave@hostx: added$' "${as_host[@]}" account add dave@hostx
  expect "... in a new ~/.ssh only you can open" 0 '^drwx------' ls -ld "$host_home/.ssh"
  expect "... with the line" 0 '^cert-authority,principals="dave@hostx" ' cat "$keys"
  expect "account add to two accounts reports each" 0 'dave@hostx: already there.*dave@hosty: replaced the line for dave@hostx' \
    bash -c '"$@" | tr "\n" " "' _ "${as_host[@]}" account add dave@hostx dave@hosty
  expect "account lists them" 0 'dave@hostx no agent dave@hosty no agent' \
    bash -c '"$1" account | tr -s "\t\n" "  "' _ "$lend_ssh"
  "$lend_ssh" grant -t 4h acct dave@hosty >/dev/null
  expect "... with the agents that can reach them, until when" 0 'dave@hosty acct until [0-9-]+ [0-9:]+' \
    bash -c '"$1" account | tr -s "\t\n" "  "' _ "$lend_ssh"

  expect "account rm removes the line, cancelling the grants" 0 '^dave@hosty: removed; cancelled: acct until ' \
    "${as_host[@]}" account rm dave@hosty
  check "... leaving the file empty" test ! -s "$keys"
  expect "... and moves the account to its next number" 0 '^2 removed$' cat "$HOME/.config/lend-ssh/accounts/dave@hosty"
  expect "account lists it as removed" 0 'dave@hosty \(removed\)' "$lend_ssh" account
  expect "the agent's grant shows as cancelled" 0 'dave@hosty \(cancelled\) until' "$lend_ssh" agent
  expect "grant to a removed account" 1 "dave@hosty isn't set up for agents from here" \
    "$lend_ssh" grant -t 4h acct dave@hosty
  expect "account rm again" 0 '^dave@hosty: not there$' "${as_host[@]}" account rm dave@hosty
  expect "... keeps its number" 0 '^2 removed$' cat "$HOME/.config/lend-ssh/accounts/dave@hosty"
  expect "account add again" 0 '^dave@hosty: added$' "${as_host[@]}" account add dave@hosty
  expect "... under the next number, which no old certificate has" 0 \
    '^cert-authority,principals="dave@hosty#2" ' grep hosty "$keys"
  expect "grant uses the account's number" 0 'dave@hosty \(new\)' "$lend_ssh" grant -t 4h acct dave@hosty
  expect "... in the certificate" 0 '^ +dave@hosty#2$' "$lend_ssh" agent show acct

  expect "account reset moves the account to its next number" 0 \
    '^dave@hosty: every grant cancelled; cancelled: acct until ' "${as_host[@]}" account reset dave@hosty
  expect "... in the line" 0 '^cert-authority,principals="dave@hosty#3" ' grep hosty "$keys"
  expect "... and the record" 0 '^3$' cat "$HOME/.config/lend-ssh/accounts/dave@hosty"

  "$lend_ssh" grant -t 4h acct dave@hosty >/dev/null
  "$lend_ssh" revoke acct >/dev/null
  expect "agent lists a revoked account until its certificate would end" 0 \
    '^	dave@hosty \(revoked\) until [0-9-]+ [0-9:]+$' "$lend_ssh" agent
  expect "... and account" 0 'dave@hosty acct \(revoked\) until [0-9-]+ [0-9:]+' \
    bash -c '"$1" account | tr -s "\t\n" "  "' _ "$lend_ssh"
  expect "account reset cancels the revoked certificate" 0 \
    '^dave@hosty: every grant cancelled; cancelled: acct \(revoked\) until ' "${as_host[@]}" account reset dave@hosty
  expect "... which then goes from the list" 0 '^	no grant$' "$lend_ssh" agent

  if command -v python3 >/dev/null; then
    local out
    out=$(in_tty y "${as_host[@]}" grant -t 1h acct dave@hostn 2>&1)
    expect "grant offers to set up an account in a terminal" 0 \
      "^dave@hostn isn't set up for agents from here; set it up now \('lend-ssh account add dave@hostn'\)\? \[y/N\] y dave@hostn: (added|replaced the line for [^ ]+) acct: dave@hostn \(new\) until [0-9-]+ [0-9:]+ \(exit 0\)$" \
      echo "${out//$'\n'/ } (exit $?)"
    expect "... and stops when told no" 1 "^lend-ssh: dave@hostm isn't set up for agents from here: 'lend-ssh account add dave@hostm' sets it up" \
      in_tty n "${as_host[@]}" grant -t 1h acct dave@hostm
    check "... setting nothing up" test ! -e "$HOME/.config/lend-ssh/accounts/dave@hostm"
  else
    skip=$((skip + 1)); echo "skip grant's question (needs python3 for a pty)"
  fi
  expect "account reset with no grants" 0 '^dave@hosty: every grant cancelled; there were none$' \
    "${as_host[@]}" account reset dave@hosty
  expect "account reset of an account not set up" 0 "^dave@hostz: isn't set up for agents from here; nothing to reset$" \
    "${as_host[@]}" account reset dave@hostz
  expect "account rm with -k FILE" 0 '^dave@hostx: not there$' "${as_host[@]}" account rm -k "$work/other-keys" dave@hostx
  expect "account add with --file FILE" 0 '^dave@hostx: added$' "${as_host[@]}" account add --file "$work/other-keys" dave@hostx
  expect "... the line" 0 '^cert-authority,principals="dave@hostx#2" ' cat "$work/other-keys"
  expect "account reset -k FILE" 0 '^dave@hostx: every grant cancelled' \
    "${as_host[@]}" account reset -k "$work/other-keys" dave@hostx
  expect "... in that file" 0 '^cert-authority,principals="dave@hostx#3" ' cat "$work/other-keys"
  expect "account add --print" 0 '^cert-authority,principals="dave@hostp" ' "$lend_ssh" account add --print dave@hostp
  "$lend_ssh" agent rm acct >/dev/null
}

# Puts on PATH a zsh and a bash that, run as `-lic SCRIPT` for install, print
# some startup noise and run SCRIPT in a clean shell (zsh -f, bash --norc
# --noprofile) after the setup in ZSH_SETUP or BASH_SETUP: the startup files
# under test. Otherwise they run the real shell.
fake_shells() {
  local fake=$work/fake-shells sh real clean
  mkdir -p "$fake"
  for sh in zsh bash; do
    real=$(command -v "$sh") || real=/bin/false
    case $sh in
      zsh) clean="-f -c \"\${ZSH_SETUP:-}"$'\n'"\$2\"" ;;
      bash) clean="--norc --noprofile -c \"\${BASH_SETUP:-}"$'\n'"\$2\"" ;;
    esac
    cat >"$fake/$sh" <<SH
#!/bin/sh
if [ "\$1" = -lic ]; then
  echo 'startup noise'
  exec $real $clean
fi
exec $real "\$@"
SH
    chmod +x "$fake/$sh"
  done
  PATH=$fake:$PATH
}

# shellcheck disable=SC2016  # zsh and bash setup, expanded there
test_install() {
  local bin=$work/bin other=$work/other
  mkdir -p "$bin"
  fake_shells
  expect "install picks a writable directory on PATH" 0 "installed .*/bin/lend-ssh -> $lend_ssh" \
    env PATH="$HOME/bin:$PATH" bash -c "mkdir -p '$HOME/bin' && '$lend_ssh' install"
  expect "install links to the real script" 0 "^$lend_ssh\$" readlink "$HOME/bin/lend-ssh"
  expect "installed link runs" 0 '^usage: lend-ssh' "$HOME/bin/lend-ssh" help
  expect "install through the link links the script, not the link" 0 'already installed as ~/bin/lend-ssh' \
    env PATH="$HOME/bin:$PATH" "$HOME/bin/lend-ssh" install
  expect "install DIR off PATH says how to add it" 0 "isn't on your PATH.*" \
    env SHELL=/bin/zsh "$lend_ssh" install "$other"
  expect "PATH hint names the shell's startup file" 0 'to [~]/.zshrc' \
    env SHELL=/bin/zsh "$lend_ssh" install "$other"
  echo x >"$bin/lend-ssh"
  expect "install refuses an existing file" 1 "already exists; 'lend-ssh install -f' replaces it" \
    "$lend_ssh" install "$bin"
  expect "install -f replaces it" 0 'installed ' "$lend_ssh" install -f "$bin"
  expect "install -f leaves a link" 0 "^$lend_ssh\$" readlink "$bin/lend-ssh"
  rm "$bin/lend-ssh"
  echo x >"$bin/lend-ssh"
  expect "install --force replaces it" 0 'installed ' "$lend_ssh" install --force "$bin"
  expect "install with no usable directory uses ~/.local/bin" 0 "installed ~/.local/bin/lend-ssh" \
    env PATH="${PATH%%:*}:/usr/bin:/bin" "$lend_ssh" install
  expect "install takes one directory" 2 'at most one directory' "$lend_ssh" install a b

  local zdir=$work/site-functions comp=$clone/completions compinit='compdef() { :; }'
  mkdir -p "$zdir" "$work/read-only"
  chmod a-w "$work/read-only"
  expect "without a place to link completion, install says how to load it" 0 'eval "\$\(lend-ssh completion\)"' \
    env SHELL=/bin/zsh ZSH_SETUP="fpath=($work/read-only); $compinit" "$lend_ssh" install "$bin"
  expect "zsh without compinit gets no link" 0 'eval "\$\(lend-ssh completion\)"' \
    env SHELL=/bin/zsh ZSH_SETUP="fpath=($zdir)" "$lend_ssh" install "$bin"
  check "... none" test ! -e "$zdir/_lend-ssh"
  expect "install links zsh completion into the first writable fpath directory" 0 \
    "installed zsh tab completion as $zdir/_lend-ssh" \
    env SHELL=/bin/zsh ZSH_SETUP="fpath=($work/nowhere $work/read-only $zdir); $compinit" "$lend_ssh" install "$bin"
  expect "... to the clone's file" 0 "^$comp/_lend-ssh\$" readlink "$zdir/_lend-ssh"
  expect "... and doesn't print the eval line" 0 '^0$' \
    bash -c '"$@" | grep -c "lend-ssh completion"; true' _ env SHELL=/bin/zsh ZSH_SETUP="fpath=($zdir); $compinit" \
    "$lend_ssh" install "$bin"
  expect "install again finds zsh completion in place" 0 "zsh tab completion is already installed" \
    env ZSH_SETUP="fpath=($zdir); $compinit" "$lend_ssh" install "$bin"
  rm "$zdir/_lend-ssh"
  echo x >"$zdir/_lend-ssh"
  expect "install refuses to replace another completion file" 1 "_lend-ssh already exists; 'lend-ssh install -f'" \
    env ZSH_SETUP="fpath=($zdir); $compinit" BASH_SETUP='_comp_load() { :; }' "$lend_ssh" install "$bin"
  expect "... but links the other shell's" 0 "^$comp/lend-ssh.bash\$" \
    readlink "$HOME/.local/share/bash-completion/completions/lend-ssh"
  rm "$HOME/.local/share/bash-completion/completions/lend-ssh"
  expect "install -f replaces it" 0 "installed zsh tab completion" \
    env ZSH_SETUP="fpath=($zdir); $compinit" "$lend_ssh" install -f "$bin"
  expect "install links bash completion where bash-completion looks" 0 \
    "installed bash tab completion as ~/.local/share/bash-completion/completions/lend-ssh" \
    env SHELL=/bin/bash BASH_SETUP='_comp_load() { :; }' "$lend_ssh" install "$bin"
  expect "... to the clone's file" 0 "^$comp/lend-ssh.bash\$" \
    readlink "$HOME/.local/share/bash-completion/completions/lend-ssh"
  expect "... or under XDG_DATA_HOME" 0 "installed bash tab completion as $work/data/bash-completion/completions/lend-ssh" \
    env XDG_DATA_HOME="$work/data" BASH_SETUP='_comp_load() { :; }' "$lend_ssh" install "$bin"
  expect "... and with bash-completion before 2.12" 0 "installed bash tab completion as $work/old/completions/lend-ssh" \
    env BASH_COMPLETION_USER_DIR="$work/old" BASH_SETUP='__load_completion() { :; }' "$lend_ssh" install "$bin"
  expect "bash without bash-completion gets the eval line" 0 'eval "\$\(lend-ssh completion\)"' \
    env SHELL=/bin/bash "$lend_ssh" install "$bin"

  # uninstall, with the links install made above: in $bin, ~/bin, ~/.local/bin,
  # $zdir and bash-completion's directories, and a file in $other.
  echo x >"$work/not-ours"
  ln -sfn "$work/not-ours" "$HOME/.local/bin/lend-ssh"
  rm "$other/lend-ssh"
  echo x >"$other/lend-ssh"
  local out
  out=$(env PATH="$bin:$HOME/bin:$other:$PATH" ZSH_SETUP="fpath=($zdir)" "$lend_ssh" uninstall)
  expect "uninstall removes the links to lend-ssh on PATH" 0 "removed $bin/lend-ssh" echo "$out"
  expect "... and in the directories install picks from" 0 'removed ~/bin/lend-ssh' echo "$out"
  expect "... and zsh's completion" 0 "removed $zdir/_lend-ssh" echo "$out"
  expect "... and bash's" 0 'removed ~/.local/share/bash-completion/completions/lend-ssh' echo "$out"
  check "... which are gone" test ! -e "$bin/lend-ssh" -a ! -e "$HOME/bin/lend-ssh" -a ! -e "$zdir/_lend-ssh" \
    -a ! -e "$HOME/.local/share/bash-completion/completions/lend-ssh"
  check "uninstall leaves a link to something else" test -L "$HOME/.local/bin/lend-ssh"
  check "... and a file of that name" test -f "$other/lend-ssh"
  expect "... and says what stays: the clone" 0 "^- this clone, .*: rm -rf " echo "$out"
  expect "... and any eval line" 0 '^- any eval "\$\(lend-ssh completion\)" line' echo "$out"
  expect "uninstall again finds nothing" 0 '^found no links to ' \
    env PATH="$bin:$HOME/bin:$PATH" ZSH_SETUP="fpath=($zdir)" "$lend_ssh" uninstall
  "$lend_ssh" install "$work/off-path" >/dev/null
  expect "uninstall DIR removes a link install DIR made off PATH" 0 "removed $work/off-path/lend-ssh" \
    "$lend_ssh" uninstall "$work/off-path"
  check "... which is gone" test ! -e "$work/off-path/lend-ssh"
  mkdir -p "$HOME/.config/lend-ssh/agents" "$HOME/.config/lend-ssh/accounts"
  echo 1 >"$HOME/.config/lend-ssh/accounts/dave@hosta"
  echo "$work/k.pub" >"$HOME/.config/lend-ssh/agents/claude"
  out=$(env -u LEND_SSH_CA "$lend_ssh" uninstall)
  expect "uninstall lists no agents' certificates when there are none" 0 '^0$' \
    bash -c 'grep -c "agents. certificates" <<<"$1"; true' _ "$out"
  touch "$work/k-cert.pub"
  out=$(env -u LEND_SSH_CA "$lend_ssh" uninstall)
  expect "uninstall says what it leaves: accounts' lines" 0 "^- each account's line for agents: '.*lend-ssh account rm " echo "$out"
  expect "... agents' certificates" 0 "^- agents' certificates, .*agent rm NAME" echo "$out"
  expect "... and the config" 0 '^- your signing key, agents and accounts, in ~/.config/lend-ssh: rm -r ~/.config/lend-ssh$' \
    echo "$out"
  out=$("$lend_ssh" uninstall)
  expect "... or with the signing key elsewhere, the agents and accounts" 0 \
    '^- your agents and accounts, in ~/.config/lend-ssh: rm -r ~/.config/lend-ssh$' echo "$out"
  expect "... and a signing key kept elsewhere" 0 "^- the signing key, $work/elsewhere: rm " \
    env LEND_SSH_CA="$work/elsewhere" bash -c 'touch "$LEND_SSH_CA" && "$@"' _ "$lend_ssh" uninstall
  expect "uninstall takes at most one directory" 2 'uninstall takes at most one directory' "$lend_ssh" uninstall x y
}

# shellcheck disable=SC2016  # bash -c scripts take their own arguments
test_agents() {
  local key=$work/agenthome/.ssh/id_ed25519 cert
  make_ca
  "$lend_ssh" account add -p dave@hosta deploy@hostb >/dev/null
  mkdir -p "${key%/*}"
  keygen "$key"
  expect "no agents yet" 0 "^No agents\. 'lend-ssh agent add NAME KEY' adds one\.$" "$lend_ssh" agent
  expect "agent add a key file" 0 "^added agent claude: $key.pub$" \
    bash -c 'cd "$1" && "$2" agent add claude agenthome/.ssh/id_ed25519' _ "$work" "$lend_ssh"
  expect "agent add stores the absolute path" 0 "^$key.pub$" cat "$HOME/.config/lend-ssh/agents/claude"
  expect "agent add a key given as text" 0 '^added agent remote: ssh-ed25519 ' \
    "$lend_ssh" agent add remote "$(cut -d' ' -f2 "$key.pub")"
  expect "agent lists them" 0 'claude.*id_ed25519.pub no grant remote.*ssh-ed25519 .*given as text' \
    bash -c '"$1" agent | tr -s "\t\n" "  "' _ "$lend_ssh"
  expect "agent add refuses a name in use" 1 "already an agent claude; 'agent add -f' replaces it" \
    "$lend_ssh" agent add claude "$key"
  expect "agent add -f replaces it" 0 'added agent claude' "$lend_ssh" agent add -f claude "$key"
  expect "agent add --force too" 0 'added agent claude' "$lend_ssh" agent add --force claude "$key"
  expect "agent add rejects a bad name" 2 "'a/b' can't be an agent's name" "$lend_ssh" agent add a/b "$key"
  expect "... and one starting with -" 2 "'-x' can't be an agent's name" "$lend_ssh" agent add -- -x "$key"
  expect "... or with a ." 2 "'a.b' can't be an agent's name" "$lend_ssh" agent add a.b "$key"
  expect "agent add rejects a bad key" 1 "'nope' is neither a key file, a public key nor a host ssh knows; for a new key, give a path with a /, such as ./nope" \
    "$lend_ssh" agent add x nope
  expect "agent add takes a name and a key" 2 'takes a NAME and a KEY' "$lend_ssh" agent add claude

  local new=$work/newhome/.ssh/id_ed25519
  expect "agent add creates no key where the directory's parent is missing" 1 "no directory $work/newhome to create a key in" \
    "$lend_ssh" agent add fresh "$new.pub"
  check "... none" test ! -e "$work/newhome"
  expect "agent add creates no key beside other keys" 1 "${key%/*} already has id_ed25519.pub; name that key" \
    "$lend_ssh" agent add fresh "${key%/*}/id_typo.pub"
  check "... none" test ! -e "${key%/*}/id_typo"
  mkdir "$work/newhome"
  expect "agent add creates a key that isn't there" 0 \
    "^created a key at $new, without a passphrase$" "$lend_ssh" agent add fresh "$new.pub"
  check "... and its public key" test -f "$new.pub"
  check "... without a passphrase" eval 'ssh-keygen -y -P "" -f "$new" >/dev/null'
  expect "... readable only by you" 0 '^-rw-------' ls -l "$new"
  expect "... in a new directory only you can open" 0 '^drwx------' ls -ld "${new%/*}"
  expect "... and adds the agent" 0 "^$new.pub$" cat "$HOME/.config/lend-ssh/agents/fresh"
  expect "agent add creates a key given by its private key's path" 0 'created a key at .*/other/id_ed25519,' \
    "$lend_ssh" agent add other "$work/other/id_ed25519"
  expect "agent add creates no key for a name in use" 1 'already an agent fresh' \
    "$lend_ssh" agent add fresh "$work/unused/id_ed25519"
  check "... none" test ! -e "$work/unused"
  rm "$new.pub"
  expect "agent add won't replace a key whose .pub is missing" 1 "no public key at $new.pub" \
    "$lend_ssh" agent add -f fresh "$new.pub"
  expect "... leaving the private key" 0 '^-rw-------' ls -l "$new"
  local blob
  blob=$(cut -d' ' -f2 "$key.pub")
  blob=${blob:0:40}/${blob:41}
  expect "agent add takes a key with a / as text, not a path" 0 '^added agent slashed: ssh-ed25519 ' \
    "$lend_ssh" agent add slashed "$blob"
  check "... creating no key" test ! -e "${blob%%/*}"
  "$lend_ssh" agent rm fresh other slashed >/dev/null
  expect "unknown agent command" 2 "unknown agent command 'frob' \(add, show, rm, or none to list\)" \
    "$lend_ssh" agent frob

  expect "grant an agent by name" 0 '^claude: dave@hosta \(new\), deploy@hostb \(new\) until ' \
    "$lend_ssh" grant -t 4h claude dave@hosta deploy@hostb
  check "... beside its key" test -f "$key-cert.pub"
  expect "... under its name" 0 'Key ID: "claude"' "$lend_ssh" agent show claude
  expect "agent show an agent by name" 0 '^ +deploy@hostb$' "$lend_ssh" agent show claude
  expect "agent lists what its certificate opens until when" 0 \
    "^	dave@hosta deploy@hostb until [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$" "$lend_ssh" agent
  expect "grant lists the grants" 0 '^claude: dave@hosta deploy@hostb until [0-9-]+ [0-9:]+$' "$lend_ssh" grant
  ssh-keygen -q -s "$LEND_SSH_CA" -I t -n dave@hosta -V 20200101:20200102 "$key.pub"
  expect "agent lists an expired certificate as no grant" 0 '^	no grant$' "$lend_ssh" agent
  expect "grant leaves out an expired certificate" 0 "^No grants. 'lend-ssh grant -t TIME AGENT \[USER@\]HOST\.\.\.' makes one\.$" \
    "$lend_ssh" grant
  "$lend_ssh" grant -t 4h -D claude dave@hosta >/dev/null
  expect "agent flags a certificate without the session deadline" 0 \
    '^	dave@hosta until [0-9-]+ [0-9:]+, no session deadline$' "$lend_ssh" agent
  expect "agent add -f refuses another key while the agent has a grant" 1 \
    "agent claude has a grant until [0-9-]+ [0-9:]+; 'lend-ssh revoke claude' first" \
    "$lend_ssh" agent add -f claude "$work/other2/id_ed25519"
  check "... creating no key" test ! -e "$work/other2"
  mkdir "$work/copy"
  cp "$key" "$key.pub" "$work/copy"
  expect "... or the same key at another path" 1 "agent claude has a grant until" \
    "$lend_ssh" agent add -f claude "$work/copy/id_ed25519.pub"
  expect "... but takes the same key file" 0 "^added agent claude: $key.pub$" "$lend_ssh" agent add -f claude "$key"
  check "... keeping its certificate" test -f "$key-cert.pub"
  cert=$("$lend_ssh" grant -t 4h remote dave@hosta 2>/dev/null)
  if [[ $cert == ssh-ed25519-cert-v01@openssh.com\ * ]]; then
    ok "grant an agent given as text to stdout"
  else
    not_ok "grant an agent given as text to stdout" "$cert"
  fi
  expect "agent show an agent given as text" 0 'Key ID: "remote"' "$lend_ssh" agent show remote
  expect "a path is never an agent" 1 "no public key at ./claude" "$lend_ssh" agent show ./claude

  mv "$key.pub" "$key.pub.moved"
  expect "grant an agent whose key is gone" 1 "agent claude's key $key.pub is gone" \
    "$lend_ssh" grant -t 4h claude dave@hosta
  mv "$key.pub.moved" "$key.pub"
  expect "agent rm checks every name first" 1 'no agent nobody' "$lend_ssh" agent rm claude nobody
  check "... removing none" test -f "$HOME/.config/lend-ssh/agents/claude"
  expect "agent rm revokes, then forgets" 0 \
    'claude: dave@hosta until [0-9-]+ [0-9:]+, no session deadline -> revoked removed agent claude remote: dave@hosta until [0-9-]+ [0-9:]+ -> revoked removed agent remote' \
    bash -c '"$1" agent rm claude remote | tr "\n" " "' _ "$lend_ssh"
  check "... removing the certificate" test ! -e "$key-cert.pub"
  check "... and keeping the key" test -f "$key.pub"
  check "... and the copies of an agent given as text" test ! -e "$HOME/.config/lend-ssh/keys/remote"
  expect "... and they're gone" 0 '^No agents' "$lend_ssh" agent
  "$lend_ssh" agent add claude "$key.pub" >/dev/null
  ssh-keygen -q -s "$LEND_SSH_CA" -I t -n dave@hosta -V 20200101:20200102 "$key.pub"
  expect "agent rm with an expired certificate revokes nothing" 0 '^removed agent claude$' \
    "$lend_ssh" agent rm claude
  check "... and removes it" test ! -e "$key-cert.pub"
}

# Agents whose keys are at locations: in containers and volumes, through a
# fake docker, and over ssh, through a fake ssh that runs the script here, in
# a HOME of its own, and logs its arguments.
# shellcheck disable=SC2016  # bash -c scripts take their own arguments
test_locations() {
  local bin=$work/bin fd=$work/fd kept=$HOME/.config/lend-ssh/keys
  local c=$work/fd/containers/box/.ssh v=$work/fd/volumes/vol/.ssh s=$work/sshhome/.ssh
  mkdir -p "$bin" "$c" "$fd/volumes/vol" "$s"
  cp "$root/test/fake-docker" "$bin/docker"
  # shellcheck disable=SC2016  # the fake ssh's own $1 and $@
  printf '#!/bin/sh\n[ "$1" = -G ] && exec %s "$@"\necho "ssh $*" >>%s\nexec env HOME=%s sh -s\n' \
    "$(command -v ssh)" "$work/ssh.log" "$work/sshhome" >"$bin/ssh"
  chmod +x "$bin/ssh"
  export FAKE_DOCKER=$fd
  PATH=$bin:$PATH
  make_ca
  "$lend_ssh" account add -p dave@hosta deploy@hostb >/dev/null

  expect "agent add creates a key in a container" 0 \
    '^created a key at docker://box/~/.ssh/id_ed25519, without a passphrase$' \
    "$lend_ssh" agent add c 'docker://box/~/.ssh/id_ed25519.pub'
  check "... with its public key" test -f "$c/id_ed25519.pub"
  check "... without a passphrase" eval 'ssh-keygen -y -P "" -f "$c/id_ed25519" >/dev/null'
  expect "... readable only by its owner" 0 '^-rw-------' ls -l "$c/id_ed25519"
  expect "... and adds the agent, by its location" 0 '^docker://box/~/.ssh/id_ed25519.pub$' \
    cat "$HOME/.config/lend-ssh/agents/c"
  check "... keeping its public key" cmp -s "$c/id_ed25519.pub" "$kept/c/key.pub"
  expect "agent add an existing key in a container" 0 '^added agent c: docker://box/~/.ssh/id_ed25519.pub$' \
    "$lend_ssh" agent add -f c 'docker://box/~/.ssh/id_ed25519'
  expect "agent add creates a key in a volume, in a new directory" 0 \
    '^created a key at docker-volume://vol/.ssh/id_ed25519, without a passphrase$' \
    "$lend_ssh" agent add v 'docker-volume://vol/.ssh/id_ed25519'
  expect "... only its owner can open" 0 '^drwx------' ls -ld "$v"
  expect "... from a container of alpine" 0 '^docker run --rm -i --network none -v vol:/lend-ssh-volume alpine sh -s$' \
    tail -1 "$fd/log"
  expect "agent add creates a key over ssh" 0 '^created a key at ssh://dave@hostx:2200/~/.ssh/id_ed25519,' \
    "$lend_ssh" agent add s 'ssh://dave@hostx:2200/~/.ssh/id_ed25519.pub'
  check "... in the home directory there" test -f "$s/id_ed25519.pub"
  expect "... with ssh's port option" 0 '^ssh -p 2200 -- dave@hostx sh -s$' tail -1 "$work/ssh.log"
  mkdir "$work/abs"
  expect "agent add an absolute path over ssh" 0 "^created a key at ssh://hostx$work/abs/id_ed25519," \
    "$lend_ssh" agent add a "ssh://hostx$work/abs/id_ed25519.pub"
  check "... there" test -f "$work/abs/id_ed25519.pub"
  expect "... with no port" 0 '^ssh -- hostx sh -s$' tail -1 "$work/ssh.log"
  expect "agent lists the locations" 0 \
    "^a ssh://hostx$work/abs/id_ed25519.pub no grant c docker://box/~/.ssh/id_ed25519.pub no grant s ssh://dave@hostx:2200/~/.ssh/id_ed25519.pub no grant v docker-volume://vol/.ssh/id_ed25519.pub no grant $" \
    bash -c '"$1" agent | tr -s "\t\n" "  "' _ "$lend_ssh"

  expect "grant writes the certificate in the container" 0 '^c: dave@hosta \(new\) until ' \
    "$lend_ssh" grant -t 1h c dave@hosta
  check "... beside the key" cmp -s "$c/id_ed25519-cert.pub" "$kept/c/key-cert.pub"
  expect "... readable by all" 0 '^-rw-r--r--' ls -l "$c/id_ed25519-cert.pub"
  expect "a second grant adds to it" 0 '^c: deploy@hostb \(new\), dave@hosta \(kept\) until ' \
    "$lend_ssh" grant -t 1h c deploy@hostb
  expect "... there" 0 'Principals: deploy@hostb dave@hosta Critical' bash -c 'ssh-keygen -L -f "$1" | tr -s " \n" "  "' _ "$c/id_ed25519-cert.pub"
  expect "agent lists the grant" 0 '^c docker://box/~/.ssh/id_ed25519.pub deploy@hostb dave@hosta until ' \
    bash -c '"$1" agent | tr -s "\t\n" "  " | sed "s/.* c docker/c docker/"' _ "$lend_ssh"
  expect "revoke narrows the certificate there" 0 '^c: revoked dave@hosta; keeps deploy@hostb until ' \
    "$lend_ssh" revoke c dave@hosta
  expect "... there" 0 '^ deploy@hostb Critical' bash -c 'ssh-keygen -L -f "$1" | tr -s " \n" "  " | sed "s/.*Principals://"' _ "$c/id_ed25519-cert.pub"
  "$lend_ssh" revoke c >/dev/null
  check "revoke removes the certificate there" test ! -e "$c/id_ed25519-cert.pub"
  check "... and its copy" test ! -e "$kept/c/key-cert.pub"
  "$lend_ssh" grant -t 1h s dave@hosta >/dev/null
  check "grant writes the certificate over ssh" cmp -s "$s/id_ed25519-cert.pub" "$kept/s/key-cert.pub"
  LEND_SSH_VOLUME_IMAGE=busybox "$lend_ssh" grant -t 1h v dave@hosta >/dev/null
  check "grant writes the certificate in the volume" cmp -s "$v/id_ed25519-cert.pub" "$kept/v/key-cert.pub"
  expect "... from a container of LEND_SSH_VOLUME_IMAGE" 0 ' busybox sh -s$' tail -1 "$fd/log"
  expect "agent rm removes the certificate there" 0 '^v: dave@hosta until [0-9-]+ [0-9:]+ -> revoked removed agent v $' \
    bash -c '"$1" agent rm v | tr "\n" " "' _ "$lend_ssh"
  check "... there" test ! -e "$v/id_ed25519-cert.pub"
  check "... keeping the key" test -f "$v/id_ed25519"
  check "... and the copies" test ! -e "$kept/v"

  mkdir -p "$fd/containers/box2/.ssh"
  cp "$c/id_ed25519" "$c/id_ed25519.pub" "$fd/containers/box2/.ssh"
  "$lend_ssh" grant -t 1h c dave@hosta >/dev/null
  expect "agent add -f moves a key to a new location, with its grant" 0 \
    '^removed its certificate at docker://box/~/.ssh/id_ed25519.pub added agent c: docker://box2/~/.ssh/id_ed25519.pub sent its certificate, dave@hosta until [0-9-]+ [0-9:]+, to docker://box2/~/.ssh/id_ed25519.pub $' \
    bash -c '"$1" agent add -f c "docker://box2/~/.ssh/id_ed25519.pub" | tr "\n" " "' _ "$lend_ssh"
  check "... there" test -f "$fd/containers/box2/.ssh/id_ed25519-cert.pub"
  check "... and not at the old location" test ! -e "$c/id_ed25519-cert.pub"
  "$lend_ssh" agent add -f c "docker://box2$fd/containers/box2/.ssh/id_ed25519.pub" >/dev/null
  check "agent add -f keeps the certificate at the same file by another name" \
    test -f "$fd/containers/box2/.ssh/id_ed25519-cert.pub"
  expect "agent add -f moves the agent to text, printing its certificate" 0 \
    "^removed its certificate at docker://box2$fd/containers/box2/.ssh/id_ed25519.pub added agent c: ssh-ed25519 .* its certificate, dave@hosta until [0-9-]+ [0-9:]+: ssh-ed25519-cert-v01@openssh.com " \
    bash -c '"$1" agent add -f c "$(cat "$2")" | tr "\n" " "' _ "$lend_ssh" "$c/id_ed25519.pub"
  check "... not there" test ! -e "$fd/containers/box2/.ssh/id_ed25519-cert.pub"
  "$lend_ssh" agent add -f c "docker://box2/~/.ssh/id_ed25519.pub" >/dev/null
  check "... and back" test -f "$fd/containers/box2/.ssh/id_ed25519-cert.pub"
  expect "agent add -f refuses another key while the agent has a grant" 1 "agent c has a grant until [0-9-]+ [0-9:]+; 'lend-ssh revoke c' first" \
    "$lend_ssh" agent add -f c 'docker://box/~/.ssh/other.pub'
  expect "... or a key file here" 1 "agent c has a grant until" "$lend_ssh" agent add -f c "$c/id_ed25519.pub"
  expect "... or a key as text" 1 "agent c has a grant until" "$lend_ssh" agent add -f c "$(cat "$work/abs/id_ed25519.pub")"
  check "... creating no key" test ! -e "$c/other"

  rm -r "$fd/containers/box2"
  expect "grant to a container that's gone" 1 \
    "No such container: box2 lend-ssh: couldn't write c's certificate to docker://box2/~/.ssh/id_ed25519.pub; grant again to retry" \
    bash -c '"$1" grant -t 1h c deploy@hostb 2>&1 | tr "\n" " "; exit "${PIPESTATUS[0]}"' _ "$lend_ssh"
  expect "... keeping its copy" 0 '^	deploy@hostb dave@hosta until' "$lend_ssh" agent
  expect "revoke in a container that's gone" 1 \
    "^lend-ssh: couldn't change the certificate at docker://box2/~/.ssh/id_ed25519.pub, so c keeps its grant; revoke again to retry, or 'lend-ssh account reset deploy@hostb' stops it $" \
    bash -c '"$1" revoke c deploy@hostb 2>&1 | grep -v "No such container" | tr "\n" " "; exit "${PIPESTATUS[0]}"' _ "$lend_ssh"
  expect "... revoking nothing" 0 '^	deploy@hostb dave@hosta until' "$lend_ssh" agent
  expect "... and noting nothing revoked" 0 '^c: deploy@hostb dave@hosta until [0-9-]+ [0-9:]+$' "$lend_ssh" grant
  expect "... nor when it removes the certificate" 1 "so c keeps its grant" "$lend_ssh" revoke c
  check "... keeping its copy" test -f "$kept/c/key-cert.pub"
  mkdir -p "$fd/containers/box2/.ssh"
  cp "$c/id_ed25519.pub" "$fd/containers/box2/.ssh"
  expect "revoking again retries" 0 '^c: revoked deploy@hostb; keeps dave@hosta until ' \
    "$lend_ssh" revoke c deploy@hostb
  expect "... there" 0 '^ dave@hosta Critical' bash -c 'ssh-keygen -L -f "$1" | tr -s " \n" "  " | sed "s/.*Principals://"' _ "$fd/containers/box2/.ssh/id_ed25519-cert.pub"
  rm -r "$fd/containers/box2"
  expect "agent rm in a container that's gone" 1 \
    "couldn't remove the certificate at docker://box2/~/.ssh/id_ed25519.pub, so it still works there until .* removed agent c" \
    bash -c '"$1" agent rm c 2>&1 | tr "\n" " "; exit "${PIPESTATUS[0]}"' _ "$lend_ssh"
  check "... forgetting the agent" test ! -e "$HOME/.config/lend-ssh/agents/c"
  mkdir -p "$fd/containers/box3/.ssh"
  cp "$c/id_ed25519.pub" "$fd/containers/box3/.ssh"
  "$lend_ssh" agent add e 'docker://box3/~/.ssh/id_ed25519.pub' >/dev/null
  ssh-keygen -q -s "$LEND_SSH_CA" -I e -n dave@hosta -V 20200101:20200102 "$kept/e/key.pub"
  rm -r "$fd/containers/box3"
  expect "agent rm with an expired certificate leaves its location alone" 0 '^removed agent e$' \
    "$lend_ssh" agent rm e

  expect "agent add in a container that isn't there" 1 "No such container: nobox.*couldn't read docker://nobox/~/.ssh/id_ed25519.pub" \
    bash -c '"$1" agent add x "docker://nobox/~/.ssh/id_ed25519.pub" 2>&1 | tr "\n" " "; exit "${PIPESTATUS[0]}"' _ "$lend_ssh"
  expect "agent add in a volume that isn't there" 1 "no such volume.*couldn't read docker-volume://novol/.ssh/id_ed25519.pub" \
    bash -c '"$1" agent add x "docker-volume://novol/.ssh/id_ed25519.pub" 2>&1 | tr "\n" " "; exit "${PIPESTATUS[0]}"' _ "$lend_ssh"
  check "... creating none" test ! -e "$fd/volumes/novol"
  expect "agent add creates no key beside other keys there" 1 \
    "docker://box/~/.ssh already has id_ed25519.pub; name that key" \
    "$lend_ssh" agent add x 'docker://box/~/.ssh/id_typo.pub'
  expect "... or where the directory's parent is missing" 1 "no directory docker://box/~/new to create a key in" \
    "$lend_ssh" agent add x 'docker://box/~/new/.ssh/id_ed25519.pub'
  rm "$s/id_ed25519.pub"
  expect "agent add won't replace a key whose .pub is missing there" 1 \
    '^lend-ssh: no public key at ssh://dave@hostx:2200/~/.ssh/id_ed25519.pub$' \
    "$lend_ssh" agent add x 'ssh://dave@hostx:2200/~/.ssh/id_ed25519'
  echo nonsense >"$c/bad.pub"
  expect "agent add a file that isn't a key there" 1 "docker://box/~/.ssh/bad.pub isn't a public key" \
    "$lend_ssh" agent add x 'docker://box/~/.ssh/bad.pub'
  expect "agent add a location without a path" 1 "'docker://box' isn't a location: ssh://" \
    "$lend_ssh" agent add x 'docker://box'
  expect "... with a bad host" 1 "'-oProxy' in ssh://-oProxy/x.pub isn't \[USER@\]HOST\[:PORT\]" \
    "$lend_ssh" agent add x 'ssh://-oProxy/x.pub'
  expect "... a bad container" 1 "'a b' in docker://a b/x.pub can't be a container's name" \
    "$lend_ssh" agent add x 'docker://a b/x.pub'
  expect "... a path with a quote" 1 "can't be a key's path" "$lend_ssh" agent add x "docker://box/~/'x.pub"
  expect "... a volume's home directory" 1 'a volume has no home directory; its paths start at its top, as in docker-volume://vol/.ssh/id_ed25519.pub' \
    "$lend_ssh" agent add x 'docker-volume://vol/~/.ssh/id_ed25519.pub'
  check "... adding none" test ! -e "$HOME/.config/lend-ssh/agents/x"
}

# agent add [USER@]HOST, for a host in ~/.ssh/config or known_hosts, through
# a fake ssh that runs the script here, in a HOME of its own, and whose ssh -G
# reads a config of the test's.
test_known_hosts() {
  local bin=$work/bin s=$work/sshhome/.ssh
  mkdir -p "$bin" "$s" "$HOME/.ssh"
  printf 'Host *\n  UserKnownHostsFile %s\n  GlobalKnownHostsFile /dev/null\nHost porty\n  Port 2200\n' \
    "$work/known_hosts" >"$work/ssh_config"
  # shellcheck disable=SC2016  # the fake ssh's own $1 and $@
  printf '#!/bin/sh\n[ "$1" = -G ] && exec %s -F %s "$@"\necho "ssh $*" >>%s\nexec env HOME=%s sh -s\n' \
    "$(command -v ssh)" "$work/ssh_config" "$work/ssh.log" "$work/sshhome" >"$bin/ssh"
  chmod +x "$bin/ssh"
  PATH=$bin:$PATH
  printf 'Host aliased\n  HostName 10.9.9.9\n' >"$HOME/.ssh/config"
  printf '%s\n' 'hashed.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' \
    '[porty]:2200 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' >"$work/known_hosts"
  ssh-keygen -q -H -f "$work/known_hosts" >/dev/null 2>&1
  expect "known_hosts is hashed" 0 '^2$' grep -c '^|1|' "$work/known_hosts"
  make_ca

  expect "agent add a host in known_hosts, hashed, creates a key there" 0 \
    '^created a key at ssh://hashed.example/~/.ssh/id_ed25519, without a passphrase$' \
    "$lend_ssh" agent add k hashed.example
  check "... in the home directory there" test -f "$s/id_ed25519.pub"
  expect "... for the agent" 0 '^ssh://hashed.example/~/.ssh/id_ed25519.pub$' cat "$HOME/.config/lend-ssh/agents/k"
  expect "agent add USER@HOST" 0 '^added agent u: ssh://dave@hashed.example/~/.ssh/id_ed25519.pub$' \
    "$lend_ssh" agent add u dave@hashed.example
  expect "... which ssh logs in as" 0 '^ssh -- dave@hashed.example sh -s$' tail -1 "$work/ssh.log"
  expect "agent add a host known at its port" 0 '^added agent p: ssh://porty/~/.ssh/id_ed25519.pub$' \
    "$lend_ssh" agent add p porty
  expect "agent add a host in ~/.ssh/config" 0 '^added agent a: ssh://aliased/~/.ssh/id_ed25519.pub$' \
    "$lend_ssh" agent add a aliased
  expect "agent add a host ssh doesn't know" 1 \
    "'unknown.example' is neither a key file, a public key nor a host ssh knows" \
    "$lend_ssh" agent add x unknown.example
  expect "... nor at another port" 1 "'other@hashed.example:22' is neither a key file" \
    "$lend_ssh" agent add x other@hashed.example:22
  touch "$work/hashed.example"
  expect "a file comes before a host" 1 "no public key at hashed.example or hashed.example.pub" \
    "$lend_ssh" agent add x hashed.example
}

# grant with the signing key in an ssh-agent and not on disk.
test_ssh_agent() {
  make_ca
  "$lend_ssh" account add -p dave@hosta >/dev/null
  keygen "$work/a"
  mv "$LEND_SSH_CA" "$work/ca-private"
  expect "grant without the signing key's private key" 1 "signing key isn't at .* or in your ssh-agent" \
    "$lend_ssh" grant -t 4h "$work/a" dave@hosta
  eval "$(ssh-agent -s)" >/dev/null
  ssh-add -q "$work/ca-private"
  expect "grant with the signing key in ssh-agent" 0 'dave@hosta \(new\)' "$lend_ssh" grant -t 4h "$work/a" dave@hosta
  check "... by the CA" grep -qF "$(ssh-keygen -lf "$LEND_SSH_CA.pub" | cut -d' ' -f2)" \
    <(ssh-keygen -L -f "$work/a-cert.pub")
  ssh-agent -k >/dev/null
  unset SSH_AUTH_SOCK SSH_AGENT_PID
  mv "$work/ca-private" "$LEND_SSH_CA"
}

# completes WANT WORDS...: lend-ssh __complete WORDS prints the lines WANT,
# joined by spaces; or exits 1 when WANT is "files".
completes() {
  local want=$1 out status
  shift
  out=$("$lend_ssh" __complete "$@")
  status=$?
  out=$(cut -f1 <<<"$out" | paste -sd' ' -)
  if [[ $want == files ]]; then
    if [[ $status -eq 1 && -z $out ]]; then ok "complete '$*' to files"; else not_ok "complete '$*' to files" "exit $status: $out"; fi
  elif [[ $status -eq 0 && $out == "$want" ]]; then
    ok "complete '$*'"
  else
    not_ok "complete '$*'" "exit $status, want '$want', got '$out'"
  fi
}

test_completion() {
  local commands='init account agent grant revoke install uninstall update completion help'
  mkdir -p "$HOME/.ssh"
  printf 'Host box build *.corp\n  HostName 10.0.0.9\nHost gw\n' >"$HOME/.ssh/config"
  printf '%s\n' 'myhost,10.0.0.1 ssh-ed25519 AAAA' '|1|hashed ssh-ed25519 AAAA' \
    '[porty]:2222 ssh-ed25519 AAAA' '@cert-authority * ssh-ed25519 AAAA' >"$HOME/.ssh/known_hosts"
  # ssh -G reads the home in /etc/passwd, not $HOME.
  mkdir -p "$work/bin"
  printf '#!/bin/sh\nexec %s -F %s "$@"\n' "$(command -v ssh)" "$HOME/.ssh/config" >"$work/bin/ssh"
  chmod +x "$work/bin/ssh"
  PATH=$work/bin:$PATH
  completes '' grant cl
  completes '' agent show ''
  # box and build lead to $me@10.0.0.9, and gw to $me@gw.
  local accounts=$HOME/.config/lend-ssh/accounts
  mkdir -p "$accounts"
  echo 1 >"$accounts/$me@10.0.0.9"
  echo 1 >"$accounts/ann@gw"
  echo 1 >"$accounts/ann@myhost"
  echo '2 removed' >"$accounts/$me@gw"
  mkdir -p "$HOME/.config/lend-ssh/agents"
  keygen "$work/claude"
  keygen "$work/ca"
  ssh-keygen -q -s "$work/ca" -I claude -n "ann@myhost#2,$me@10.0.0.9" -V -5m:+1h "$work/claude.pub"
  echo "$work/claude.pub" >"$HOME/.config/lend-ssh/agents/claude"
  echo "$work/codex.pub" >"$HOME/.config/lend-ssh/agents/codex"
  echo "$work/old.pub" >"$HOME/.config/lend-ssh/agents/co.old"
  completes "$commands" ''
  completes 'account agent' a
  completes '-h --help' -
  completes '--help' --
  completes "$commands" help ''
  completes 'add show rm' help agent ''
  completes '' help grant ''
  completes '' help agent show ''
  completes 'add reset rm' account ''
  completes '-k --file' account reset -
  completes 'box build' account reset b
  completes 'box build' account reset -k f b
  completes '-p --print -k --file' account add -
  completes '--print --file' account add --
  completes '' account add -k ''
  completes '' account add --file ''
  completes '-p --print -k --file' account add -pk x -
  completes '10.0.0.1 box build gw myhost' account add -pk x ''
  completes '10.0.0.1 box build gw myhost' account add --file x ''
  completes '10.0.0.1 box build gw myhost' account add --file=x ''
  completes '' account add a@box -
  completes '' account add da
  completes '10.0.0.1 box build gw myhost' account add ''
  completes 'box build' account rm b
  completes '-k --file' account rm -
  completes 'box build' grant -t 4h claude b
  completes 'box build ann@gw ann@myhost' grant claude ''
  completes 'build ann@gw ann@myhost' grant claude box ''
  completes 'ann@gw ann@myhost' grant claude a
  # m is myhost's first letter, not ann's; and maybe yours.
  if [[ $me == m* ]]; then completes "$me@10.0.0.9" grant claude m; else completes '' grant claude m; fi
  completes 'box build ann@gw ann@myhost' account reset ''
  completes 'dave@10.0.0.1 dave@box dave@build dave@gw dave@myhost' account add dave@
  completes 'dave@box dave@build' account rm dave@b
  # bash splits words at @, = and :, and has only the last piece replaced.
  completes '@box @build' account add dave @ b
  completes '@10.0.0.1 @box @build @gw @myhost' account add dave @
  completes '@myhost' grant -t 4h key ann @ my
  completes 'dave@10.0.0.1 dave@build dave@gw dave@myhost' account add dave@box dave@
  completes '-t --time -O --option -I --id -D --no-deadline' grant -
  completes '--time --option --id --no-deadline' grant --
  completes '--no-deadline' grant --no
  completes '-t --time -O --option -I --id' grant -D -
  completes 'claude codex' grant ''
  completes 'codex' grant -t 4h -I me co
  completes 'codex' grant -D -t 4h co
  completes 'codex' grant --time 4h --id=me co
  completes 'codex' grant -Dt4h co
  completes '' grant x
  completes files grant ./
  completes files grant ~/
  completes files grant .ssh
  completes files grant dir/c
  completes 'permit-port-forwarding permit-agent-forwarding permit-X11-forwarding permit-user-rc' grant -O ''
  completes 'permit-agent-forwarding' grant --option permit-a
  completes '--option=permit-agent-forwarding' grant --option=permit-a
  completes 'permit-agent-forwarding' grant --option = permit-a
  completes '=permit-port-forwarding =permit-agent-forwarding =permit-X11-forwarding =permit-user-rc' grant --option =
  completes '' grant -t ''
  completes '' grant --time ''
  completes '' grant --time=
  completes 'ann@myhost' grant - ann@m
  completes 'ann@gw' grant -O permit-user-rc key ann@g
  completes '' revoke -
  completes 'claude codex' revoke ''
  completes 'box build ann@myhost' revoke claude ''
  completes 'box build' revoke claude b
  completes '' revoke codex ''
  echo 1 >"$accounts/$me@10.0.0.1"
  completes '10.0.0.1 10.0.0.9' grant claude 1
  rm "$accounts/$me@10.0.0.1"
  completes 'add show rm' agent ''
  completes 'rm' agent r
  completes 'claude' agent show cl
  completes files agent show ./
  completes '' agent show key ''
  completes '-f --force' agent add -
  completes '' agent add ''
  completes '' agent add -f ''
  completes files agent add -f claude ''
  mkdir -p "$work/fd/containers/box" "$work/fd/volumes/vol"
  cp "$root/test/fake-docker" "$work/bin/docker"
  export FAKE_DOCKER=$work/fd
  completes 'docker://box/~/.ssh/id_ed25519.pub docker-volume://vol/.ssh/id_ed25519.pub' agent add claude d
  completes 'docker-volume://vol/.ssh/id_ed25519.pub' agent add claude docker-
  completes 'docker://box/~/.ssh/id_ed25519.pub' agent add claude docker://
  completes 'ssh://box/~/.ssh/id_ed25519.pub ssh://build/~/.ssh/id_ed25519.pub' agent add claude ssh://b
  completes 'ssh://ann@gw/~/.ssh/id_ed25519.pub' agent add claude ssh://ann@g
  completes '//box/~/.ssh/id_ed25519.pub' agent add claude docker : //
  completes '//box/~/.ssh/id_ed25519.pub' agent add claude docker :
  completes files agent add claude c
  touch "$work/docs"
  completes files agent add claude d
  completes '' agent add claude key ''
  completes 'claude codex' agent rm ''
  completes 'codex' agent rm claude ''
  completes files install ''
  completes '-f --force' install -
  completes '' install dir ''
  completes '' init ''
  completes '' init -
  completes files uninstall ''
  completes '' uninstall dir ''
  completes '' update ''
  completes '' completion ''
  expect "commands come with descriptions" 0 $'^grant\tlist the grants, or let AGENT' \
    "$lend_ssh" __complete ''
  expect "... nouns with their verbs" 0 $'^account\taccounts: add, reset, rm, or none to list$' \
    "$lend_ssh" __complete ''
  expect "... and options" 0 $'^-t\thow long it lasts: 30m' "$lend_ssh" __complete grant -
  expect "... both forms" 0 $'^--time\thow long it lasts: 30m' "$lend_ssh" __complete grant -
  expect "... and -O's values" 0 $'^permit-agent-forwarding\tssh-agent forwarding' \
    "$lend_ssh" __complete grant -O permit-a
  expect "... and verbs" 0 $'^rm\tshut all agents out' "$lend_ssh" __complete account r

  if ! command -v python3 >/dev/null; then
    skip=$((skip + 1)); echo "skip tab completion in a shell (needs python3)"; return
  fi
  local dir=$work/complete sh how got want f bash_completion=''
  local -a files=()
  mkdir -p "$dir/bin" "$dir/cwd" "$dir/site-functions" "$dir/bash-completion/completions"
  ln -s "$lend_ssh" "$dir/bin/lend-ssh"
  touch "$dir/cwd/agentkey.pub"
  # The links install makes.
  ln -s "$clone/completions/_lend-ssh" "$dir/site-functions/_lend-ssh"
  ln -s "$clone/completions/lend-ssh.bash" "$dir/bash-completion/completions/lend-ssh"
  for f in /usr/share/bash-completion/bash_completion /opt/homebrew/share/bash-completion/bash_completion \
    /usr/local/share/bash-completion/bash_completion; do
    if [[ -f $f ]]; then bash_completion=$f; break; fi
  done
  local -a lines=('lend-ssh gr' 'lend-ssh account add dave@bo' 'lend-ssh account add bu'
    'lend-ssh account add ag' 'lend-ssh grant -O permit-a' 'lend-ssh grant --option=permit-a'
    'lend-ssh grant --no-d' 'lend-ssh grant ag' 'lend-ssh grant ./ag' 'lend-ssh grant cl'
    'lend-ssh grant agentkey.pub ann@my' 'lend-ssh agent show agentkey.pub ag' 'lend-ssh agent rm co'
    'lend-ssh agent add x ag' 'lend-ssh agent add x docker:' 'lend-ssh agent add x ssh://bo'
    'lend-ssh account res' 'lend-ssh help acc' 'lend-ssh help agent sh')
  want=$(printf '%s\n' 'lend-ssh grant' 'lend-ssh account add dave@box' 'lend-ssh account add build' \
    'lend-ssh account add ag' 'lend-ssh grant -O permit-agent-forwarding' \
    'lend-ssh grant --option=permit-agent-forwarding' 'lend-ssh grant --no-deadline' 'lend-ssh grant ag' \
    'lend-ssh grant ./agentkey.pub' 'lend-ssh grant claude' 'lend-ssh grant agentkey.pub ann@myhost' \
    'lend-ssh agent show agentkey.pub ag' 'lend-ssh agent rm codex' 'lend-ssh agent add x agentkey.pub' \
    'lend-ssh agent add x docker://box/~/.ssh/id_ed25519.pub' 'lend-ssh agent add x ssh://box/~/.ssh/id_ed25519.pub' \
    'lend-ssh account reset' 'lend-ssh help account' 'lend-ssh help agent show')
  for how in 'bash eval' 'zsh eval' 'zsh files' 'bash files'; do
    sh=${how%% *}
    files=()
    case $how in
      'zsh files') files=(--files "$dir/site-functions") ;;
      'bash files') files=(--files "$dir/bash-completion") ;;
    esac
    if ! command -v "$sh" >/dev/null; then
      skip=$((skip + 1)); echo "skip tab completion in $how (no $sh)"; continue
    fi
    if [[ $how == 'bash files' ]] &&
      ! { [[ -n $bash_completion ]] && bash -c '((BASH_VERSINFO[0] >= 4))'; }; then
      skip=$((skip + 1)); echo "skip tab completion in $how (no bash-completion 2)"; continue
    fi
    got=$(cd "$dir/cwd" && PATH=$dir/bin:$PATH "$root/test/tab-complete.py" ${files[@]+"${files[@]}"} \
      "$sh" "${lines[@]}" 2>&1)
    if [[ $got == "$want" ]]; then
      ok "tab completion in $how"
    else
      not_ok "tab completion in $how" "$(diff <(echo "$want") <(echo "$got"))"
    fi
  done
  if command -v zsh >/dev/null; then
    for how in eval files; do
      files=()
      [[ $how == eval ]] || files=(--files "$dir/site-functions")
      got=$(cd "$dir/cwd" && PATH=$dir/bin:$PATH "$root/test/tab-complete.py" ${files[@]+"${files[@]}"} \
        --list zsh 'lend-ssh ' 'lend-ssh grant -' 2>&1)
      expect "zsh ($how) lists commands in help's order" 0 \
        '^init +-- create the signing key account +-- accounts: add, reset, rm, or none to list agent ' \
        echo "$(tr -s '\n' ' ' <<<"$got")"
      expect "zsh ($how) lists an option's two forms together" 0 \
        '^--time +-t +-- how long it lasts: 30m' echo "$got"
    done
  fi
}

find_sshd() {
  if [[ -n ${SSHD:-} ]]; then echo "$SSHD"; return; fi
  command -v sshd 2>/dev/null && return
  [[ -x /usr/sbin/sshd ]] && echo /usr/sbin/sshd
}

# start_sshd DIR PORT [CONFIG]: starts sshd on 127.0.0.1:PORT as you, from
# directory DIR (which has its authorized_keys), with the lines CONFIG too.
start_sshd() {
  local d=$1 port=$2 sshd tries=0
  sshd=$(find_sshd)
  mkdir -p "$d"
  keygen "$d/hostkey"
  touch "$d/authorized_keys"
  cat >"$d/sshd_config" <<CONF
Port $port
ListenAddress 127.0.0.1
HostKey $d/hostkey
PidFile $d/sshd.pid
AuthorizedKeysFile $d/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
${3:-}
${SSHD_EXTRA_CONFIG:-}
CONF
  # The tests fail logins on purpose; OpenSSH 9.8 and later would then
  # refuse connections from 127.0.0.1 for a while.
  echo 'PerSourcePenalties no' >>"$d/sshd_config"
  "$sshd" -t -f "$d/sshd_config" 2>/dev/null || sed -i.bak '$d' "$d/sshd_config"
  if ! "$sshd" -f "$d/sshd_config" -E "$d/sshd.log"; then
    not_ok "start sshd in $d" "$(cat "$d/sshd.log" 2>/dev/null)"
    return 1
  fi
  until [[ -s $d/sshd.pid ]] || ((++tries > 10)); do
    sleep 0.2
  done
  sshd_pids+=("$(cat "$d/sshd.pid")")
}

test_e2e() {
  local port=${SSHD_PORT:-2222} d=$work/sshd
  if [[ -z $(find_sshd) ]]; then
    skip=$((skip + 1)); echo "skip end-to-end (no sshd; set SSHD, or run test/docker.sh)"; return
  fi
  make_ca
  mkdir -p "$work/bin"
  keygen "$work/me"
  keygen "$work/agent"
  # Sessions get a home of the test's, $work/host-home, in place of yours.
  mkdir -p "$work/host-home"
  start_sshd "$d" "$port" "SetEnv HOME=$work/host-home" || return
  local keys=$d/authorized_keys
  # You log in with your own key; a line from an earlier account add, with
  # another name, comes first; and the file has no final newline.
  printf '%s\n%s' "$("$lend_ssh" account add -p old@label)" "$(cat "$work/me.pub")" >"$keys"

  # account and account reset reach the host as "box", with your key.
  cat >"$work/ssh_config" <<CONF
Host box
  HostName 127.0.0.1
  Port $port
  IdentityFile $work/me
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
CONF
  printf '#!/bin/sh\nexec %s -F %s "$@"\n' "$(command -v ssh)" "$work/ssh_config" >"$work/bin/ssh"
  chmod +x "$work/bin/ssh"
  local -a as_me=(env "PATH=$work/bin:$PATH" "$lend_ssh")
  local box=box target=$me@127.0.0.1 blob
  blob=$(cut -d' ' -f2 "$LEND_SSH_CA.pub")

  # The agent logs in with its own key only.
  local -a ssh=(ssh -F /dev/null -p "$port" -i "$work/agent" -o BatchMode=yes
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
    -o IdentitiesOnly=yes)
  # stdio-forward to sshd itself: its banner comes back only if allowed.
  local forward='echo | "$@" | head -1'
  if command -v timeout >/dev/null; then
    forward='echo | timeout 10 "$@" | head -1'
  fi

  expect "e2e: no certificate is refused" fail 'Permission denied' "${ssh[@]}" -n 127.0.0.1 true
  "${as_me[@]}" account add -p "$box" >/dev/null
  "${as_me[@]}" grant -t 4h "$work/agent" "$box" >/dev/null
  expect "e2e: a certificate for an account whose line names another is refused" fail 'Permission denied' \
    "${ssh[@]}" -n 127.0.0.1 true

  expect "e2e: account add replaces the earlier line" 0 "^$target: replaced the line for old@label$" \
    "${as_me[@]}" account add -k "$keys" "$box"
  expect "e2e: a certificate logs in" 0 '^hello$' "${ssh[@]}" -n 127.0.0.1 echo hello
  expect "e2e: account add again changes nothing" 0 "^$target: already there$" \
    "${as_me[@]}" account add -k "$keys" "$box"
  expect "e2e: one line for the signing key" 0 '^1$' grep -cF "$blob" "$keys"
  check "e2e: your own key's line is kept" grep -qxF "$(cat "$work/me.pub")" "$keys"
  expect "e2e: the line names USER@HOST" 0 "^cert-authority,principals=\"$target\" " grep -F "$blob" "$keys"

  expect "e2e: forwarding is refused" 0 'forwarding failed' \
    bash -c "$forward" _ "${ssh[@]}" -W 127.0.0.1:"$port" 127.0.0.1
  "$lend_ssh" revoke "$work/agent" >/dev/null
  "${as_me[@]}" grant -t 4h -O permit-port-forwarding "$work/agent" "$box" >/dev/null
  expect "e2e: -O permit-port-forwarding allows it" 0 '^SSH-2.0' \
    bash -c "$forward" _ "${ssh[@]}" -W 127.0.0.1:"$port" 127.0.0.1
  "$lend_ssh" revoke "$work/agent" >/dev/null
  "$lend_ssh" account add -p "$me@elsewhere" >/dev/null
  "$lend_ssh" grant -t 4h "$work/agent" "$me@elsewhere" >/dev/null
  expect "e2e: a certificate for another account is refused" fail 'Permission denied' \
    "${ssh[@]}" -n 127.0.0.1 true
  "$lend_ssh" grant -t 4h "$work/agent" "$target" >/dev/null
  expect "e2e: a grant adds to a certificate, which logs into each account" 0 '^hello$' \
    "${ssh[@]}" -n 127.0.0.1 echo hello
  "$lend_ssh" revoke "$work/agent" "$target" >/dev/null
  expect "e2e: revoking one account refuses it" fail 'Permission denied' "${ssh[@]}" -n 127.0.0.1 true
  ssh-keygen -q -s "$LEND_SSH_CA" -I t -n "$target" -V 20200101:20200102 "$work/agent.pub"
  expect "e2e: an expired certificate is refused" fail 'Permission denied' "${ssh[@]}" -n 127.0.0.1 true
  expect "e2e: sshd logs why" 0 'Certificate invalid: expired' cat "$d/sshd.log"

  "$lend_ssh" grant -t 4h "$work/agent" "$target" >/dev/null
  expect "e2e: account rm removes the line" 0 "^$target: removed$" "${as_me[@]}" account rm -k "$keys" "$box"
  expect "e2e: then the certificate is refused" fail 'Permission denied' "${ssh[@]}" -n 127.0.0.1 true
  check "e2e: account rm keeps your own key's line" grep -qxF "$(cat "$work/me.pub")" "$keys"
  expect "e2e: account rm again changes nothing" 0 "^$target: not there$" \
    "${as_me[@]}" account rm -k "$keys" "$box"
  expect "e2e: account add again" 0 "^$target: added$" "${as_me[@]}" account add -k "$keys" "$box"
  expect "e2e: ... revives no certificate made before" fail 'Permission denied' "${ssh[@]}" -n 127.0.0.1 true
  "$lend_ssh" grant -t 4h "$work/agent" "$target" >/dev/null
  expect "e2e: ... and a new grant logs in" 0 '^hello$' "${ssh[@]}" -n 127.0.0.1 echo hello
  expect "e2e: account reset cancels every grant" 0 "^$target: every grant cancelled" \
    "${as_me[@]}" account reset -k "$keys" "$box"
  expect "e2e: ... so the certificate is refused" fail 'Permission denied' "${ssh[@]}" -n 127.0.0.1 true
  "$lend_ssh" grant -t 4h "$work/agent" "$target" >/dev/null
  expect "e2e: ... until a new grant" 0 '^hello$' "${ssh[@]}" -n 127.0.0.1 echo hello

  # An agent whose key is at ssh://box, in the home directory there, logs in
  # with the certificate grant writes there.
  local far_key=$work/host-home/.ssh/id_ed25519
  local -a far=(ssh -F /dev/null -p "$port" -i "$far_key" -o BatchMode=yes
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
    -o IdentitiesOnly=yes)
  expect "e2e: agent add creates a key in the home directory over ssh" 0 \
    "^created a key at ssh://box/~/.ssh/id_ed25519, without a passphrase$" \
    "${as_me[@]}" agent add far 'ssh://box/~/.ssh/id_ed25519.pub'
  expect "e2e: ... in a new ~/.ssh only its owner can open" 0 '^drwx------' ls -ld "${far_key%/*}"
  "${as_me[@]}" grant -t 1h far "$box" >/dev/null
  check "e2e: grant writes the certificate over ssh" cmp -s "$far_key-cert.pub" "$HOME/.config/lend-ssh/keys/far/key-cert.pub"
  expect "e2e: ... which logs in" 0 '^hello$' "${far[@]}" -n 127.0.0.1 echo hello
  "${as_me[@]}" revoke far >/dev/null
  check "e2e: revoke removes it over ssh" test ! -e "$far_key-cert.pub"
  expect "e2e: ... so the key alone is refused" fail 'Permission denied' "${far[@]}" -n 127.0.0.1 true
  expect "e2e: agent add at a host it can't reach" 1 "couldn't read ssh://nowhere.invalid/~/.ssh/id_ed25519.pub$" \
    "${as_me[@]}" agent add nowhere 'ssh://nowhere.invalid/~/.ssh/id_ed25519.pub'

  expect "e2e: account add creates a new file and its directory" 0 "^$target: added$" \
    "${as_me[@]}" account add -k "$d/new/keys" "$box"
  expect "e2e: ... with only the signing key's line" 0 "^cert-authority,principals=\"$target#3\" " cat "$d/new/keys"
  expect "e2e: ... readable only by you" 0 '^-rw-------' ls -l "$d/new/keys"
  expect "e2e: account add reports a host it can't reach" 1 "$me@nowhere.invalid: failed" \
    "${as_me[@]}" account add -k "$keys" "$me@nowhere.invalid"
}

# A directory of links to the programs in /usr/bin and /bin, leaving out
# those named after it: a PATH without them.
path_without() {
  local IFS=- d f name
  d=$work/path-without-$*
  IFS=$' \t\n'
  mkdir -p "$d"
  for f in /usr/bin/* /bin/*; do
    name=${f##*/}
    [[ " $* " != *" $name "* && ! -e $d/$name ]] && ln -s "$f" "$d/$name"
  done
  echo "$d"
}

# shellcheck disable=SC2016  # bash -c scripts take their own arguments
# Sessions under the certificate's deadline, on an sshd whose sessions get
# PATH $2 (or the default), named $1 in the tests' names.
deadline_tests() {
  local mode=$1 path=${2:-} port=$3 d=$work/sshd-${1// /-} config='' sftp='' f
  for f in /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/libexec/sftp-server /usr/lib/ssh/sftp-server; do
    [[ -x $f ]] && sftp=internal-sftp && break
  done
  if [[ -z $sftp ]]; then
    f=$(dirname "$(find_sshd)")/../lib/openssh/sftp-server
    [[ -x $f ]] && sftp=$f
  fi
  [[ -z $sftp ]] || config="Subsystem sftp $sftp"
  config+=$'\n'"SetEnv HOME=$d/home${path:+ PATH=$path}"
  mkdir -p "$d/home/.ssh"
  ln -s "$d/authorized_keys" "$d/home/.ssh/authorized_keys"
  start_sshd "$d" "$port" "$config" || return
  "$lend_ssh" account add -p "$me@127.0.0.1" >"$d/authorized_keys"
  local -a ssh=(ssh -F /dev/null -p "$port" -i "$work/dl-agent" -o BatchMode=yes
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
    -o IdentitiesOnly=yes)
  local t="deadline ($mode)"

  "$lend_ssh" grant -t 4h "$work/dl-agent" "$me@127.0.0.1" >/dev/null
  if [[ $mode == neither ]]; then
    expect "$t: refuses a session it can't end on time" fail 'neither GNU timeout nor perl' \
      "${ssh[@]}" -n 127.0.0.1 echo hello
    return
  fi
  expect "$t: a command keeps its quoting" 0 '^\[a\] \[b c\] $' \
    bash -c '"$@" | tr "\n" " "' _ "${ssh[@]}" -n 127.0.0.1 'printf "[%s]\n" a "b c"'
  expect "$t: and its exit status" 0 '^7$' bash -c '"$@"; echo $?' _ "${ssh[@]}" -n 127.0.0.1 'exit 7'
  expect "$t: and its stdin" 0 '^piped$' bash -c 'echo piped | "$@"' _ "${ssh[@]}" 127.0.0.1 cat
  expect "$t: an interactive shell gets a terminal" 0 'tty=/dev/' \
    bash -c 'printf "echo tty=\$(tty)\nexit\n" | "$@"' _ "${ssh[@]}" -tt 127.0.0.1
  if [[ -n $sftp ]]; then
    expect "$t: sftp works ($sftp)" 0 "dl-agent.pub" \
      bash -c 'echo "ls $1" | sftp -b - -P "$2" -i "$3" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o IdentitiesOnly=yes 127.0.0.1' \
      _ "$work/dl-agent.pub" "$port" "$work/dl-agent"
  else
    skip=$((skip + 1)); echo "skip $t: sftp (no sftp-server)"
  fi

  # A certificate valid 6 seconds more: sessions that run past it, and a
  # control socket opened before it.
  local out=$d/out sock=/tmp/lend-ssh-test-$$-${mode// /-} start
  mkdir -p "$out"
  "$lend_ssh" revoke "$work/dl-agent" >/dev/null
  "$lend_ssh" grant -t 6s "$work/dl-agent" "$me@127.0.0.1" >/dev/null
  "$lend_ssh" grant -D -t 6s "$work/dl-loose" "$me@127.0.0.1" >/dev/null
  start=$(date +%s)
  "${ssh[@]}" -o ControlMaster=yes -o ControlPath="$sock" -o ControlPersist=60 -n 127.0.0.1 true
  ("${ssh[@]}" -n 127.0.0.1 'sleep 31; echo SURVIVED' >"$out/command" 2>&1; echo "$? $(($(date +%s) - start))" >"$out/command.end") &
  ("${ssh[@]}" -n 127.0.0.1 'sleep 32 & wait; echo SURVIVED' >"$out/job" 2>&1; echo "$? $(($(date +%s) - start))" >"$out/job.end") &
  (printf 'sleep 33; echo SUR""VIVED\n' | "${ssh[@]}" -tt 127.0.0.1 >"$out/shell" 2>&1; echo "$? $(($(date +%s) - start))" >"$out/shell.end") &
  ("${ssh[@]/dl-agent/dl-loose}" -n 127.0.0.1 'sleep 12; echo SURVIVED' >"$out/loose" 2>&1) &
  sleep 9
  expect "$t: the control socket refuses a session after the deadline" fail 'lend-ssh: this certificate has expired' \
    "${ssh[@]}" -o ControlPath="$sock" -n 127.0.0.1 true
  expect "$t: a new connection is refused" fail 'Permission denied' "${ssh[@]}" -o ControlPath=none -n 127.0.0.1 true
  "${ssh[@]}" -o ControlPath="$sock" -O exit 127.0.0.1 2>/dev/null
  wait
  local what
  for what in command job shell; do
    if grep -q SURVIVED "$out/$what"; then
      not_ok "$t: a $what running at the deadline ends" "$(cat "$out/$what")"
    elif read -r status secs <"$out/$what.end" && ((status != 0 && secs >= 5 && secs <= 9)); then
      ok "$t: a $what running at the deadline ends"
    else
      not_ok "$t: a $what running at the deadline ends" "status and seconds: $(cat "$out/$what.end")"
    fi
  done
  expect "$t: no processes are left" 0 '^0$' bash -c 'ps -eo args | grep -E "^sleep 3[123]$" | wc -l | tr -d " "'
  expect "$t: grant -D lets a session outlast the certificate" 0 SURVIVED cat "$out/loose"

  # The watcher: a session ends soon after the account's line stops trusting
  # its certificate, here by its name changing (as account reset does) or by
  # the line going (as account rm does).
  local how=renamed status secs
  [[ $mode != perl ]] || how=removed
  "$lend_ssh" grant -t 4h "$work/dl-agent" "$me@127.0.0.1" >/dev/null
  start=$(date +%s)
  ("${ssh[@]}" -n 127.0.0.1 'sleep 41; echo SURVIVED' >"$out/watched" 2>&1; echo "$? $(($(date +%s) - start))" >"$out/watched.end") &
  sleep 2
  if [[ $how == renamed ]]; then
    perl -pi -e 's/principals="([^"]*)"/principals="$1#99"/' "$d/authorized_keys"
  else
    : >"$d/authorized_keys"
  fi
  wait
  if grep -q SURVIVED "$out/watched"; then
    not_ok "$t: a session ends once its account's line is $how" "$(cat "$out/watched")"
  elif read -r status secs <"$out/watched.end" && ((status != 0 && secs >= 2 && secs <= 16)); then
    ok "$t: a session ends once its account's line is $how"
  else
    not_ok "$t: a session ends once its account's line is $how" "status and seconds: $(cat "$out/watched.end")"
  fi
  expect "$t: ... leaving no process" 0 '^0$' bash -c 'ps -eo args | grep -E "^sleep 41$" | wc -l | tr -d " "'
}

test_deadline() {
  if [[ -z $(find_sshd) ]]; then
    skip=$((skip + 1)); echo "skip deadline (no sshd; set SSHD, or run test/docker.sh)"; return
  fi
  local port=${SSHD_PORT:-2222}
  make_ca
  keygen "$work/dl-agent"
  keygen "$work/dl-loose"
  if timeout --version 2>/dev/null | grep -q GNU; then
    deadline_tests 'GNU timeout' '' $((port + 1))
  else
    skip=$((skip + 1)); echo "skip deadline (GNU timeout): none here"
  fi
  if command -v perl >/dev/null; then
    deadline_tests perl "$(path_without timeout gtimeout)" $((port + 2))
  else
    skip=$((skip + 1)); echo "skip deadline (perl): none here"
  fi
  deadline_tests neither "$(path_without timeout gtimeout perl)" $((port + 3))
}

# update, in a clone of a throwaway upstream repository.
# shellcheck disable=SC2016  # bash -c scripts take their own arguments
test_update() {
  expect "update outside a git checkout" 1 "^lend-ssh: .* isn't a git checkout, so there's nothing to update$" \
    "$lend_ssh" update
  expect "update takes no arguments" 2 'update takes no arguments' "$lend_ssh" update x
  if ! command -v git >/dev/null; then
    skip=$((skip + 1)); echo "skip update (no git)"; return
  fi
  local i
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test \
    GIT_COMMITTER_EMAIL=test@example.com GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q -b master "$work/upstream"
  cp -R "$clone/lend-ssh" "$clone/completions" "$work/upstream"
  git -C "$work/upstream" add -A
  git -C "$work/upstream" commit -q -m 'first'
  git clone -q "$work/upstream" "$work/mine"
  expect "update when up to date" 0 '^lend-ssh [0-9a-f]+ is up to date$' "$work/mine/lend-ssh" update
  echo one >"$work/upstream/a"
  git -C "$work/upstream" add a
  git -C "$work/upstream" commit -q -m 'add a'
  expect "update lists what it brought in" 0 '^lend-ssh updated to [0-9a-f]+, 1 change: +[0-9a-f]+ add a $' \
    bash -c '"$1" update | tr "\n" " "' _ "$work/mine/lend-ssh"
  for ((i = 1; i <= 22; i++)); do
    git -C "$work/upstream" commit -q --allow-empty -m "change $i"
  done
  expect "update lists at most 20 changes" 0 '^lend-ssh updated to [0-9a-f]+, 22 changes: .* change 3 +\.\.\. and 2 more: git -C .* log $' \
    bash -c '"$1" update | tr "\n" " "' _ "$work/mine/lend-ssh"
  echo two >"$work/upstream/a"
  git -C "$work/upstream" commit -q -am 'change a'
  echo mine >"$work/mine/a"
  expect "update refuses to merge local changes" 1 "git pull failed in .*mine \(git's message is above\); sort it out with git there" \
    "$work/mine/lend-ssh" update
  expect "... leaving them" 0 '^mine$' cat "$work/mine/a"
}

test_lint() {
  if ! command -v shellcheck >/dev/null; then
    skip=$((skip + 1)); echo "skip lint (no shellcheck)"; return
  fi
  expect "shellcheck" 0 '' shellcheck -x "$root/lend-ssh" "$root/test/run.sh" "$root/test/real.sh" "$root/test/real/"*.sh \
    "$root/test/fake-docker" "$root/test/docker.sh" "$root/completions/lend-ssh.bash"
}

run test_lint
run test_cli
run test_help
run test_init
run test_grant
run test_revoke
run test_ssh_agent
run test_agents
run test_locations
run test_known_hosts
run test_accounts
run test_install
run test_update
run test_completion
run test_e2e
run test_deadline

echo "$pass passed, $fail failed, $skip skipped"
((fail == 0))
