#!/usr/bin/env bash
set -euo pipefail

# Looker Custom Visualizations Parity & Manifest Fallback Script
# Validates custom visualizations between Stage (source) and Prod (target).
# If a visualization is missing from Prod, checks manifest.lkml for pending deployment.

clean_host() { sed -E 's|^https?://||; s|/.*||; s|:[0-9]+$||' <<<"${1:-}"; }

fetch_vizs() {
  (if [ -f "$1" ]; then cat "$1"; else
    local h tok
    h=$(clean_host "$1")
    tok=$(jq -r --arg h "$h" '.[$h].default.token // empty' "$HOME/.looker_auth" 2>/dev/null || true)
    [ -n "$tok" ] && curl -s -H "Authorization: Bearer $tok" "https://$h:${LOOKER_PORT:-443}/api/4.0/vis_manifest" 2>/dev/null || echo "[]"
  fi) | jq -S 'if type == "array" then map({id: (.id // .name // ""), label: (.label // ""), uri: (.main // .url // .file // "")} | select(.id != "")) | sort_by(.id) else [] end'
}

if [ "${1:-}" = "--self-test" ]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  printf 'project_name: "test"\n# visualization: { id: "ignored" }\nvisualization: {\n  id: "viz_m"\n  label: "Viz M"\n  file: "visualizations/m.js"\n}\n' > "$TMP/manifest.lkml"
  printf '[{"id":"viz_a","label":"Viz A","uri":"https://cdn/a.js"},{"id":"viz_m","label":"Viz M","uri":"visualizations/m.js"}]' > "$TMP/stage.json"
  printf '[{"id":"viz_a","label":"Viz A","uri":"https://cdn/a.js"}]' > "$TMP/prod.json"
  printf '[{"id":"viz_a","label":"Viz A","uri":"https://cdn/a.js"},{"id":"viz_drift","label":"Drift","uri":"d.js"}]' > "$TMP/stage_drift.json"
  printf '[{"id":"viz_a","label":"Viz A (Different)","uri":"https://cdn/diff.js"}]' > "$TMP/prod_diff.json"

  # Case 1: Stage has viz_m missing in Prod, but manifest covers it -> pass
  LOOKML_DIR="$TMP" STATUS_FILE="$TMP/pass_manifest.json" "$0" "$TMP/prod.json" "$TMP/stage.json" >/dev/null
  jq -e '.status == "pass" and (.pending_deploy_via_manifest == ["viz_m"]) and (.missing_in_prod == [])' "$TMP/pass_manifest.json" >/dev/null

  # Case 2: In-sync -> pass
  LOOKML_DIR="$TMP" STATUS_FILE="$TMP/pass_sync.json" "$0" "$TMP/prod.json" "$TMP/prod.json" >/dev/null
  jq -e '.status == "pass" and (.in_sync == ["viz_a"]) and (.missing_in_prod == [])' "$TMP/pass_sync.json" >/dev/null

  # Case 3: Stage has viz_drift not in Prod and not in manifest -> fail
  ! LOOKML_DIR="$TMP" STATUS_FILE="$TMP/fail_drift.json" "$0" "$TMP/prod.json" "$TMP/stage_drift.json" >/dev/null 2>&1
  jq -e '.status == "fail" and (.missing_in_prod == ["viz_drift"])' "$TMP/fail_drift.json" >/dev/null

  # Case 4: Definition mismatch -> fail
  ! LOOKML_DIR="$TMP" STATUS_FILE="$TMP/fail_diff.json" "$0" "$TMP/prod_diff.json" "$TMP/stage.json" >/dev/null 2>&1
  jq -e '.status == "fail" and (.definition_mismatches == ["viz_a"])' "$TMP/fail_diff.json" >/dev/null

  echo "Self-test passed."
  exit 0
fi

TARGET_INPUT="${1:-${LOOKER_PROD_BASE_URL:-${LOOKER_TARGET_BASE_URL:?Target host required}}}"
SOURCE_INPUT="${2:-${LOOKER_STAGE_BASE_URL:-${LOOKER_SOURCE_BASE_URL:?Source host required}}}"
STATUS_FILE="${STATUS_FILE:-custom_visualizations_status.json}"

# ponytail: awk block parser over manifest.lkml; upgrade to full LookML AST parser if multi-file includes or nested manifests are introduced
MANIFEST_VIZS=$( { find "${LOOKML_DIR:-.}" -name "manifest.lkml" -exec awk '
  /^[[:space:]]*#.*visualization:/ { next }
  /visualization:[[:space:]]*\{/ { in_viz=1; id=""; label=""; uri=""; next }
  in_viz && /^[[:space:]]*id:[[:space:]]*/ { match($0, /id:[[:space:]]*["'\''"]?([^"'\''[:space:]]+)/, m); id=m[1] }
  in_viz && /^[[:space:]]*label:[[:space:]]*/ { match($0, /label:[[:space:]]*["'\''"]?([^"'\''\n]+)["'\''"]?/, m); label=m[1]; gsub(/["'\''[:space:]]*$/, "", label) }
  in_viz && /^[[:space:]]*(url|file):[[:space:]]*/ { match($0, /(url|file):[[:space:]]*["'\''"]?([^"'\''[:space:]]+)/, m); uri=m[2] }
  in_viz && /^[[:space:]]*\}/ { if (id != "") printf "{\"id\":\"%s\",\"label\":\"%s\",\"uri\":\"%s\"}\n", id, label, uri; in_viz=0 }
' {} + 2>/dev/null || true; } | jq -s 'sort_by(.id)')

TARGET_VIZS=$(fetch_vizs "$TARGET_INPUT")
SOURCE_VIZS=$(fetch_vizs "$SOURCE_INPUT")

jq -n \
  --arg target "$(clean_host "$TARGET_INPUT")" \
  --arg source "$(clean_host "$SOURCE_INPUT")" \
  --argjson stage "$SOURCE_VIZS" \
  --argjson prod "$TARGET_VIZS" \
  --argjson manifest "$MANIFEST_VIZS" '
  ($stage | map(.id)) as $s_ids |
  ($prod | map(.id)) as $p_ids |
  ($manifest | map(.id)) as $m_ids |
  ($s_ids - $p_ids - $m_ids) as $missing_in_prod |
  ($m_ids - $p_ids) as $pending_deploy |
  ($s_ids - ($s_ids - $p_ids)) as $in_sync |
  [$stage[] as $s | $prod[] | select(.id == $s.id and (.uri != $s.uri or (.label != "" and $s.label != "" and .label != $s.label))) | .id] as $diffs |
  {
    status: (if ($missing_in_prod | length) == 0 and ($diffs | length) == 0 then "pass" else "fail" end),
    target_host: $target,
    source_host: $source,
    in_sync_count: ($in_sync | length),
    in_sync: $in_sync,
    manifest_visualizations: $m_ids,
    pending_deploy_via_manifest: $pending_deploy,
    missing_in_prod: $missing_in_prod,
    definition_mismatches: $diffs
  }' | tee "$STATUS_FILE"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '### Custom Visualizations Diagnostics (`%s`)\n```json\n%s\n```\n' "$STATUS_FILE" "$(cat "$STATUS_FILE")" >> "$GITHUB_STEP_SUMMARY"; fi
if ! jq -e '.status == "pass"' "$STATUS_FILE" >/dev/null; then
  echo "Custom Visualizations parity drift detected between Stage and Prod!" >&2
  diff -u <(printf '%s\n' "$SOURCE_VIZS") <(printf '%s\n' "$TARGET_VIZS") || true
  exit 1
fi
