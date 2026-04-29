#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: resolve_download.sh <downloaded filename or search text>" >&2
  exit 64
fi

query="$*"
move_index="${HOME}/Library/Application Support/DownloadsOrganizer/move-index.tsv"

print_match() {
  local path="$1"
  if [[ -e "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  return 1
}

if [[ ! -f "$move_index" ]]; then
  exit 1
fi

while IFS=$'\t' read -r moved_at original_name original_path final_path type_label; do
  [[ "$original_name" == *"$query"* || "$original_path" == *"$query"* || "$final_path" == *"$query"* ]] || continue
  print_match "$final_path" && exit 0
done < <(tail -r "$move_index")

exit 1
