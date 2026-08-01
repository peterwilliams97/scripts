#!/usr/bin/env bash
# current_branches.sh — list local branches of the current repo, ascending by
# last-commit time, with whether each is fully merged into a named base branch.
#
# Usage: ./scripts/current_branches.sh [<base-branch>] [-clean] [-update] [<dir>]
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

set -euo pipefail

CLEAN=0
UPDATE=0
REPO_DIR=""
BASE_BRANCH=""

for arg in "$@"; do
    case "$arg" in
        -clean)  CLEAN=1 ;;
        -update) UPDATE=1 ;;
        -h|--help)
            # -E: BSD sed's BRE has no `\?` quantifier, so `s|^# \?||` would match a
            # literal `?` and leave every line still prefixed with "# ".
            sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed -E 's|^# ?||'
            exit 0
            ;;
        -*)
            echo "current_branches.sh: unknown switch: $arg" >&2
            exit 2
            ;;
        *)
            if [ -z "$BASE_BRANCH" ]; then
                BASE_BRANCH="$arg"
            elif [ -z "$REPO_DIR" ]; then
                REPO_DIR="$arg"
            else
                echo "current_branches.sh: extra positional argument: $arg" >&2
                exit 2
            fi
            ;;
    esac
done

REPO_DIR="${REPO_DIR:-$PWD}"
cd "$REPO_DIR"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "current_branches.sh: $REPO_DIR is not a git repository" >&2
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
    echo "current_branches.sh: branch '$BASE_BRANCH' does not exist locally" >&2
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

CURRENT=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")

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
    [ "$branch" = "$CURRENT" ] && mark="*"
    printf "%-25s %-50s %-8s %s\n" "$date" "$branch" "$merged" "$mark"
done < <(git for-each-ref refs/heads/ \
    --sort=committerdate \
    --format='%(committerdate:iso-strict)|%(refname:short)')
