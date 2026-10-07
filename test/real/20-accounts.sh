# shellcheck shell=bash disable=SC2154  # lend_ssh and the rest are test/real.sh's
# Accounts on host1's real sshd: setting them up, grants to several, revoking,
# resetting and removing them, and how open sessions end. The agents' keys are
# on agentbox in ~/acct and ~/acct2, of their own beside any other agent's
# key, which each test removes again.

# host1_keys USER: prints USER's authorized_keys on host1.
host1_keys() { docker exec "$id-host1" cat "/home/$1/.ssh/authorized_keys"; }

# lines USER PRINCIPAL: prints how many lend-ssh lines USER's authorized_keys
# on host1 has, and how many of them name PRINCIPAL.
lines() {
  local keys
  keys=$(host1_keys "$1")
  echo "$(grep -c '^cert-authority,' <<<"$keys") $(grep -cF "cert-authority,principals=\"$2\" " <<<"$keys")"
}

# me_line USER: me's own key is still in USER's authorized_keys on host1.
me_line() { host1_keys "$1" | grep -q ' me@lender$'; }

# listed ACCOUNT TEXT: account lists TEXT on the line after ACCOUNT.
listed() { "$lend_ssh" account | grep -A1 -xF "$1" | tail -n +2 | grep -qF "$2"; }

# unlisted ACCOUNT: account doesn't list ACCOUNT.
unlisted() { ! "$lend_ssh" account | grep -qxF "$1"; }

# acct_clean: removes the files the tests create in agent's home on agentbox.
acct_clean() { as_agent agentbox sh -c 'rm -rf ~/acct ~/acct2 ~/acct-copy'; }

# wait_gone PID SECONDS: waits up to SECONDS for process PID to end.
wait_gone() {
  local i
  for ((i = 0; i < $2 * 5; i++)); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.2
  done
  return 1
}

real_accounts_grant_revoke() {
  make_ca
  expect "accounts: account add sets up two accounts" 0 'deploy@host1' "$lend_ssh" account add dave@host1 deploy@host1
  check "accounts: dave's authorized_keys has the line" test "$(lines dave dave@host1)" = "1 1"
  check "accounts: the line holds the signing key" grep -qF "cert-authority,principals=\"dave@host1\" $(cut -d' ' -f1-2 "$LEND_SSH_CA.pub")" <(host1_keys dave)
  check "accounts: deploy's authorized_keys has its line" test "$(lines deploy deploy@host1)" = "1 1"
  check "accounts: account add keeps the other keys" me_line dave
  expect "accounts: account add again" 0 'already there' "$lend_ssh" account add dave@host1
  check "accounts: account add again adds no line" test "$(lines dave dave@host1)" = "1 1"
  expect "accounts: account lists dave@host1" 0 '^dave@host1' "$lend_ssh" account
  expect "... and deploy@host1" 0 '^deploy@host1' "$lend_ssh" account
  expect "accounts: agent add creates a key at agentbox" 0 '^added agent acct: ' "$lend_ssh" agent add acct ssh://agent@agentbox/~/acct/id_ed25519.pub

  expect "accounts: grant to two accounts" 0 '^acct: (dave@host1 \(new\), deploy@host1 \(new\)|deploy@host1 \(new\), dave@host1 \(new\))' \
    "$lend_ssh" grant -t 1h acct dave@host1 deploy@host1
  expect "accounts: the agent logs in to dave" 0 '^dave$' agent_ssh -i /home/agent/acct/id_ed25519 agentbox dave whoami
  expect "accounts: the agent logs in to deploy" 0 '^deploy$' agent_ssh -i /home/agent/acct/id_ed25519 agentbox deploy whoami
  check "accounts: account lists the agent under dave" listed dave@host1 'acct until '
  check "accounts: account lists the agent under deploy" listed deploy@host1 'acct until '
  expect "accounts: revoke one account" 0 '^acct: revoked deploy@host1; keeps dave@host1' "$lend_ssh" revoke acct deploy@host1
  expect "accounts: the agent can't log in to deploy" fail 'Permission denied' agent_ssh -i /home/agent/acct/id_ed25519 agentbox deploy whoami
  expect "accounts: the agent still logs in to dave" 0 '^dave$' agent_ssh -i /home/agent/acct/id_ed25519 agentbox dave whoami
  expect "accounts: grant lists deploy as revoked" 0 '^acct: .*deploy@host1 \(revoked\)' "$lend_ssh" grant

  # The second grant is shorter, so the certificate keeps the first's end.
  local until
  until=$("$lend_ssh" grant | grep -o ' until .*')
  expect "accounts: grant adds up" 0 "^acct: deploy@host1 \\(new\\), dave@host1 \\(kept\\)$until\$" "$lend_ssh" grant -t 30m acct deploy@host1
  expect "... the agent logs in to deploy again" 0 '^deploy$' agent_ssh -i /home/agent/acct/id_ed25519 agentbox deploy whoami
  expect "... and still to dave" 0 '^dave$' agent_ssh -i /home/agent/acct/id_ed25519 agentbox dave whoami

  "$lend_ssh" agent rm acct >/dev/null
  expect "accounts: account rm" 0 'removed' "$lend_ssh" account rm dave@host1 deploy@host1
  check "accounts: account rm removes dave's line" test "$(lines dave dave@host1)" = "0 0"
  check "accounts: account rm removes deploy's line" test "$(lines deploy deploy@host1)" = "0 0"
  check "accounts: account rm keeps the other keys" me_line dave
  acct_clean
}

# A copy of a certificate outlives revoke until account reset, which also ends
# open sessions.
real_accounts_reset() {
  make_ca
  "$lend_ssh" account add dave@host1 >/dev/null
  "$lend_ssh" agent add acct ssh://agent@agentbox/~/acct/id_ed25519.pub >/dev/null
  "$lend_ssh" grant -t 1h acct dave@host1 >/dev/null
  as_agent agentbox sh -c 'mkdir ~/acct-copy && cp ~/acct/id_ed25519 ~/acct/id_ed25519-cert.pub ~/acct-copy/'
  expect "accounts: reset: the copy logs in" 0 '^dave$' agent_ssh -i /home/agent/acct-copy/id_ed25519 agentbox dave whoami
  expect "accounts: reset: revoke" 0 "^acct: revoked dave@host1; .*account reset dave@host1" "$lend_ssh" revoke acct
  expect "accounts: reset: the agent can't log in after revoke" fail 'Permission denied' agent_ssh -i /home/agent/acct/id_ed25519 agentbox dave whoami
  expect "accounts: reset: the copy still logs in after revoke" 0 '^dave$' agent_ssh -i /home/agent/acct-copy/id_ed25519 agentbox dave whoami
  expect "accounts: reset: account lists dave as revoked" 0 'acct .*revoked' "$lend_ssh" account

  # A session open on the copy when the account is reset.
  agent_ssh -i /home/agent/acct-copy/id_ed25519 agentbox dave sleep 60 >/dev/null 2>&1 &
  local session=$!
  sleep 2
  check "accounts: reset: a session is open" kill -0 "$session"
  expect "accounts: reset: account reset" 0 '^dave@host1: ' "$lend_ssh" account reset dave@host1
  check "accounts: reset: the line names the next number" test "$(lines dave 'dave@host1#2')" = "1 1"
  expect "accounts: reset: the copy can't log in" fail 'Permission denied' agent_ssh -i /home/agent/acct-copy/id_ed25519 agentbox dave whoami
  check "accounts: reset: the open session ends" wait_gone "$session" 20
  kill "$session" 2>/dev/null
  wait "$session" 2>/dev/null
  expect "accounts: reset: grant no longer lists dave as revoked" 0 '^No grants\.' "$lend_ssh" grant
  expect "accounts: reset: grant again" 0 '^acct: dave@host1 \(new\)' "$lend_ssh" grant -t 1h acct dave@host1
  expect "accounts: reset: the agent logs in after the reset" 0 '^dave$' agent_ssh -i /home/agent/acct/id_ed25519 agentbox dave whoami
  expect "accounts: reset: the copy still can't" fail 'Permission denied' agent_ssh -i /home/agent/acct-copy/id_ed25519 agentbox dave whoami

  "$lend_ssh" agent rm acct >/dev/null
  "$lend_ssh" account rm dave@host1 >/dev/null
  docker exec "$id-host1" pkill -u dave -x sleep
  acct_clean
}

# account rm shuts agents out, and account add after it revives no grant.
real_accounts_rm() {
  make_ca
  "$lend_ssh" account add dave@host1 deploy@host1 >/dev/null
  "$lend_ssh" agent add acct ssh://agent@agentbox/~/acct/id_ed25519.pub >/dev/null
  "$lend_ssh" grant -t 1h acct dave@host1 deploy@host1 >/dev/null
  expect "accounts: rm: the agent logs in" 0 '^dave$' agent_ssh -i /home/agent/acct/id_ed25519 agentbox dave whoami
  expect "accounts: rm: account rm" 0 'removed' "$lend_ssh" account rm dave@host1
  check "accounts: rm: the line is gone" test "$(lines dave dave@host1)" = "0 0"
  check "accounts: rm: me's key stays" me_line dave
  expect "accounts: rm: the agent can't log in" fail 'Permission denied' agent_ssh -i /home/agent/acct/id_ed25519 agentbox dave whoami
  expect "accounts: rm: the other account still works" 0 '^deploy$' agent_ssh -i /home/agent/acct/id_ed25519 agentbox deploy whoami
  check "accounts: rm: account doesn't list it" unlisted dave@host1
  expect "accounts: rm: grant refuses it" 1 "dave@host1 isn't set up" "$lend_ssh" grant -t 1h acct dave@host1 </dev/null
  expect "accounts: rm: account add again" 0 'dave@host1' "$lend_ssh" account add dave@host1
  expect "accounts: rm: the old grant stays cancelled" fail 'Permission denied' agent_ssh -i /home/agent/acct/id_ed25519 agentbox dave whoami
  expect "accounts: rm: grant again" 0 'dave@host1 \(new\)' "$lend_ssh" grant -t 1h acct dave@host1
  expect "accounts: rm: the agent logs in again" 0 '^dave$' agent_ssh -i /home/agent/acct/id_ed25519 agentbox dave whoami

  "$lend_ssh" agent rm acct >/dev/null
  "$lend_ssh" account rm dave@host1 deploy@host1 >/dev/null
  acct_clean
}

# An agent given as text: grant prints the certificate, put in place by hand,
# and so does a grant to a key read from stdin.
real_accounts_text() {
  make_ca
  "$lend_ssh" account add dave@host1 deploy@host1 >/dev/null
  as_agent agentbox mkdir /home/agent/acct
  as_agent agentbox ssh-keygen -q -t ed25519 -N '' -C acct -f /home/agent/acct/id_ed25519
  local pub
  pub=$(as_agent agentbox cat /home/agent/acct/id_ed25519.pub)
  expect "accounts: text: agent add" 0 '^added agent txt: ssh-ed25519 ' "$lend_ssh" agent add txt "$pub"
  "$lend_ssh" grant -t 1h txt dave@host1 >grant.out 2>grant.err
  check "accounts: text: grant prints the certificate" grep -q '^ssh-ed25519-cert-v01@openssh.com ' grant.out
  docker exec -i -u agent "$id-agentbox" sh -c 'cat >~/acct/id_ed25519-cert.pub' <grant.out
  expect "accounts: text: the agent logs in" 0 '^dave$' agent_ssh -i /home/agent/acct/id_ed25519 agentbox dave whoami
  expect "accounts: text: agent lists the grant" 0 'dave@host1 until ' "$lend_ssh" agent
  expect "accounts: text: revoke" 0 '^txt: revoked dave@host1; a copy' "$lend_ssh" revoke txt
  "$lend_ssh" agent rm txt >/dev/null

  # README's pipeline: the key from stdin, the certificate to the agent.
  docker exec -u agent "$id-agentbox" cat /home/agent/acct/id_ed25519.pub | "$lend_ssh" grant -t 1h - deploy@host1 2>grant.err |
    docker exec -i -u agent "$id-agentbox" sh -c 'cat >~/acct/id_ed25519-cert.pub'
  check "accounts: text: a grant to a key from stdin goes under its comment" grep -q '^acct: deploy@host1 (new)' grant.err
  expect "accounts: text: a key from stdin logs in" 0 '^deploy$' agent_ssh -i /home/agent/acct/id_ed25519 agentbox deploy whoami
  expect "accounts: text: a key from stdin replaces the certificate" fail 'Permission denied' agent_ssh -i /home/agent/acct/id_ed25519 agentbox dave whoami

  "$lend_ssh" account rm dave@host1 deploy@host1 >/dev/null
  acct_clean
}

# account add -p: the line added by hand opens the account.
real_accounts_print() {
  make_ca
  local line
  line=$("$lend_ssh" account add -p dave@host1 | grep '^cert-authority,')
  check "accounts: print: account add -p prints the line" test -n "$line"
  check "accounts: print: account add -p adds nothing" test "$(lines dave dave@host1)" = "0 0"
  docker exec -i "$id-host1" sh -c 'cat >>/home/dave/.ssh/authorized_keys' <<<"$line"
  "$lend_ssh" agent add acct ssh://agent@agentbox/~/acct/id_ed25519.pub >/dev/null
  expect "accounts: print: grant takes the account" 0 '^acct: dave@host1 \(new\)' "$lend_ssh" grant -t 1h acct dave@host1
  expect "accounts: print: the agent logs in" 0 '^dave$' agent_ssh -i /home/agent/acct/id_ed25519 agentbox dave whoami

  "$lend_ssh" agent rm acct >/dev/null
  "$lend_ssh" account rm dave@host1 >/dev/null
  check "accounts: print: account rm removes the line added by hand" test "$(lines dave dave@host1)" = "0 0"
  acct_clean
}

# Sessions end when the certificate expires, and with -D run on.
real_accounts_deadline() {
  make_ca
  "$lend_ssh" account add dave@host1 deploy@host1 >/dev/null
  "$lend_ssh" agent add acct ssh://agent@agentbox/~/acct/id_ed25519.pub >/dev/null
  "$lend_ssh" agent add acct2 ssh://agent@agentbox/~/acct2/id_ed25519.pub >/dev/null
  # The -D grant ends 5s before the other, whose session's end is waited for
  # before checking that the -D session runs on.
  expect "accounts: deadline: grant -D for 5s" 0 '^acct2: deploy@host1 \(new\)' "$lend_ssh" grant -D -t 5s acct2 deploy@host1
  agent_ssh -i /home/agent/acct2/id_ed25519 agentbox deploy sleep 60 >/dev/null 2>&1 &
  local nodeadline=$!
  expect "accounts: deadline: grant for 10s" 0 '^acct: dave@host1 \(new\)' "$lend_ssh" grant -t 10s acct dave@host1
  agent_ssh -i /home/agent/acct/id_ed25519 agentbox dave sleep 60 >/dev/null 2>&1 &
  local session=$!
  expect "accounts: deadline: agent show has the deadline" 0 'deadline' "$lend_ssh" agent show acct
  expect "accounts: deadline: agent marks -D" 0 'no session deadline' "$lend_ssh" agent
  sleep 2
  check "accounts: deadline: a session is open" kill -0 "$session"
  check "accounts: deadline: a -D session is open" kill -0 "$nodeadline"
  check "accounts: deadline: the session ends at the expiry" wait_gone "$session" 20
  expect "accounts: deadline: the agent can't log in after the expiry" fail 'Permission denied' agent_ssh -i /home/agent/acct/id_ed25519 agentbox dave whoami
  expect "accounts: deadline: the -D agent can't log in after its expiry" fail 'Permission denied' agent_ssh -i /home/agent/acct2/id_ed25519 agentbox deploy whoami
  check "... but its session runs on" kill -0 "$nodeadline"
  expect "accounts: deadline: agent shows no grant" 0 'no grant' "$lend_ssh" agent
  kill "$session" "$nodeadline" 2>/dev/null
  wait "$session" "$nodeadline" 2>/dev/null

  "$lend_ssh" agent rm acct acct2 >/dev/null
  "$lend_ssh" account rm dave@host1 deploy@host1 >/dev/null
  docker exec "$id-host1" pkill -u dave -x sleep
  docker exec "$id-host1" pkill -u deploy -x sleep
  acct_clean
}
