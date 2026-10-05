#!/usr/bin/env bash
set -euo pipefail

# Looker CLI User Attribute Parity & LookML Diagnostic Script

clean_host() { sed -E 's|^https?://||; s|/.*||; s|:[0-9]+$||' <<<"${1:-}"; }

fetch_attrs() {
  (if [ -f "$1" ]; then cat "$1"; else looker-cli api userattribute all_user_attributes \
    --token-file --host "$(clean_host "$1")" --port "${LOOKER_PORT:-443}"; fi) \
    | jq -S 'map({name, label, type, default_value, is_system, value_is_hidden, user_can_view, user_can_edit, hidden_value_domain_whitelist}) | sort_by(.name)'
}

if [ "${1:-}" = "--self-test" ]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  printf 'access_grant: g { user_attribute: dept }\n# user_attribute: ignored\nsql: {{ _user_attributes["region"] }} ;;\n' > "$TMP/test.view.lkml"
  printf '[{"id":1,"name":"dept","label":"Dept","type":"string"},{"id":2,"name":"region","label":"Region","type":"string"}]' > "$TMP/stage.json"
  printf '[{"id":9,"name":"dept","label":"Dept","type":"string"}]' > "$TMP/prod.json"
  LOOKML_DIR="$TMP" STATUS_FILE="$TMP/single.json" "$0" "$TMP/stage.json" >/dev/null
  jq -e '.status == "pass" and (.lookml_user_attributes == ["dept","region"]) and (.parity.checked == false)' "$TMP/single.json" >/dev/null
  LOOKML_DIR="$TMP" STATUS_FILE="$TMP/pass.json" "$0" "$TMP/stage.json" "$TMP/stage.json" >/dev/null
  jq -e '.status == "pass" and (.lookml_user_attributes == ["dept","region"]) and .parity.in_sync' "$TMP/pass.json" >/dev/null
  ! LOOKML_DIR="$TMP" STATUS_FILE="$TMP/fail.json" "$0" "$TMP/prod.json" "$TMP/stage.json" >/dev/null 2>&1
  jq -e '.status == "fail" and (.missing_in_target == ["region"]) and (.parity.only_in_source == ["region"])' "$TMP/fail.json" >/dev/null
  echo "Self-test passed."
  exit 0
fi

TARGET_INPUT="${1:-${LOOKER_TARGET_BASE_URL:?Target host required}}"
SOURCE_INPUT="${2:-${LOOKER_SOURCE_BASE_URL:-}}"
STATUS_FILE="${STATUS_FILE:-user_attributes_status.json}"

# ponytail: regex scan over .lkml/.lookml files; upgrade to full LookML AST parser if multiline block comments or dynamic attribute names are needed
LOOKML_ATTRS=$((find "${LOOKML_DIR:-.}" \( -name '*.lkml' -o -name '*.lookml' \) -exec sed -E 's/^[[:space:]]*#.*//; s/;;[[:space:]]*#.*//' {} + 2>/dev/null \
  | grep -oE "(user_attribute:[[:space:]]*['\"]?[a-zA-Z0-9_]+|_user_attributes\[[[:space:]]*['\"][a-zA-Z0-9_]+)" \
  | sed -E "s/.*['\":[:space:]]([a-zA-Z0-9_]+)$/\1/" | sort -u || true) | jq -R 'select(length > 0)' | jq -s '.')

TARGET_ATTRS=$(fetch_attrs "$TARGET_INPUT")
SOURCE_ATTRS="null"
if [ -n "$SOURCE_INPUT" ]; then SOURCE_ATTRS=$(fetch_attrs "$SOURCE_INPUT"); fi

jq -n \
  --arg target "$(clean_host "$TARGET_INPUT")" \
  --arg source "$(clean_host "$SOURCE_INPUT")" \
  --argjson lookml "$LOOKML_ATTRS" \
  --argjson target_attrs "$TARGET_ATTRS" \
  --argjson source_attrs "$SOURCE_ATTRS" '
  ($target_attrs | map(.name)) as $t_names |
  (if $source_attrs != null then ($source_attrs | map(.name)) else null end) as $s_names |
  ($lookml - $t_names) as $missing_target |
  (if $s_names != null then ($lookml - $s_names) else [] end) as $missing_source |
  (if $source_attrs != null then {
    checked: true,
    in_sync: ($source_attrs == $target_attrs),
    only_in_source: ($s_names - $t_names),
    only_in_target: ($t_names - $s_names),
    definition_mismatches: [$source_attrs[] as $s | $target_attrs[] | select(.name == $s.name and . != $s) | .name]
  } else {checked: false, in_sync: true, only_in_source: [], only_in_target: [], definition_mismatches: []} end) as $parity |
  {
    status: (if ($missing_target | length) == 0 and ($missing_source | length) == 0 and $parity.in_sync then "pass" else "fail" end),
    target_host: $target,
    source_host: (if $source != "" then $source else null end),
    lookml_user_attributes: $lookml,
    target_user_attribute_count: ($t_names | length),
    missing_in_target: $missing_target,
    missing_in_source: $missing_source,
    parity: $parity
  }' | tee "$STATUS_FILE"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '### User Attribute Diagnostics (`%s`)\n```json\n%s\n```\n' "$STATUS_FILE" "$(cat "$STATUS_FILE")" >> "$GITHUB_STEP_SUMMARY"; fi
if [ "$SOURCE_ATTRS" != "null" ] && ! jq -e '.parity.in_sync' "$STATUS_FILE" >/dev/null; then diff -u <(echo "$SOURCE_ATTRS") <(echo "$TARGET_ATTRS") || true; fi
jq -e '.status == "pass"' "$STATUS_FILE" >/dev/null
