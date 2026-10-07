#!/usr/bin/env python3
"""Completes command lines in a real interactive shell, through a pty, with
lend-ssh's completion loaded, and prints each line as the shell completed it.

    test/tab-complete.py [--files DIR] [--list] bash|zsh LINE...

For each LINE it waits for the shell's prompt, types the line and Tab, then
Ctrl-A and `echo RESULT: `, and Enter: the shell handles keys in order,
completion included, so the echoed line is the completed one. Keys typed before
the prompt would reach the terminal's own line editing instead of the shell's,
so nothing is typed until the prompt shows. The environment (HOME, PATH) is
passed through.

The completion is loaded with eval "$(lend-ssh completion)", or with --files
from the files install links: DIR is zsh's directory on $fpath, holding
_lend-ssh, or for bash, bash-completion's directory for your own, holding
completions/lend-ssh, with bash-completion loaded.

--list prints what the shell lists for each LINE instead, a line each, after
Tab (and a second Tab for bash): in zsh, the words with their descriptions.
"""
import os
import pty
import re
import select
import sys
import time

args = sys.argv[1:]
files = None
listing = False
while args and args[0].startswith("--"):
    if args[0] == "--files":
        files, args = args[1], args[2:]
    elif args[0] == "--list":
        listing, args = True, args[1:]
    else:
        sys.exit(f"tab-complete: unknown option {args[0]}")
shell, lines = args[0], args[1:]
prompt = "tab-complete> "
argv = {"bash": ["bash", "--norc", "--noprofile", "-i"], "zsh": ["zsh", "-f", "-i"]}[shell]
env = dict(os.environ, TERM="dumb", PS1=prompt, PROMPT=prompt)

pid, fd = pty.fork()
if pid == 0:
    os.execvpe(argv[0], argv, env)

out = b""


def wait_for(marker, timeout=30):
    """Reads until the output holds marker; returns what came before it."""
    global out
    end = time.time() + timeout
    while marker not in out:
        if time.time() > end:
            sys.exit(f"tab-complete: {shell} timed out; output so far: {out[-500:]!r}")
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            out += os.read(fd, 65536)
    head, _, out = out.partition(marker)
    return head


def settle(quiet=0.5, timeout=10):
    """Reads until the shell has printed nothing for quiet seconds."""
    global out
    end = time.time() + timeout
    last = time.time()
    while time.time() - last < quiet and time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            out += os.read(fd, 65536)
            last = time.time()


def bash_completion():
    for f in ("/usr/share/bash-completion/bash_completion",
              "/opt/homebrew/share/bash-completion/bash_completion",
              "/usr/local/share/bash-completion/bash_completion"):
        if os.path.isfile(f):
            return f
    sys.exit("tab-complete: no bash-completion to load")


# zsh picks vi keys when $EDITOR mentions vi, and Ctrl-A needs emacs keys. Its
# compinit asks before using group-writable function directories, as a CI
# runner's are; -u skips that, and the shim then finds compinit already run.
if shell == "zsh":
    setup = "bindkey -e; "
    if files:
        load = f"fpath=('{files}' $fpath); autoload -Uz compinit && compinit -u -D"
    else:
        load = 'autoload -Uz compinit && compinit -u; eval "$(lend-ssh completion)"'
else:
    setup = "set -o emacs; "
    if files:
        load = f"BASH_COMPLETION_USER_DIR='{files}'; source '{bash_completion()}'"
    else:
        load = 'eval "$(lend-ssh completion)"'
wait_for(prompt.encode())
os.write(fd, f"{setup}{load}\n".encode())
wait_for(prompt.encode())
for line in lines:
    if listing:
        os.write(fd, line.encode() + (b"\t\t" if shell == "bash" else b"\t"))
        settle()
        shown, out = out, b""
        os.write(fd, b"\x03")
        wait_for(prompt.encode())
        text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", shown.decode(errors="replace"))
        for row in text.replace("\r", "").split("\n")[1:]:
            if row.strip() and not row.startswith(prompt):
                print(row.rstrip())
        continue
    os.write(fd, line.encode() + b"\t\x01echo RESULT: \n")
    # the terminal echoes the typed "echo RESULT: " too, but not after a newline
    wait_for(b"\nRESULT: ")
    print(wait_for(b"\r\n").decode().rstrip())
    wait_for(prompt.encode())
os.write(fd, b"exit\n")
os.waitpid(pid, 0)
