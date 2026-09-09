#!/usr/bin/env bash
set -euo pipefail

# Source-to-Target agent migration tracks Source->Target Agent and Golden Query ID mappings via Looker Artifact API, enabling clean description-free upserts and golden query creation from get_agent.

SOURCE_HOST="${LOOKER_SOURCE_BASE_URL#*://}"
SOURCE_HOST="${SOURCE_HOST%%/*}"
SOURCE_HOST="${SOURCE_HOST%%:*}"
TARGET_HOST="${LOOKER_TARGET_BASE_URL#*://}"
TARGET_HOST="${TARGET_HOST%%/*}"
TARGET_HOST="${TARGET_HOST%%:*}"
LOOKER_PORT="${LOOKER_PORT:-443}"
ARTIFACT_NAMESPACE="ca_agent_migration"
ARTIFACT_AGENT_KEY="agent_mapping"
ARTIFACT_QUERY_KEY="golden_query_mapping"

CONFIG_FILE="${1:-}"
WHITELIST=()

if [ -n "$CONFIG_FILE" ]; then
  if [ -f "$CONFIG_FILE" ]; then
    readarray -t WHITELIST < <(grep -E '^[[:space:]]*-' "$CONFIG_FILE" | sed 's/^[[:space:]]*-[[:space:]]*//; s/"//g; s/'\''//g')
    echo "Loaded ${#WHITELIST[@]} whitelisted agent(s) from $CONFIG_FILE."
  else
    echo "Notice: Config file '$CONFIG_FILE' not found. Migrating all agents."
  fi
fi

if [ -z "$SOURCE_HOST" ] || [ -z "$TARGET_HOST" ]; then
  echo "Error: LOOKER_SOURCE_BASE_URL and LOOKER_TARGET_BASE_URL must be set." >&2
  exit 1
fi

echo "Starting Conversational Analytics Agents Migration (Source > Target)..."

# 1. Fetch Source and Target agents
SOURCE_AGENTS_RAW=$(looker-cli api conversationalanalytics search_agents --token-file --host "$SOURCE_HOST" --port "$LOOKER_PORT")
TARGET_AGENTS_RAW=$(looker-cli api conversationalanalytics search_agents --token-file --host "$TARGET_HOST" --port "$LOOKER_PORT")

if ! echo "$SOURCE_AGENTS_RAW" | jq . >/dev/null 2>&1 || ! echo "$TARGET_AGENTS_RAW" | jq . >/dev/null 2>&1; then
  echo "Error: Failed to fetch agents from Source or Target, or received invalid JSON." >&2
  exit 1
fi

# 2. Fetch existing Source->Target ID mapping artifacts from Target
load_artifact() {
  local resp
  resp=$(looker-cli api artifact artifact "$ARTIFACT_NAMESPACE" "$1" --token-file --host "$TARGET_HOST" --port "$LOOKER_PORT" 2>/dev/null || echo "[]")
  echo "$resp" | jq -c '{
    version: (.[0].version // empty),
    map: (.[0].value // "{}" | if type == "string" then (fromjson? // {}) else . end)
  }' 2>/dev/null || echo '{"version":null,"map":{}}'
}

AGENT_ART=$(load_artifact "$ARTIFACT_AGENT_KEY")
AGENT_MAP_VERSION=$(echo "$AGENT_ART" | jq -r '.version // empty')
SOURCE_TO_TARGET_AGENT_MAP=$(echo "$AGENT_ART" | jq -c '.map // {}')
AGENT_MAP_MODIFIED=false

QUERY_ART=$(load_artifact "$ARTIFACT_QUERY_KEY")
QUERY_MAP_VERSION=$(echo "$QUERY_ART" | jq -r '.version // empty')
SOURCE_TO_TARGET_QUERY_MAP=$(echo "$QUERY_ART" | jq -c '.map // {}')
QUERY_MAP_MODIFIED=false

echo "Loaded existing agent and golden query mappings from Target artifact store."

# 3. Iterate over active Source agents and upsert to Target
FAILED_AGENTS=()
MATCHED_AGENTS=()

while IFS= read -r AGENT_SUMMARY; do
  [ -z "$AGENT_SUMMARY" ] && continue
  SOURCE_AGENT_ID=$(echo "$AGENT_SUMMARY" | jq -r '.id // empty')
  AGENT_NAME=$(echo "$AGENT_SUMMARY" | jq -r '.name // empty')
  [ -z "$AGENT_NAME" ] || [ -z "$SOURCE_AGENT_ID" ] && continue

  if [ ${#WHITELIST[@]} -gt 0 ]; then
    MATCH=false
    for ALLOWED in "${WHITELIST[@]}"; do
      if [ "${AGENT_NAME,,}" = "${ALLOWED,,}" ]; then
        MATCH=true
        break
      fi
    done
    if [ "$MATCH" != "true" ]; then
      echo "Skipping agent '$AGENT_NAME' (not in whitelist)."
      continue
    fi
    MATCHED_AGENTS+=("$AGENT_NAME")
  fi

  echo ""
  echo "Processing agent: '$AGENT_NAME' (Source ID: $SOURCE_AGENT_ID)..."

  # Fetch full agent data from Source to access golden_queries array and details
  SOURCE_AGENT_FULL=$(looker-cli api conversationalanalytics get_agent "$SOURCE_AGENT_ID" --token-file --host "$SOURCE_HOST" --port "$LOOKER_PORT" 2>/dev/null || echo "$AGENT_SUMMARY")

  # Resolve each golden query using get_agent data and create_golden_query on Target
  TARGET_GQIDS=()
  GQ_FAILED=false

  while IFS= read -r GQ; do
    [ -z "$GQ" ] && continue
    GQ_ID=$(echo "$GQ" | jq -r '.id // empty')
    [ -z "$GQ_ID" ] && continue

    # Check cache in artifact mapping
    CACHED_TARGET_GQID=$(echo "$SOURCE_TO_TARGET_QUERY_MAP" | jq -r --arg id "$GQ_ID" '.[$id] // empty')
    if [ -n "$CACHED_TARGET_GQID" ]; then
      echo "  Using mapped Target golden query ID $CACHED_TARGET_GQID for Source golden query ID $GQ_ID."
      TARGET_GQIDS+=("$CACHED_TARGET_GQID")
      continue
    fi

    echo "  Creating unmapped golden query on Target (Source golden query ID $GQ_ID)..."

    # Golden query answer URLs require a valid query ID or share URL on the Target instance.
    # Replicate the query definition on Target first to obtain a valid Target answer URL.
    TARGET_ANSWER=$(echo "$GQ" | jq -r '.answer // ""')
    MODEL=$(echo "$GQ" | jq -r '.model // empty')
    EXPLORE=$(echo "$GQ" | jq -r '.explore // empty')

    if [ -n "$MODEL" ] && [ -n "$EXPLORE" ]; then
      QUERY_PAYLOAD=$(echo "$GQ" | jq -c '{
        model: .model,
        view: .explore,
        fields: (.fields // []),
        filters: (.filters // {}),
        pivots: (.pivots // []),
        sorts: (.sorts // []),
        limit: (.limit // null),
        dynamic_fields: (.dynamic_fields // null)
      } | with_entries(select(.value != null))')

      if TARGET_QUERY_RESP=$(echo "$QUERY_PAYLOAD" | looker-cli api query create_query - --token-file --host "$TARGET_HOST" --port "$LOOKER_PORT" 2>/dev/null); then
        RESOLVED_URL=$(echo "$TARGET_QUERY_RESP" | jq -r '.share_url // .expanded_share_url // empty' 2>/dev/null || true)
        [ -n "$RESOLVED_URL" ] && TARGET_ANSWER="$RESOLVED_URL"
      fi
    fi

    GQ_PAYLOAD=$(echo "$GQ" | jq -c --arg ans "$TARGET_ANSWER" '{
      answer: $ans,
      is_active: (if .is_active != null then .is_active else true end),
      questions: (.questions // [])
    }')

    if CREATE_GQ_RESP=$(echo "$GQ_PAYLOAD" | looker-cli api conversationalanalytics create_golden_query - --token-file --host "$TARGET_HOST" --port "$LOOKER_PORT" 2>&1); then
      NEW_TARGET_GQID=$(echo "$CREATE_GQ_RESP" | jq -r '.id // empty' 2>/dev/null || true)
      if [ -n "$NEW_TARGET_GQID" ]; then
        echo "  Created golden query on Target: ID $NEW_TARGET_GQID (from Source golden query ID $GQ_ID)."
        TARGET_GQIDS+=("$NEW_TARGET_GQID")
        SOURCE_TO_TARGET_QUERY_MAP=$(echo "$SOURCE_TO_TARGET_QUERY_MAP" | jq -c --arg s "$GQ_ID" --arg t "$NEW_TARGET_GQID" '.[$s] = ($t | tonumber? // $t)')
        QUERY_MAP_MODIFIED=true
      else
        echo "  Error: Failed to parse created golden query ID on Target for Source golden query ID $GQ_ID: $CREATE_GQ_RESP" >&2
        GQ_FAILED=true
        break
      fi
    else
      echo "  Error: Failed to create golden query on Target for Source golden query ID $GQ_ID: $CREATE_GQ_RESP" >&2
      GQ_FAILED=true
      break
    fi
  done < <(echo "$SOURCE_AGENT_FULL" | jq -c '.golden_queries[]? // empty')

  if [ "$GQ_FAILED" = "true" ]; then
    echo "Error: Skipping Agent '$AGENT_NAME' due to golden query creation failure." >&2
    FAILED_AGENTS+=("$AGENT_NAME (Source ID: $SOURCE_AGENT_ID - golden query creation failed)")
    continue
  fi

  # Build payload
  TARGET_GQIDS_JSON=$(jq -n '[$ARGS.positional[] | select(length > 0) | tonumber? // .]' --args "${TARGET_GQIDS[@]:-}")
  PAYLOAD=$(echo "$SOURCE_AGENT_FULL" | jq -c --argjson gq "$TARGET_GQIDS_JSON" '({name, description, sources, code_interpreter, category, context, workflow_params} + (if ($gq | length) > 0 then {golden_query_ids: $gq} else {} end)) | with_entries(select(.value != null))')

  # Check if this Source agent was already mapped to a Target agent ID
  MAPPED_TARGET_ID=$(echo "$SOURCE_TO_TARGET_AGENT_MAP" | jq -r --arg id "$SOURCE_AGENT_ID" '.[$id] // empty')
  TARGET_AGENT_EXISTS=""

  if [ -n "$MAPPED_TARGET_ID" ]; then
    TARGET_AGENT_EXISTS=$(echo "$TARGET_AGENTS_RAW" | jq -r --arg id "$MAPPED_TARGET_ID" '.[] | select((.id | tostring) == $id and .deleted != true) | .id' | head -n 1)
  fi

  if [ -n "$TARGET_AGENT_EXISTS" ]; then
    echo "Found mapped Target agent (ID: $MAPPED_TARGET_ID). Updating via PATCH..."
    TARGET_AGENT_FULL=$(looker-cli api conversationalanalytics get_agent "$MAPPED_TARGET_ID" --token-file --host "$TARGET_HOST" --port "$LOOKER_PORT" 2>/dev/null || echo "{}")
    readarray -t EXISTING_TARGET_GQIDS < <(echo "$TARGET_AGENT_FULL" | jq -r '[(.golden_queries[]?.id // empty), (.golden_query_ids[]? // empty)] | unique | .[]' 2>/dev/null || true)

    if UPDATE_OUTPUT=$(echo "$PAYLOAD" | looker-cli api conversationalanalytics update_agent "$MAPPED_TARGET_ID" - --token-file --host "$TARGET_HOST" --port "$LOOKER_PORT" 2>&1); then
      echo "Successfully updated Agent '$AGENT_NAME' on Target (ID: $MAPPED_TARGET_ID)."
      for OLD_GQID in "${EXISTING_TARGET_GQIDS[@]:-}"; do
        [ -z "$OLD_GQID" ] && continue
        if [[ ! " ${TARGET_GQIDS[*]} " =~ [[:space:]]"${OLD_GQID}"[[:space:]] ]]; then
          echo "  Golden query ID $OLD_GQID was removed from Source. Deleting from Target..."
          if looker-cli api conversationalanalytics delete_golden_query "$OLD_GQID" --token-file --host "$TARGET_HOST" --port "$LOOKER_PORT" >/dev/null 2>&1; then
            echo "  Deleted golden query ID $OLD_GQID on Target."
            SOURCE_TO_TARGET_QUERY_MAP=$(echo "$SOURCE_TO_TARGET_QUERY_MAP" | jq -c --arg t "$OLD_GQID" 'with_entries(select((.value | tostring) != $t))')
            QUERY_MAP_MODIFIED=true
          else
            echo "  Warning: Failed to delete removed golden query ID $OLD_GQID on Target." >&2
          fi
        fi
      done
    else
      echo "Error updating Agent '$AGENT_NAME' on Target: $UPDATE_OUTPUT" >&2
      FAILED_AGENTS+=("$AGENT_NAME (Source ID: $SOURCE_AGENT_ID)")
    fi
  else
    echo "No existing Target mapping found for Source ID $SOURCE_AGENT_ID. Creating via POST..."
    if CREATE_OUTPUT=$(echo "$PAYLOAD" | looker-cli api conversationalanalytics create_agent - --token-file --host "$TARGET_HOST" --port "$LOOKER_PORT" 2>&1); then
      NEW_ID=$(echo "$CREATE_OUTPUT" | jq -r '.id // empty' 2>/dev/null || true)
      echo "Successfully created Agent '$AGENT_NAME' on Target (ID: ${NEW_ID:-unknown})."
      if [ -n "$NEW_ID" ]; then
        SOURCE_TO_TARGET_AGENT_MAP=$(echo "$SOURCE_TO_TARGET_AGENT_MAP" | jq -c --arg s "$SOURCE_AGENT_ID" --arg p "$NEW_ID" '.[$s] = $p')
        AGENT_MAP_MODIFIED=true
      fi
    else
      echo "Error creating Agent '$AGENT_NAME' on Target: $CREATE_OUTPUT" >&2
      FAILED_AGENTS+=("$AGENT_NAME (Source ID: $SOURCE_AGENT_ID)")
    fi
  fi
done < <(echo "$SOURCE_AGENTS_RAW" | jq -c '.[] | select(.deleted != true)')

if [ ${#WHITELIST[@]} -gt 0 ]; then
  for ALLOWED in "${WHITELIST[@]}"; do
    if [[ ! " ${MATCHED_AGENTS[*],,} " =~ [[:space:]]"${ALLOWED,,}"[[:space:]] ]]; then
      echo "Notice: Whitelisted agent '$ALLOWED' not found on Source."
    fi
  done
fi

# 4. Save updated Source->Target mappings back to Target Artifact API
# Note: Looker OpenAPI schema defines Artifact.value as type: string; JSON payloads must be stored as serialized strings via --arg.
ARTIFACT_UPDATES=()
[ "$AGENT_MAP_MODIFIED" = "true" ] && ARTIFACT_UPDATES+=("$(jq -c -n --arg k "$ARTIFACT_AGENT_KEY" --arg v "$SOURCE_TO_TARGET_AGENT_MAP" --arg ver "$AGENT_MAP_VERSION" '{key: $k, value: $v, content_type: "application/json"} + (if ($ver | length) > 0 then {version: ($ver | tonumber)} else {} end)')")
[ "$QUERY_MAP_MODIFIED" = "true" ] && ARTIFACT_UPDATES+=("$(jq -c -n --arg k "$ARTIFACT_QUERY_KEY" --arg v "$SOURCE_TO_TARGET_QUERY_MAP" --arg ver "$QUERY_MAP_VERSION" '{key: $k, value: $v, content_type: "application/json"} + (if ($ver | length) > 0 then {version: ($ver | tonumber)} else {} end)')")

if [ ${#ARTIFACT_UPDATES[@]} -gt 0 ]; then
  echo ""
  echo "Saving updated mapping artifact(s) to Target..."
  ARTIFACTS_PAYLOAD=$(printf '%s\n' "${ARTIFACT_UPDATES[@]}" | jq -s '.')
  if ! echo "$ARTIFACTS_PAYLOAD" | looker-cli api artifact update_artifacts "$ARTIFACT_NAMESPACE" - --token-file --host "$TARGET_HOST" --port "$LOOKER_PORT" >/dev/null; then
    echo "Error: Failed to save mapping artifacts to Target. Exiting to prevent duplicate migrations." >&2
    exit 1
  else
    echo "Successfully updated mapping artifact(s) on Target."
  fi
fi

if [ ${#FAILED_AGENTS[@]} -gt 0 ]; then
  echo ""
  echo "Error: Failed to migrate ${#FAILED_AGENTS[@]} agent(s): ${FAILED_AGENTS[*]}" >&2
  exit 1
fi

echo ""
echo "Conversational Analytics Agents migration completed successfully."
