#!/bin/bash

set -uo pipefail

CONFIG_PATH="${GITHUB_ACTION_PATH}/pr-title-checker-config.json"
EVENT_PATH="${GITHUB_EVENT_PATH}"
PASS_ON_ERROR="${INPUT_PASS_ON_OCTOKIT_ERROR:-false}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
API_BASE="${GITHUB_API_URL:-https://api.github.com}"

if [ -z "$TOKEN" ]; then
  echo "API Error - no GitHub token provided"
  if [ "$PASS_ON_ERROR" = "true" ]; then
    echo "Passing CI regardless"
    exit 0
  else
    echo "::error::Failing CI test"
    exit 1
  fi
fi

api() {
  local method="$1" endpoint="$2"
  shift 2
  curl -s -X "$method" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@" \
    "${API_BASE}${endpoint}"
}

PR_TITLE=$(jq -r '.pull_request.title' "$EVENT_PATH")
PR_NUMBER=$(jq -r '.pull_request.number' "$EVENT_PATH")

LABEL_NAME=$(jq -r '.LABEL.name // "Gitmoji missing"' "$CONFIG_PATH")
LABEL_COLOR=$(jq -r '.LABEL.color // "eee"' "$CONFIG_PATH")
ALWAYS_PASS_CI=$(jq -r '.CHECKS.alwaysPassCI // false' "$CONFIG_PATH")
SUCCESS_MSG=$(jq -r '.MESSAGES.success // "All OK"' "$CONFIG_PATH")
FAILURE_MSG=$(jq -r '.MESSAGES.failure // "Failing CI test"' "$CONFIG_PATH")
NOTICE_MSG=$(jq -r '.MESSAGES.notice // ""' "$CONFIG_PATH")

add_label() {
  echo "Adding label ($1) to PR..."
  local body
  body=$(jq -n --arg lbl "$1" '{"labels":[$lbl]}')
  local status
  status=$(api POST "/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/labels" \
    -o /dev/null -w "%{http_code}" \
    -d "$body")
  if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
    echo "Added label ($1) to PR - ${status}"
  else
    echo "Failed to add label ($1) to PR - ${status}"
  fi
}

remove_label() {
  local has_label
  has_label=$(jq -r --arg name "$1" \
    '[.pull_request.labels[].name] | map(ascii_downcase) |
     if index($name | ascii_downcase) != null then "true" else "false" end' \
    "$EVENT_PATH")

  if [ "$has_label" != "true" ]; then
    return
  fi

  echo "No formatting necessary. Removing label..."
  local encoded_name
  encoded_name=$(printf '%s' "$1" | jq -sRr @uri)
  local status
  status=$(api DELETE "/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/labels/${encoded_name}" \
    -o /dev/null -w "%{http_code}")
  if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
    echo "Removed label - ${status}"
  else
    echo "Failed to remove label ($1) from PR - ${status}"
  fi
}

ensure_label_exists() {
  echo "Creating label ($1)..."
  local body
  body=$(jq -n --arg name "$1" --arg color "$2" '{"name":$name,"color":$color}')
  local status
  status=$(api POST "/repos/${GITHUB_REPOSITORY}/labels" \
    -o /dev/null -w "%{http_code}" \
    -d "$body")
  if [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
    echo "Created label ($1) - ${status}"
  else
    echo "Label ($1) already created."
  fi
}

title_check_failed() {
  if [ -n "$NOTICE_MSG" ]; then
    echo "::notice::${NOTICE_MSG}"
  fi

  add_label "$LABEL_NAME"

  if [ "$ALWAYS_PASS_CI" = "true" ]; then
    echo "$FAILURE_MSG"
  else
    echo "::error::${FAILURE_MSG}"
    exit 1
  fi
}

# Check for ignore labels
SHOULD_IGNORE=$(jq -r \
  --slurpfile config "$CONFIG_PATH" \
  '($config[0].CHECKS.ignoreLabels // []) as $ignore |
   [.pull_request.labels[].name] as $labels |
   if ($labels | map(. as $l | $ignore | index($l)) | any(. != null))
   then "true" else "false" end' \
  "$EVENT_PATH")

if [ "$SHOULD_IGNORE" = "true" ]; then
  MATCHED_LABEL=$(jq -r \
    --slurpfile config "$CONFIG_PATH" \
    '($config[0].CHECKS.ignoreLabels // []) as $ignore |
     [.pull_request.labels[].name] |
     map(select(. as $l | $ignore | index($l) != null)) | first' \
    "$EVENT_PATH")
  echo "Ignoring Title Check for label - ${MATCHED_LABEL}"
  remove_label "$LABEL_NAME"
  exit 0
fi

# Ensure the failure label exists in the repository
ensure_label_exists "$LABEL_NAME" "$LABEL_COLOR"

# Check title against allowed prefixes
PREFIX_MATCH=$(jq -r \
  --arg title "$PR_TITLE" \
  '.CHECKS.prefixes // [] | map(. as $p | select($title | startswith($p))) |
   if length > 0 then "true" else "false" end' \
  "$CONFIG_PATH")

if [ "$PREFIX_MATCH" = "true" ]; then
  remove_label "$LABEL_NAME"
  echo "$SUCCESS_MSG"
  exit 0
fi

# Check title against optional regexp
REGEXP=$(jq -r '.CHECKS.regexp // ""' "$CONFIG_PATH")
if [ -n "$REGEXP" ]; then
  REGEXP_FLAGS=$(jq -r '.CHECKS.regexpFlags // ""' "$CONFIG_PATH")
  GREP_ARGS=(-E -q)
  if echo "$REGEXP_FLAGS" | grep -q "i"; then
    GREP_ARGS+=(-i)
  fi
  if echo "$PR_TITLE" | grep "${GREP_ARGS[@]}" -- "$REGEXP" 2>/dev/null; then
    remove_label "$LABEL_NAME"
    echo "$SUCCESS_MSG"
    exit 0
  fi
fi

title_check_failed
