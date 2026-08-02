#!/usr/bin/env bash
# current_branches.sh — list local branches of the current repo, ascending by
# last-commit time, with whether each is fully merged into a named base branch.
#
# Usage: current_branches.sh [<dir>] [<base-branch>] [-clean] [-update] [--poll <sec>]
#
# <dir> is the clone to inspect and defaults to `.`. The two positionals are told apart
# by what they name, not by their order: an argument that is an existing directory is
# <dir>, anything else is <base-branch>. So `current_branches.sh ~/code/foo` and
# `current_branches.sh master ~/code/foo` both do what they look like. A base branch
# whose name collides with a directory in the current directory is the one case the
# guess gets wrong — pass `--base <branch>` or `-C <dir>` to say which is which.
#
# <base-branch> defaults to `main` if that ref exists locally, otherwise `master`.
# The "merged" column is yes/no — yes means the branch's changes are present in
# <base-branch> via any merge strategy (regular merge OR squash merge). A branch is
# merged if its tip is an ancestor of <base-branch>; failing that, if the patch-id of
# its net diff since the merge base matches the patch-id of some commit <base-branch>
# absorbed since that merge base — which is what a squash merge produces. A squash
# commit that was hand-edited, or split, has a different patch-id and so reports "no":
# the check fails closed, never deleting a branch it can't prove is merged. Branches
# equal to <base-branch> show "-". The current branch is marked with "*".
#
# -clean   delete every local branch fully merged into <base-branch>, excluding
#          <base-branch> and the current branch. Uses `git branch -d` (lowercase),
#          which refuses to force-delete unmerged branches even if our
#          merged-set check is wrong.
# -update  for every local branch, checkout and run `git pull origin <base-branch>`.
#          Requires a clean working tree. Restores the original branch on
#          completion. On a per-branch pull failure, aborts the merge and
#          continues; failures are summarised at the end.
# --poll <sec>
#          redraw the table every <sec> seconds until Ctrl-C, for watching another
#          process (a Claude Code session, a long rebase) move branches around. Each
#          iteration re-reads refs from disk and re-runs the merged check, so a new
#          branch or a fresh commit shows up on the next tick. On a terminal the
#          screen and scrollback are cleared before each redraw; when redirected to a
#          file or pipe, iterations are appended with a blank line between them.
#          Mutually exclusive with -clean and -update — both mutate the repo, and a
#          mutation on a timer is not something to arm by accident.
# -C <dir> the clone to inspect, stated explicitly instead of positionally. `--dir` is
#          a synonym; both accept `-C=<dir>` too.
# --base <branch>
#          the base branch, stated explicitly. Use this when the branch name is also a
#          directory name here, which is the only case the positional guess misreads.

set -euo pipefail

CLEAN=0
UPDATE=0
POLL=""
REPO_DIR=""
BASE_BRANCH=""

while [ $# -gt 0 ]; do
    case "$1" in
        -clean)  CLEAN=1 ;;
        -update) UPDATE=1 ;;
        -poll|--poll)
            if [ $# -lt 2 ]; then
                echo "current_branches.sh: $1 requires a seconds argument" >&2
                exit 2
            fi
            POLL="$2"
            shift
            ;;
        -poll=*|--poll=*) POLL="${1#*=}" ;;
        -C|--dir)
            if [ $# -lt 2 ]; then
                echo "current_branches.sh: $1 requires a directory argument" >&2
                exit 2
            fi
            REPO_DIR="$2"
            shift
            ;;
        -C=*|--dir=*) REPO_DIR="${1#*=}" ;;
        --base)
            if [ $# -lt 2 ]; then
                echo "current_branches.sh: --base requires a branch argument" >&2
                exit 2
            fi
            BASE_BRANCH="$2"
            shift
            ;;
        --base=*) BASE_BRANCH="${1#*=}" ;;
        -h|--help)
            # -E: BSD sed's BRE has no `\?` quantifier, so `s|^# \?||` would match a
            # literal `?` and leave every line still prefixed with "# ".
            sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed -E 's|^# ?||'
            exit 0
            ;;
        -*)
            echo "current_branches.sh: unknown switch: $1" >&2
            exit 2
            ;;
        *)
            # Positionals are identified by what they name rather than by position: the
            # old fixed order made `current_branches.sh ~/code/foo` read the path as a
            # branch and then fail about $PWD, naming a directory the user never typed.
            if [ -d "$1" ]; then
                if [ -n "$REPO_DIR" ]; then
                    echo "current_branches.sh: two directories given: $REPO_DIR and $1" >&2
                    exit 2
                fi
                REPO_DIR="$1"
            else
                # `git check-ref-format` rejects a leading `/` and any `.`/`..` component,
                # so an argument shaped like a path cannot be a branch name — fail as the
                # missing directory it is instead of deferring to a confusing branch error.
                case "$1" in
                    /*|./*|../*|~*)
                        echo "current_branches.sh: not a directory: $1" >&2
                        exit 1
                        ;;
                esac
                if [ -n "$BASE_BRANCH" ]; then
                    echo "current_branches.sh: extra positional argument: $1" >&2
                    exit 2
                fi
                BASE_BRANCH="$1"
            fi
            ;;
    esac
    shift
done

if [ -n "$POLL" ]; then
    case "$POLL" in
        ''|*[!0-9]*)
            echo "current_branches.sh: --poll wants a whole number of seconds, got: $POLL" >&2
            exit 2
            ;;
    esac
    if [ "$POLL" -lt 1 ]; then
        echo "current_branches.sh: --poll interval must be at least 1 second" >&2
        exit 2
    fi
    if [ "$CLEAN" = 1 ] || [ "$UPDATE" = 1 ]; then
        echo "current_branches.sh: --poll cannot be combined with -clean or -update" >&2
        exit 2
    fi
fi

REPO_DIR="${REPO_DIR:-.}"
if [ ! -d "$REPO_DIR" ]; then
    echo "current_branches.sh: not a directory: $REPO_DIR" >&2
    exit 1
fi
cd "$REPO_DIR"

# Report $PWD rather than $REPO_DIR: with the default `.` the literal argument says
# nothing, and an absolute path is what tells you whether you are where you meant to be.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "current_branches.sh: $PWD is not a git repository" >&2
    exit 1
fi

if [ -z "$BASE_BRANCH" ]; then
    if git show-ref --verify --quiet refs/heads/main; then
        BASE_BRANCH=main
    elif git show-ref --verify --quiet refs/heads/master; then
        BASE_BRANCH=master
    else
        echo "current_branches.sh: no <base-branch> given and neither main nor master exists locally" >&2
        exit 1
    fi
elif ! git show-ref --verify --quiet "refs/heads/$BASE_BRANCH"; then
    # It failed the -d test during parsing, so a mistyped path lands here too — say both
    # readings are exhausted rather than only the branch one.
    echo "current_branches.sh: '$BASE_BRANCH' is neither a local branch in $PWD nor a directory" >&2
    exit 1
fi

ORIGINAL=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")

if [ "$UPDATE" = 1 ]; then
    if [ -z "$ORIGINAL" ]; then
        echo "current_branches.sh: -update requires HEAD on a branch (detached HEAD)" >&2
        exit 1
    fi
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "current_branches.sh: -update requires a clean working tree (commit or stash first)" >&2
        exit 1
    fi

    failures=()
    echo "==> -update: pulling origin/$BASE_BRANCH into every local branch"
    while IFS= read -r b; do
        [ -z "$b" ] && continue
        echo "--- $b"
        if ! git checkout "$b"; then
            failures+=("$b: checkout failed")
            continue
        fi
        if ! git pull origin "$BASE_BRANCH"; then
            failures+=("$b: pull origin $BASE_BRANCH failed")
            git merge --abort 2>/dev/null || true
        fi
    done < <(git for-each-ref refs/heads/ --format='%(refname:short)')

    if ! git checkout "$ORIGINAL"; then
        echo "current_branches.sh: failed to restore original branch $ORIGINAL" >&2
    fi

    if [ "${#failures[@]}" -gt 0 ]; then
        echo
        echo "update failures:"
        for f in "${failures[@]}"; do
            echo "  - $f"
        done
    fi
    echo
fi

# is_merged <branch> <base> — returns 0 if branch is fully merged into base,
# covering both regular merges and squash merges.
is_merged() {
    local branch="$1" base="$2"
    # Fast path: regular merge — branch tip is an ancestor of base.
    if git merge-base --is-ancestor "$branch" "$base" 2>/dev/null; then
        return 0
    fi
    # Squash-merge detection: compare the patch the branch introduced
    # (merge_base..branch) against the patch base absorbed (merge_base..base).
    # If the branch patch is empty or already present in base, it's merged.
    # Using patch-id: a squash commit produces the same content diff, so the
    # branch's combined patch will appear in base's patch set.
    #
    # Previous approach (diff base..branch scoped to branch-touched files) gave
    # false positives when both master and the branch independently modified the
    # same files to the same content — the file-scoped diff came up empty even
    # though the branch had real unique commits.
    local merge_base
    merge_base=$(git merge-base "$base" "$branch" 2>/dev/null) || return 1

    # The branch's net change: what did it add on top of the common ancestor?
    local branch_diff
    branch_diff=$(git diff "$merge_base" "$branch" 2>/dev/null)
    [ -z "$branch_diff" ] && return 0  # branch adds nothing — trivially merged

    # Does base contain a commit whose diff matches the branch's net change?
    # Compare patch-ids: generate one for the branch's squashed diff and check
    # if any commit in base (since merge_base) produces the same patch-id.
    local branch_patch_id
    branch_patch_id=$(echo "$branch_diff" | git patch-id --stable 2>/dev/null | awk '{print $1}')
    [ -z "$branch_patch_id" ] && return 1

    local base_patch_ids
    base_patch_ids=$(git log "$merge_base..$base" -p 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')

    if echo "$base_patch_ids" | grep -qF "$branch_patch_id"; then
        return 0
    fi
    return 1
}

if [ "$CLEAN" = 1 ]; then
    echo "==> -clean: deleting branches merged into $BASE_BRANCH"
    while IFS= read -r b; do
        [ -z "$b" ] && continue
        [ "$b" = "$BASE_BRANCH" ] && continue
        if [ "$b" = "$ORIGINAL" ]; then
            echo "skip $b (current branch)"
            continue
        fi
        if is_merged "$b" "$BASE_BRANCH"; then
            if ! git branch -d "$b" 2>/dev/null; then
                # -d refuses unmerged branches; force only when our squash check passed
                git branch -D "$b" || echo "  warning: failed to delete $b" >&2
            fi
        fi
    done < <(git for-each-ref refs/heads/ --format='%(refname:short)')
    echo
fi

# print_table — one rendering of the branch listing. Factored out of the main body so
# --poll can call it repeatedly; everything it reads (HEAD, refs, merged status) is
# re-derived per call rather than captured once, which is the whole point of polling.
print_table() {
    local current date branch merged mark
    current=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")

    printf "%-25s %-50s %-8s %s\n" "LAST_COMMIT" "BRANCH" "MERGED" ""
    while IFS='|' read -r date branch; do
        if [ "$branch" = "$BASE_BRANCH" ]; then
            merged="-"
        elif is_merged "$branch" "$BASE_BRANCH"; then
            merged="yes"
        else
            merged="no"
        fi
        mark=""
        [ "$branch" = "$current" ] && mark="*"
        printf "%-25s %-50s %-8s %s\n" "$date" "$branch" "$merged" "$mark"
    done < <(git for-each-ref refs/heads/ \
        --sort=committerdate \
        --format='%(committerdate:iso-strict)|%(refname:short)')
}

if [ -z "$POLL" ]; then
    print_table
    exit 0
fi

# Poll loop. `\033[3J` drops the scrollback too — without it every redraw leaves a
# stale copy of the table above the visible one, which is exactly the confusion this
# mode is meant to remove. Skipped when stdout isn't a terminal so a redirected run
# stays greppable instead of accumulating escape sequences.
while :; do
    if [ -t 1 ]; then
        printf '\033[H\033[2J\033[3J'
    fi
    printf '==> %s | base=%s | %s | every %ss (Ctrl-C to stop)\n\n' \
        "$(git rev-parse --show-toplevel)" \
        "$BASE_BRANCH" \
        "$(date '+%H:%M:%S')" \
        "$POLL"
    print_table
    [ -t 1 ] || echo
    sleep "$POLL"
done
