#!/usr/bin/env bash
set -euo pipefail

# Looker CLI Title-Based Board Migration Script
# Migrates whitelisted Boards, sections, and pinned tiles from Stage to Prod using looker-cli api.

CONFIG_FILE="${1:-config/content_boards_whitelist.yaml}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Notice: Config file $CONFIG_FILE not found. Skipping board migration."
  exit 0
fi

STAGE_HOST=$(echo "${LOOKER_STAGE_BASE_URL:-}" | sed -e 's|^https\?://||' -e 's|/.*$||' -e 's|:[0-9]*$||')
PROD_HOST=$(echo "${LOOKER_PROD_BASE_URL:-}" | sed -e 's|^https\?://||' -e 's|/.*$||' -e 's|:[0-9]*$||')
LOOKER_PORT="${LOOKER_PORT:-443}"

if [ -z "$STAGE_HOST" ] || [ -z "$PROD_HOST" ]; then
  echo "Error: LOOKER_STAGE_BASE_URL and LOOKER_PROD_BASE_URL must be set." >&2
  exit 1
fi

echo "Starting Looker CLI Title-Based Board Migration..."

# Extract whitelisted board names
BOARDS=$(grep -E '^[[:space:]]*-' "$CONFIG_FILE" | sed 's/^[[:space:]]*-[[:space:]]*//; s/"//g; s/'\''//g')

for BOARD_TITLE in $BOARDS; do
  echo ""
  echo "Processing board: '$BOARD_TITLE'..."

  # 1. Search for Board on Stage
  STAGE_BOARD_JSON=$(looker-cli api board search_boards --token-file --host "$STAGE_HOST" --port "$LOOKER_PORT" 2>/dev/null || echo "[]")
  STAGE_BOARD_ID=$(echo "$STAGE_BOARD_JSON" | jq -r --arg t "$BOARD_TITLE" '.[] | select(.title | ascii_downcase == ($t | ascii_downcase)) | .id' | head -n 1)

  if [ -z "$STAGE_BOARD_ID" ] || [ "$STAGE_BOARD_ID" = "null" ]; then
    echo "Notice: Board '$BOARD_TITLE' not found on Stage. Skipping."
    continue
  fi

  echo "Found Stage board ID: $STAGE_BOARD_ID"

  # Fetch full Stage board details (sections and items)
  FULL_STAGE_BOARD=$(looker-cli api board board "$STAGE_BOARD_ID" --token-file --host "$STAGE_HOST" --port "$LOOKER_PORT")
  BOARD_DESC=$(echo "$FULL_STAGE_BOARD" | jq -r '.description // ""')

  # 2. Find or Create Board on Prod
  PROD_BOARD_JSON=$(looker-cli api board search_boards --token-file --host "$PROD_HOST" --port "$LOOKER_PORT" 2>/dev/null || echo "[]")
  PROD_BOARD_ID=$(echo "$PROD_BOARD_JSON" | jq -r --arg t "$BOARD_TITLE" '.[] | select(.title | ascii_downcase == ($t | ascii_downcase)) | .id' | head -n 1)

  if [ -z "$PROD_BOARD_ID" ] || [ "$PROD_BOARD_ID" = "null" ]; then
    echo "Creating Board '$BOARD_TITLE' on Prod..."
    NEW_PROD_BOARD=$(looker-cli api board create_board --token-file --host "$PROD_HOST" --port "$LOOKER_PORT" "{\"title\": \"$BOARD_TITLE\", \"description\": \"$BOARD_DESC\"}")
    PROD_BOARD_ID=$(echo "$NEW_PROD_BOARD" | jq -r '.id')
  fi

  echo "Prod Board ID: $PROD_BOARD_ID"

  # 3. Read Sections from Stage Board
  SECTIONS=$(echo "$FULL_STAGE_BOARD" | jq -c '.board_sections[]?')

  for SEC in $SECTIONS; do
    SEC_TITLE=$(echo "$SEC" | jq -r '.title // "Default Section"')
    SEC_DESC=$(echo "$SEC" | jq -r '.description // ""')
    echo "  Processing section: '$SEC_TITLE'..."

    # Check if section exists on Prod board
    PROD_SECS=$(looker-cli api board all_board_sections "$PROD_BOARD_ID" --token-file --host "$PROD_HOST" --port "$LOOKER_PORT" 2>/dev/null || echo "[]")
    PROD_SEC_ID=$(echo "$PROD_SECS" | jq -r --arg t "$SEC_TITLE" '.[] | select(.title | ascii_downcase == ($t | ascii_downcase)) | .id' | head -n 1)

    if [ -z "$PROD_SEC_ID" ] || [ "$PROD_SEC_ID" = "null" ]; then
      echo "    Creating section '$SEC_TITLE' on Prod..."
      NEW_SEC=$(looker-cli api board create_board_section --token-file --host "$PROD_HOST" --port "$LOOKER_PORT" "{\"board_id\": \"$PROD_BOARD_ID\", \"title\": \"$SEC_TITLE\", \"description\": \"$SEC_DESC\"}")
      PROD_SEC_ID=$(echo "$NEW_SEC" | jq -r '.id')
    fi

    # 4. Migrate Items in this Section
    ITEMS=$(echo "$SEC" | jq -c '.board_items[]?')
    for ITEM in $ITEMS; do
      DASH_ID=$(echo "$ITEM" | jq -r '.dashboard_id // empty')
      LOOK_ID=$(echo "$ITEM" | jq -r '.look_id // empty')

      if [ -n "$DASH_ID" ]; then
        DASH_TITLE=$(looker-cli api dashboard dashboard "$DASH_ID" --token-file --host "$STAGE_HOST" --port "$LOOKER_PORT" | jq -r '.title // empty')
        if [ -n "$DASH_TITLE" ]; then
          # Search for matching dashboard by title on Prod
          PROD_DASH_ID=$(looker-cli api dashboard search_dashboards --token-file --host "$PROD_HOST" --port "$LOOKER_PORT" | jq -r --arg t "$DASH_TITLE" '.[] | select(.title | ascii_downcase == ($t | ascii_downcase)) | .id' | head -n 1)
          if [ -n "$PROD_DASH_ID" ] && [ "$PROD_DASH_ID" != "null" ]; then
            echo "    Pinning Dashboard '$DASH_TITLE' (Prod ID: $PROD_DASH_ID) to section '$SEC_TITLE'..."
            looker-cli api board create_board_item --token-file --host "$PROD_HOST" --port "$LOOKER_PORT" "{\"board_section_id\": \"$PROD_SEC_ID\", \"dashboard_id\": \"$PROD_DASH_ID\"}" >/dev/null 2>&1 || true
          fi
        fi
      elif [ -n "$LOOK_ID" ]; then
        LOOK_TITLE=$(looker-cli api look look "$LOOK_ID" --token-file --host "$STAGE_HOST" --port "$LOOKER_PORT" | jq -r '.title // empty')
        if [ -n "$LOOK_TITLE" ]; then
          PROD_LOOK_ID=$(looker-cli api look search_looks --token-file --host "$PROD_HOST" --port "$LOOKER_PORT" | jq -r --arg t "$LOOK_TITLE" '.[] | select(.title | ascii_downcase == ($t | ascii_downcase)) | .id' | head -n 1)
          if [ -n "$PROD_LOOK_ID" ] && [ "$PROD_LOOK_ID" != "null" ]; then
            echo "    Pinning Look '$LOOK_TITLE' (Prod ID: $PROD_LOOK_ID) to section '$SEC_TITLE'..."
            looker-cli api board create_board_item --token-file --host "$PROD_HOST" --port "$LOOKER_PORT" "{\"board_section_id\": \"$PROD_SEC_ID\", \"look_id\": \"$PROD_LOOK_ID\"}" >/dev/null 2>&1 || true
          fi
        fi
      fi
    done
  done
done

echo "Board migration finished successfully."
