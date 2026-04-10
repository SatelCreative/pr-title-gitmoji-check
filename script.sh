#!/bin/bash

set -uo pipefail

CONFIG_PATH="${GITHUB_ACTION_PATH}/pr-title-checker-config.json"
EVENT_PATH="${GITHUB_EVENT_PATH}"
PASS_ON_ERROR="${INPUT_PASS_ON_OCTOKIT_ERROR:-false}"

# Verify GitHub token is available
if [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "API Error - no GitHub token provided"
  if [ "$PASS_ON_ERROR" = "true" ]; then
    echo "Passing CI regardless"
    exit 0
  else
    echo "::error::Failing CI test"
    exit 1
  fi
fi

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
  if gh pr edit "$PR_NUMBER" --add-label "$1" -R "$GITHUB_REPOSITORY"; then
    echo "Added label ($1) to PR"
  else
    echo "Failed to add label ($1) to PR"
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
  if gh pr edit "$PR_NUMBER" --remove-label "$1" -R "$GITHUB_REPOSITORY"; then
    echo "Removed label"
  else
    echo "Failed to remove label ($1) from PR"
  fi
}

ensure_label_exists() {
  echo "Creating label ($1)..."
  if gh label create "$1" --color "$2" -R "$GITHUB_REPOSITORY" 2>/dev/null; then
    echo "Created label ($1)"
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
