#!/bin/sh
# recent-files.sh — newest n files under root, printed oldest-first of that set, so the
# most recently written file is the last line rather than something you scroll back to.
#
# Usage: recent-files.sh [-a] [--poll <sec>] [root] [n]
#
# -a           include dotfiles/dot-dirs (default: prune anything under a .component)
# --poll <sec> reprint every <sec> seconds until Ctrl-C, for watching a directory being
#              written to by another process — a Claude Code session, a build, a sync.
#              The tree is re-walked each tick, so new files appear and the ordering
#              re-sorts. On a terminal the screen and scrollback are cleared before each
#              redraw; when redirected to a file or pipe, iterations are appended with a
#              blank line between them.
#
# Unknown switches are rejected rather than silently treated as `root` — passing one
# through used to surface as a bare `find: illegal option` with no mention of this script.

show_hidden=0
poll=""
root=""
n=""

usage() {
    echo "usage: recent-files.sh [-a] [--poll <sec>] [root] [n]" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        -a) show_hidden=1 ;;
        -poll|--poll)
            if [ $# -lt 2 ]; then
                echo "recent-files.sh: $1 requires a seconds argument" >&2
                exit 2
            fi
            poll="$2"
            shift
            ;;
        -poll=*|--poll=*) poll="${1#*=}" ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "recent-files.sh: unknown switch: $1" >&2
            usage
            exit 2
            ;;
        *)
            if [ -z "$root" ]; then
                root="$1"
            elif [ -z "$n" ]; then
                n="$1"
            else
                echo "recent-files.sh: extra positional argument: $1" >&2
                exit 2
            fi
            ;;
    esac
    shift
done

root="${root:-.}"
n="${n:-10}"

if [ ! -d "$root" ]; then
    echo "recent-files.sh: not a directory: $root" >&2
    exit 1
fi

case "$n" in
    ''|*[!0-9]*)
        echo "recent-files.sh: n must be a whole number, got: $n" >&2
        exit 2
        ;;
esac

if [ -n "$poll" ]; then
    case "$poll" in
        ''|*[!0-9]*)
            echo "recent-files.sh: --poll wants a whole number of seconds, got: $poll" >&2
            exit 2
            ;;
    esac
    if [ "$poll" -lt 1 ]; then
        echo "recent-files.sh: --poll interval must be at least 1 second" >&2
        exit 2
    fi
fi

# list_recent — one rendering of the listing. Factored out so --poll can call it
# repeatedly; the find walk is redone per call, which is the point of polling.
list_recent() {
    if [ "$show_hidden" -eq 1 ]; then
        find "$root" -type f -exec stat -f '%m %N' {} +
    else
        find "$root" -name '.*' ! -name '.' -prune -o -type f -exec stat -f '%m %N' {} +
    fi \
      | sort -n \
      | tail -n "$n" \
      | while read -r ts path; do
          printf '%s %s\n' "$(date -r "$ts" '+%Y-%m-%d %H:%M:%S')" "$path"
        done
}

if [ -z "$poll" ]; then
    list_recent
    exit 0
fi

# Poll loop. `\033[3J` drops the scrollback too — without it every redraw leaves a stale
# copy above the visible one. Skipped when stdout isn't a terminal so a redirected run
# stays greppable instead of accumulating escape sequences.
while :; do
    if [ -t 1 ]; then
        printf '\033[H\033[2J\033[3J'
    fi
    printf '==> %s | newest %s | %s | every %ss (Ctrl-C to stop)\n\n' \
        "$root" "$n" "$(date '+%H:%M:%S')" "$poll"
    list_recent
    [ -t 1 ] || echo
    sleep "$poll"
done
