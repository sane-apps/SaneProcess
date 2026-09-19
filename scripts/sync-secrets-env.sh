#!/bin/bash
# Merge secret env files between Air and Mini by key name.
# Adds keys missing on either side; never overwrites an existing value.
# Same name + different value = conflict: reported, both sides keep theirs.
# Prints key NAMES and counts only — never values.
set -u
AIR_ENV="$HOME/.config/nv/env"
MINI_ENV_TMP="$(mktemp)"
BACKUP_SUFFIX=".bak-$(date +%Y%m%d-%H%M%S)"
conflicts=0
added_air=0
added_mini=0

scp -q "mini:.config/nv/env" "$MINI_ENV_TMP" || { echo "FAIL: cannot fetch Mini env"; exit 1; }
cp "$AIR_ENV" "$AIR_ENV$BACKUP_SUFFIX"
ssh mini "cp ~/.config/nv/env ~/.config/nv/env$BACKUP_SUFFIX"

key_of() { echo "$1" | sed -n 's/^export \([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'; }
val_of() { echo "$1" | sed -n 's/^export [A-Za-z_][A-Za-z0-9_]*=\(.*\)/\1/p'; }

while IFS= read -r line; do
  name="$(key_of "$line")"
  [ -z "$name" ] && continue
  air_line="$(grep "^export ${name}=" "$AIR_ENV" | tail -n 1)"
  if [ -z "$air_line" ]; then
    printf '%s\n' "$line" >> "$AIR_ENV"
    added_air=$((added_air + 1))
  elif [ "$(val_of "$air_line")" != "$(val_of "$line")" ]; then
    echo "CONFLICT: $name differs on Air vs Mini — keeping both, resolve by hand"
    conflicts=$((conflicts + 1))
  fi
done < "$MINI_ENV_TMP"

while IFS= read -r line; do
  name="$(key_of "$line")"
  [ -z "$name" ] && continue
  if ! grep -q "^export ${name}=" "$MINI_ENV_TMP"; then
    printf '%s\n' "$line" >> "$MINI_ENV_TMP"
    added_mini=$((added_mini + 1))
  fi
done < "$AIR_ENV"

chmod 600 "$AIR_ENV"
scp -q "$MINI_ENV_TMP" "mini:.config/nv/env"
ssh mini 'chmod 600 ~/.config/nv/env'
rm -f "$MINI_ENV_TMP"
echo "added_to_air=$added_air added_to_mini=$added_mini conflicts=$conflicts"
