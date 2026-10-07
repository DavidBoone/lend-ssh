# shellcheck shell=bash
# lend-ssh's tab completion for bash, which bash-completion loads from its
# completions directory. It hands the words to lend-ssh __complete, and
# completes file names instead when that exits 1. It drops the descriptions
# after a tab, which bash can't show.
_lend_ssh() {
  local ret=0 out line cur re='^([^@=:]*)([@=:])(.*)$'
  local -a words=("${COMP_WORDS[@]:1:$COMP_CWORD}")
  # bash 3 leaves dave@host, --id=x and a:b whole, where bash 4 splits them
  # at @, = and :, as readline does; this splits the current word likewise.
  if ((BASH_VERSINFO[0] < 4 && ${#words[@]})); then
    cur=${words[${#words[@]}-1]}
    if [[ $cur == *[@=:]* ]]; then
      unset 'words[${#words[@]}-1]'
      while [[ $cur =~ $re ]]; do
        [[ -z ${BASH_REMATCH[1]} ]] || words+=("${BASH_REMATCH[1]}")
        words+=("${BASH_REMATCH[2]}")
        cur=${BASH_REMATCH[3]}
      done
      [[ -z $cur ]] || words+=("$cur")
    fi
  fi
  out=$(lend-ssh __complete ${words[@]+"${words[@]}"}) || ret=$?
  COMPREPLY=()
  if [[ -n $out ]]; then
    while IFS= read -r line; do
      COMPREPLY+=("${line%%$'\t'*}")
    done <<<"$out"
  fi
  if ((ret == 1)); then
    compopt -o default 2>/dev/null
  fi
  return 0
}
# bash 3.2 has no compopt, so there it falls back to file names whenever
# nothing else matches.
if type compopt >/dev/null 2>&1; then
  complete -F _lend_ssh lend-ssh
else
  complete -o default -F _lend_ssh lend-ssh
fi
