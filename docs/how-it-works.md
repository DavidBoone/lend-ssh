# How it works

The details behind the [README](../README.md): how lend-ssh names accounts,
what a certificate contains, how sessions end, and where it keeps things.

## Accounts

`account add` adds a line to the account's `~/.ssh/authorized_keys`, as the
[README](../README.md#getting-started) shows, naming the account:
`principals="dave@myhost"`. The account then accepts certificates from your
signing key that carry that name, and no others. `-k FILE` names the
`authorized_keys` file on a host that keeps it elsewhere.

An `authorized_keys` file holds one line from your signing key. Running
`account add` again changes nothing; for another account whose
`authorized_keys` is the same file, such as a host you reach under two names,
or a home directory shared between hosts, it replaces the line, and says
whose line it replaced.

`account add -p` prints the line instead of adding it, and records the account
as set up, so that `grant` accepts it.

The name is the user and host name `ssh -G` gives for the account: your user
name unless you give one or your ssh config sets `User`, and the host's
`HostName` from your ssh config, in lower case. So `myhost`, `dave@myhost` and
an alias for it all name `dave@myhost`, and every command agrees on it. To
sshd it is only a label, matched against the certificate.

Two hand-edited lines with the same name are opened by the same
certificates.

### Account numbers

Each account set up from here has a number, kept in
`~/.config/lend-ssh/accounts/`. At first the account's name is `dave@myhost`.
Each `account reset` or `account rm` moves it to its next number, and its name
in the line and in new certificates becomes `dave@myhost#2`, `#3`, and so on.

Certificates made under an earlier name no longer match the line, so they stop
working, copies included. This cancels every agent's grants to the account at
once: a line names only the account, so it can't single out one agent's
certificate. `account add` after `account rm` uses the next number too, and
revives no grant made before.

## Certificates

A certificate from `grant`:

- names the accounts granted, each of which must be set up from here
- is valid from 5 minutes before the grant, in case a host's clock runs slow,
  until its end, as long after the grant as `-t` says
- has the session deadline as its forced command (below)
- allows a shell and commands only: no port, agent or X11 forwarding, and no
  `~/.ssh/rc`. `-O` adds these back: `permit-port-forwarding`,
  `permit-agent-forwarding`, `permit-X11-forwarding`, `permit-user-rc`, or any
  other `ssh-keygen -O` option
- carries the agent's name, which hosts log with each login (`-I` sets
  another). A grant to a key rather than an agent carries the key's comment,
  or `agent` for a key without one

A grant only adds: while the agent's certificate is valid, the new one keeps
the accounts it already opens, and its end if that's later. A grant with other
options than the current certificate's, such as `-O` or `-D`, is refused until
you `revoke` the agent.

`revoke AGENT` reissues the certificate without those accounts, with the same
end, or removes it when none are left. It changes only the file beside the
agent's key (and lend-ssh's copy, below), so a copy of the old certificate
works until it expires.
`revoke` and `agent rm` note each account they take back, with the old
certificate's end, and `grant`, `agent` and `account` list the account as
revoked until then. The note goes once `account reset` or `account rm`
cancels the account's certificates, or a later grant to the same key opens
the account for at least as long.

## Session deadline

sshd checks a certificate only when a connection logs in. Without more, a
session started before the certificate expires runs on after it, and so does
an ssh connection kept open for reuse (`ControlMaster` with `ControlPersist`),
which opens new sessions without logging in again.

So `grant` makes its certificates' forced command a small `sh` script holding
the expiry time. sshd runs it for every session the certificate opens,
whatever the agent asked to run.

- After the expiry, the script refuses the session.
- Before it, the script runs what was asked for: a command, a login shell or
  sftp. At the expiry it sends that SIGHUP, and SIGKILL 10 seconds later. A
  session with no terminal gets them as a process group.
- It times this with GNU `timeout`, or else with `perl`, and refuses sessions
  on a host that has neither.

While the session runs, a watcher checks every 10 seconds that the account's
`~/.ssh/authorized_keys` still has the line naming it, and ends the session
the same way once it hasn't; this is how `account reset` and `account rm` end
open sessions. On a host that keeps the line in another file (`-k FILE`),
there's no watcher, and sessions end at the expiry.

`grant -D` leaves the deadline out, for a host where it gets in the way;
sessions then outlast the certificate, and `agent` marks it. A forced command
of your own, `-O force-command=…`, needs `-D`, since a certificate holds one.

On a host whose sshd runs sftp as `internal-sftp`, the script runs the first
`sftp-server` program it finds in `/usr/lib/openssh`, `/usr/libexec/openssh`,
`/usr/libexec` and `/usr/lib/ssh`, with the arguments `internal-sftp`
was given.

The deadline doesn't end processes the agent detaches from the session, such
as one started with `setsid` or `nohup`, and an agent with a shell can kill
the watcher.

## Agents

An agent is a file in `~/.config/lend-ssh/agents` holding its public key's
absolute path, its location, or `-` when `agent add` is given the key as
text, whole line or `AAAA…` part. Its name is letters, digits, `_` and `-`,
not starting with `-`. `agent add -f` replaces an agent. A private key's path
stands for the `.pub` beside it.

### Locations

A location is a key file that lend-ssh reaches by running a short `sh`
script there, with the file's contents in the script:

| Location | Runs the script with |
|---|---|
| `ssh://[USER@]HOST[:PORT]/PATH` | `ssh [-p PORT] -- [USER@]HOST sh -s` |
| `docker://CONTAINER/PATH` | `docker exec -i CONTAINER sh -s` |
| `docker-volume://VOLUME/PATH` | `docker run --rm -i --network none -v VOLUME:/lend-ssh-volume alpine sh -s` |

A PATH starting with `~/` is from the home directory there, and any other
from `/`; in a volume, PATH is from the volume's top.

`agent add` also takes `[USER@]HOST:PATH`, a colon before any `/` as for
`scp`, when no file of that name is here: `ssh://[USER@]HOST/~/PATH`, or
`ssh://[USER@]HOST/PATH` for a PATH from `/`. A PATH of digits alone is
refused, as it looks like a port. `[USER@]HOST:` alone stands for the
default keys there: the first of `~/.ssh/id_ed25519.pub`, `~/.ssh/id_ecdsa.pub`
and `~/.ssh/id_rsa.pub` that exists, read in one connection. When none does
but one's private key does, it refuses, as for any private key with no
public key; with none of them, it creates `~/.ssh/id_ed25519`. `[USER@]HOST`
alone means the same when no file of that name is here and ssh knows the
host: it's a `Host` in `~/.ssh/config`, or `ssh-keygen -F` finds the host
name and port that `ssh -G` gives for it (`[NAME]:PORT` for a port other than
22) in the `UserKnownHostsFile` or `GlobalKnownHostsFile` files that `ssh -G`
names, hashed or not. A PATH is letters,
digits and `._@+-/`. `LEND_SSH_VOLUME_IMAGE` sets another image than
`alpine`, which needs `sh`, `ls`, `awk`, `chown` and `mv`. lend-ssh checks
that the volume exists before it runs the container, since `docker run`
would create one with a mistyped name.

The script writes a file to a temporary name beside it, then moves it into
place. Run as root, as in the volume's container, it gives the file the
owner of its directory, and a directory it creates the owner of the
directory above. A certificate is readable by all, a private key only by its
owner.

For these agents, and those given as text, lend-ssh keeps the public key and
the latest certificate in `~/.config/lend-ssh/keys/NAME`, and works from
those copies as it does from the files beside a key here: `grant` adds to the
copy, then writes it to the location, and `agent`, `account` and `grant`
with no agent read only the copies. When `grant` can't write to the
location, it exits 1 with the copy already changed, so lend-ssh counts the
grant as made, which it may be; granting again writes it again. When
`revoke` can't, it puts the copy back as it was and exits 1, so revoking
again retries. When `agent rm` can't, it notes the accounts as revoked, as
for any copy, and forgets the agent; it reaches the location only for a
valid certificate.

`agent add` with a location reads the public key there once, and when the
private key beside it is there too and so is `ssh-keygen`, runs
`ssh-keygen -y -P ''` on it; when that reports a passphrase, `agent add`
warns that the agent can use the key only through an ssh-agent. It checks a
key here the same way. While an agent
has a valid certificate, `agent add -f` refuses to replace it by another key,
or by the same key somewhere the certificate wouldn't follow, since that
would leave the certificate working where lend-ssh no longer looks. It takes
the same key at the same path here, or, for an agent at a location or given
as text, at any location or as text: it removes the certificate from the
old location, then writes it to the new one, or prints it for text.

When `agent add` is given a path with no key there, it creates one, with no
passphrase; for a location, it creates the key on this machine, writes both
files there, and deletes them here. So that a mistyped path doesn't quietly
make a new key, it does this only when the key's directory or that
directory's parent exists, and the directory holds no other `.pub` file;
when it holds one, the refusal gives the `agent add` command that takes it. A
path for a new key must contain a `/`, such as `./id_ed25519.pub`.

`grant`, `revoke` and `agent show` also take a key file's path in place of an
agent's name, and `grant` takes a public key or `-` too. A name is looked up
before a file of that name.

## Files

`~/.config/lend-ssh` (or `$XDG_CONFIG_HOME/lend-ssh`) holds:

- `ca`, the signing key, and `ca.pub`; `LEND_SSH_CA` sets another path
- `agents/`, a file per agent
- `keys/`, a directory per agent at a location or given as text, holding its
  public key, `key.pub`, and its latest certificate, `key-cert.pub`
- `accounts/`, a file per account set up from here, holding its number
- `revoked`, a line per account taken back with `revoke` or `agent rm` whose
  old certificate still works

Certificates are written beside the agents' keys, as `id_ed25519-cert.pub`
for `id_ed25519.pub`, here or at their locations.

## Install and tab completion

`install` links `lend-ssh` into the first of `~/.local/bin`, `~/bin`,
`/opt/homebrew/bin` and `/usr/local/bin` that is on your `PATH` and writable,
else into `~/.local/bin`, and then tells you the line that puts it on your
`PATH`. `install DIR` links it into `DIR` instead, and `-f` replaces a file
already there.

It also links the files in `completions/` where the shells load them:

- zsh's `_lend-ssh` into the first directory on your `$fpath` that you can
  write to, such as Homebrew's `/opt/homebrew/share/zsh/site-functions`, when
  your zsh runs `compinit`
- bash's into `~/.local/share/bash-completion/completions` (or under
  `$XDG_DATA_HOME` or `$BASH_COMPLETION_USER_DIR`), when your bash loads
  bash-completion 2

It finds these by starting each shell as a login shell. Where neither applies
to your login shell, it prints a line to add to your shell's startup file
instead:

```sh
eval "$(lend-ssh completion)"
```

Completion covers commands, options, `-O`'s forwarding options, agents' names
and accounts. For `account add` and `account rm`, an account's host comes from
your `~/.ssh/config` and `~/.ssh/known_hosts`. For `grant` and `account
reset`, only the accounts set up from here are offered, and for `revoke`, only
those the agent's certificate is for: each as a `Host` alias in
`~/.ssh/config` that leads to it, else as its host alone when that leads to
it, else as `USER@HOST`. Where an agent's name goes, a key file completes once the
word looks like a path: it has a `/`, or starts with `.` or `~`. `agent
add`'s KEY completes as a file too, except for the start of a location
(`ssh://` and the rest, with the hosts, running containers or volumes), or,
when no file here starts with the word, as `[USER@]HOST` from the same hosts
as `account add`. In zsh,
commands and options are listed with what they do.

`uninstall` removes the links `install` made in the directories on your
`PATH`, the ones `install` picks from, and the completion directories, and
leaves anything else of those names; `uninstall DIR` also looks in `DIR`. It
then lists what stays, with the command that removes each: each account's
line, agents' certificates, your signing key, agents and accounts in
`~/.config/lend-ssh`, and the clone.
