#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <whole-device-watts>" >&2
  exit 2
fi

WATTS="$1"
if ! awk -v watts="$WATTS" \
  'BEGIN { exit !(watts ~ /^[0-9]+([.][0-9]+)?$/ && watts >= 0 && watts <= 100000) }'
then
  echo "Watts must be a number from 0 through 100000." >&2
  exit 2
fi

INPUT_DIRECTORY="$HOME/Library/Application Support/WattBar"
INPUT_PATH="$INPUT_DIRECTORY/external-power-watts.txt"
mkdir -p "$INPUT_DIRECTORY"

TEMPORARY_PATH="$(mktemp "$INPUT_DIRECTORY/.external-power-watts.XXXXXX")"
trap 'rm -f "$TEMPORARY_PATH"' EXIT
LC_ALL=C printf '%s\n' "$WATTS" > "$TEMPORARY_PATH"
mv -f "$TEMPORARY_PATH" "$INPUT_PATH"
trap - EXIT

echo "Updated Watt Bar external whole-device power: $WATTS W"
