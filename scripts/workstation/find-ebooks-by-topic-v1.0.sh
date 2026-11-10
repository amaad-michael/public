#!/usr/bin/env bash
# find-ebooks-by-topic v1.0
#
# WHAT IT DOES
#   Searches your Humble Bundle library for ebook files whose NAMES match
#   a topic you choose, and copies the distinct matches into one folder
#   per topic on the Desktop: ~/Desktop/<Topic>-Books. The originals in
#   the library are never touched; this script only reads them and
#   copies. One run can handle several topics, each getting its own
#   folder.
#
# HOW TO CHOOSE TOPICS
#   Pass topics as arguments, one word (or one quoted phrase) each:
#       ./find-ebooks-by-topic-v1.0.sh terraform
#       ./find-ebooks-by-topic-v1.0.sh terraform python docker
#       ./find-ebooks-by-topic-v1.0.sh "machine learning" rust
#   Or run it with no arguments and it will ask:
#       ./find-ebooks-by-topic-v1.0.sh
#       Topics (separate with spaces or commas): terraform, python
#
# MATCHING RULES
#   Filename matching only (book titles), case-insensitive, for PDF,
#   EPUB, MOBI, and AZW3 files. The same file appearing in several
#   bundles is copied once (same name and same size counts as the same
#   book). A different book with the same filename gets a -2 suffix
#   instead of overwriting. Files already copied are skipped on re-runs,
#   so the script is safe to run again.
#
# NAMING RULE
#   All spaces in the output become hyphens: the folder is
#   <Topic>-Books with the topic's own spaces hyphenated too, and
#   copied filenames have their spaces replaced with hyphens.
#
# PLAN MODE
#   Add --plan anywhere to preview without copying anything:
#       ./find-ebooks-by-topic-v1.0.sh --plan terraform python
#
# OVERRIDES (for testing)
#   LIBRARY=/path DESTDIR=/path ./find-ebooks-by-topic-v1.0.sh topic

set -u

Library="${LIBRARY:-$HOME/Downloads/HumbleBundle}"
DestRoot="${DESTDIR:-$HOME/Desktop}"
Plan=0

hyphenate() { printf '%s' "$1" | tr ' ' '-'; }
titlecase() { printf '%s' "$1" | sed 's/^./\U&/'; }

# process_topic <topic>: search the library for one topic and copy the
# distinct matches into its Desktop folder. Sets globals Copied,
# Skipped, Distinct for the summary.
process_topic() {
  local Topic="$1"
  local DestFolder MatchCount
  DestFolder="$DestRoot/$(hyphenate "$(titlecase "$Topic")")-Books"
  Copied=0; Skipped=0; Distinct=0

  echo "Topic: $Topic"
  echo "Destination folder: $DestFolder"
  if [ "$Plan" -eq 1 ]; then
    echo "Mode: PLAN (nothing will be copied)"
  fi
  echo

  local Matches
  Matches="$(mktemp)"
  find "$Library" -type f \( -iname "*$Topic*.pdf" -o -iname "*$Topic*.epub" \
    -o -iname "*$Topic*.mobi" -o -iname "*$Topic*.azw3" \) -print0 \
    | sort -z > "$Matches"

  MatchCount="$(tr -cd '\0' < "$Matches" | wc -c)"
  echo "Files matching '$Topic' in the library: $MatchCount"
  if [ "$MatchCount" -eq 0 ]; then
    echo "Nothing to do for this topic."
    rm -f "$Matches"
    return 0
  fi

  if [ "$Plan" -eq 0 ]; then
    mkdir -p "$DestFolder"
  fi

  local SeenFile Src Base Size Key Dest Target Ext Stem N
  SeenFile="$(mktemp)"
  : > "$SeenFile"
  while IFS= read -r -d '' Src; do
    Base="$(basename -- "$Src")"
    Size="$(stat -c %s -- "$Src")"
    Key="$Base|$Size"
    if grep -qxF -- "$Key" "$SeenFile"; then
      continue
    fi
    printf '%s\n' "$Key" >> "$SeenFile"
    Distinct=$((Distinct + 1))

    Dest="$(hyphenate "$Base")"
    Target="$DestFolder/$Dest"
    if [ -e "$Target" ] && [ "$(stat -c %s -- "$Target")" != "$Size" ]; then
      Ext="${Dest##*.}"
      Stem="${Dest%.*}"
      N=2
      while [ -e "$DestFolder/$Stem-$N.$Ext" ] \
        && [ "$(stat -c %s -- "$DestFolder/$Stem-$N.$Ext")" != "$Size" ]; do
        N=$((N + 1))
      done
      Target="$DestFolder/$Stem-$N.$Ext"
    fi

    if [ -e "$Target" ]; then
      echo "  skip (already copied): $(basename -- "$Target")"
      Skipped=$((Skipped + 1))
    elif [ "$Plan" -eq 1 ]; then
      echo "  would copy: $Base"
      Copied=$((Copied + 1))
    else
      cp -- "$Src" "$Target"
      echo "  copied: $(basename -- "$Target")"
      Copied=$((Copied + 1))
    fi
  done < "$Matches"
  rm -f "$Matches" "$SeenFile"
}

# ---- collect topics ----
Topics=()
for Arg in "$@"; do
  case "$Arg" in
    --plan) Plan=1 ;;
    *) Topics+=("$Arg") ;;
  esac
done

if [ "${#Topics[@]}" -eq 0 ]; then
  if [ -t 0 ]; then
    printf 'Topics (separate with spaces or commas): '
  fi
  IFS= read -r Line || Line=""
  # Split the line on commas and whitespace into the Topics array.
  Line="${Line//,/ }"
  # shellcheck disable=SC2206
  Topics=( $Line )
fi

if [ "${#Topics[@]}" -eq 0 ]; then
  echo "No topics given. Pass topics as arguments, for example:" >&2
  echo "  $0 terraform python" >&2
  exit 2
fi

# ---- validate the library ----
if [ ! -d "$Library" ]; then
  echo "Library folder not found: $Library" >&2
  exit 1
fi

echo "Find Ebooks by Topic v1.0"
echo "Library: $Library"
echo "Topics: ${Topics[*]}"
echo

GrandCopied=0; GrandSkipped=0; GrandDistinct=0
for Topic in "${Topics[@]}"; do
  process_topic "$Topic"
  GrandCopied=$((GrandCopied + Copied))
  GrandSkipped=$((GrandSkipped + Skipped))
  GrandDistinct=$((GrandDistinct + Distinct))
  echo
done

echo "Summary"
echo "  Topics processed: ${#Topics[@]}"
echo "  Distinct books found: $GrandDistinct"
if [ "$Plan" -eq 1 ]; then
  echo "  Would copy: $GrandCopied"
  echo "  Nothing was copied (plan mode). Run again without --plan to copy."
else
  echo "  Copied: $GrandCopied"
  echo "  Skipped (already copied earlier): $GrandSkipped"
  echo "  Originals untouched: $Library"
fi
