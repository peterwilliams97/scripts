# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`~/scripts` — a flat collection of standalone shell scripts, one file per command, all on `PATH`
via `export PATH="$HOME/scripts:$PATH"` in `~/.zshrc`. There is no build, no package manifest, no
module graph. Each script is independently executable and shares nothing with the others; the only
cross-file coupling is documentary (see *Adding a script*).

Read `README.md` first — it is the living spec for conventions (POSIX `sh` by default, bash only
for arrays/`pipefail`; read-only unless an explicit mutation flag; macOS/BSD utility spellings).
Repeating those here would just create a second source of truth.

## Running and verifying a script

The Bash tool's shell does not source `~/.zshrc`, so `PATH` does not contain this directory.
Invoking a script by bare name will fail. Two options:

```sh
zsh -c 'source ~/.zshrc 2>/dev/null; current_branches.sh; echo "---exit=$?"'   # as the user runs it
/Users/peterw/scripts/current_branches.sh                                      # direct path
```

Use the `zsh -c` form when the thing being verified *is* the PATH wiring; the direct path otherwise.

There is no test harness in this repo — no `test.sh`, no shellcheck/shfmt installed. Verification is
running the script against a real directory and reading the output. `current_branches.sh` is
read-only without `-clean`/`-update`, so it is safe to run anywhere; when exercising `-clean` or
`-update`, do it against a throwaway clone, never `~/code/...`.

## The header comment block is load-bearing

In `current_branches.sh` the `-h`/`--help` handler prints the file's own header by extracting it
with `sed -n '2,/^set -euo/p'` (`current_branches.sh:35`). The block therefore must start on line 2
and the *first* `set -euo` in the file must be the one immediately after it. Inserting a comment
line above the block, or an earlier `set -euo pipefail`, silently truncates or bloats `--help`.
Check `--help` output after editing any header in a script that wires this up.

## Adding or renaming a script

Three places must change together, or the repo lies about itself:

1. The script file — `chmod +x`, shebang on line 1, header block giving purpose, `Usage:`, and the
   non-obvious semantics.
2. `README.md` — the *Scripts* table, and the *Examples* block if the invocation isn't obvious.
3. Nothing else. There is no index, registry, or manifest to update.

New scripts use `-` as the word separator (`recent-files.sh`), not `_`; `current_branches.sh`
predates that rule and keeps its name. The `.sh` extension stays in the invoked name deliberately.

## Non-obvious behaviour worth knowing before editing

`current_branches.sh`'s `is_merged()` decides the `MERGED` column and gates `-clean`'s deletions.
It tries `git merge-base --is-ancestor` first, then falls back to comparing the branch's net diff
against `git patch-id` of every commit base absorbed since the merge base. The comment at
`current_branches.sh:132-135` records a rejected earlier approach (file-scoped `diff base..branch`)
that produced false positives — false positives here mean deleted branches, so treat any
simplification of this function as a correctness change, not a cleanup, and construct a repo with a
squash-merged branch plus an unmerged branch to test both directions.
