# scripts

The terminal commands I type most often, kept as scripts instead of as shell history I have to
re-derive. If I've typed a pipeline more than a handful of times — or had to reconstruct its flags
from `Ctrl-R` — it belongs here as a named, documented, argument-taking script.

`~/scripts` is on `PATH` (see [Install](#install)), so every file here is callable by name from any
directory. Scripts operate on `$PWD` (or an explicit path argument), never on a hardcoded repo, so
the same command works across every checkout.

## Conventions

- **POSIX `sh` unless bash is needed.** `#!/bin/sh` by default; `#!/usr/bin/env bash` when the
  script wants arrays or `set -o pipefail`. Bash scripts use `set -euo pipefail`.
- **Header comment is the spec.** Line 1 is the shebang; then a comment block giving the script's
  one-line purpose, its `Usage:` line, and the non-obvious semantics — what a column means, how a
  check can be wrong, which flags mutate state. `-h`/`--help` prints that block where it's worth
  wiring up.
- **Read-only by default; mutation behind a flag.** No script changes git state, deletes, or pulls
  unless an explicit switch asks for it (`-clean`, `-update`). Destructive paths prefer the safe
  primitive (`git branch -d` over `-D`) so a wrong assumption in the script fails closed.
- **Executable and committed.** `chmod +x` on add, and the file is tracked here — this repo is the
  source of truth, not the machine.
- **macOS-flavoured.** `stat -f`, `date -r` and friends are BSD spellings; these are not written for
  Linux.

## Scripts

| Script | What it does |
| --- | --- |
| `current_branches.sh` | Lists local branches oldest-commit-first with a `MERGED` column that catches squash merges, not just fast-forward ancestry. `-clean` deletes the merged ones; `-update` pulls the base branch into every branch; `--poll <sec>` redraws on a timer to watch another process commit. |
| `recent-files.sh` | Newest *n* files under a root, printed oldest-first with timestamps — "what did I actually touch last session". `-a` includes dotfiles; `--poll <sec>` re-walks on a timer to watch a directory being written. |

Examples:

```sh
current_branches.sh                    # base branch inferred: main, else master
current_branches.sh master -clean      # prune everything already squash-merged into master
current_branches.sh main -update ~/code/papercutsoftware/ipp
current_branches.sh --poll 5           # redraw every 5s — watch a Claude session commit

recent-files.sh                        # 10 newest files under $PWD
recent-files.sh ~/code/wpp-transition 30
recent-files.sh --poll 3 ~/code/papercutsoftware/ipp 20   # watch a session write files
```

## Install

`~/.zshrc` prepends this directory to `PATH`:

```sh
export PATH="$HOME/scripts:$PATH"
```

Prepended rather than appended so a script here deliberately shadows a same-named system command.
New shells pick it up; in an existing one, `source ~/.zshrc`.

## Adding a script

```sh
cd ~/scripts
printf '#!/bin/sh\n' > newthing.sh          # then the header comment block
chmod +x newthing.sh
git add newthing.sh && git commit -m "add newthing.sh"
```

The `.sh` extension is kept in the invoked name (`recent-files.sh`, not `recent-files`) so it's
obvious at the prompt that a shell script is running rather than a binary. Naming is inconsistent
about `_` vs `-` today; new scripts use `-`.
