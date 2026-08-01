#!/bin/sh
# recent-files [-a] [root] [n] — newest n files under root, oldest-first of that set
# -a: include dotfiles/dot-dirs (default: ignore anything under a .component)

show_hidden=0
if [ "$1" = "-a" ]; then
  show_hidden=1
  shift
fi

root="${1:-.}"
n="${2:-10}"

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
