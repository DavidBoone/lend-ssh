# lend-ssh

A single bash script, `lend-ssh`, that lends agents short-lived SSH access with
OpenSSH user certificates. `README.md` is the guide for a new user;
`docs/how-it-works.md` has the details behind it, and `docs/alternatives.md`
compares it with other tools.

## Commands

`./lend-ssh help` lists the commands and `./lend-ssh COMMAND -h` shows one;
use those names in code, docs, tests and conversation. Every option has a
short and a long form; `-f`/`--force` always means force, and a file option
is `-k`/`--file FILE`. Usage errors exit 2, other errors 1.

## Layout

- `lend-ssh`: the whole tool. `command_table` and `option_table` near the top
  are the one list of commands and options; help, the parser
  (`parse_options`), usage errors and tab completion are built from them, so a
  new command or option starts there. Each command is a `cmd_*` function named
  after it (`cmd_grant`, `cmd_account_add`), called with the arguments left
  after its options, which `opt_value` reads.
- `completions/`: thin bash and zsh shims that call `lend-ssh __complete`;
  the completion logic is `cmd_complete` in the script.
- `test/run.sh`: the tests that run anywhere. `test/tab-complete.py` drives
  real bash and zsh for the completion tests, and `test/fake-docker` stands
  in for docker, with directories for containers and volumes. The ssh://
  tests use a fake ssh, and the end-to-end tests a real one.
- `test/real.sh`: the tests between real machines, in `test/real/*.sh`, which
  `test/docker.sh` runs in containers it starts (`test/Dockerfile`).
  `test/lib.sh` has the helpers both use.

## Constraints

- Bash 3.2 compatible (macOS's `/bin/bash`): no associative arrays,
  `mapfile`, `${var,,}`, `readlink -f` and the like.
- Runs on macOS and Linux, so only flags both BSD and GNU tools accept.
- shellcheck clean; `test/run.sh` runs it.

## Tests

`test/run.sh` runs shellcheck, the command-line and completion tests and, when
it finds `sshd`, end-to-end tests against throwaway sshds on 127.0.0.1 from
port 2222; `SSHD`, `SSHD_PORT` and `SSHD_EXTRA_CONFIG` change how those
sshds run. `test/docker.sh` needs only Docker: it runs `test/run.sh` in a
Debian container that has `sshd`, so nothing is skipped, then `test/real.sh`
on a network of real containers: a lender running lend-ssh with the Docker
socket, a host with the accounts, an agent machine reached over ssh, an agent
container and an agent's volume. `test/docker.sh run` or `real [FILE...]`
runs one part. CI (`.github/workflows/test.yml`) runs `test/run.sh` on
Ubuntu and macOS, and `test/docker.sh` on Ubuntu. A
change to a command updates its help, completion, README or
`docs/how-it-works.md`, and tests together.
