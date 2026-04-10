# pr-title-gitmoji-check

A GitHub Action that checks for [gitmoji](https://gitmoji.dev/) prefixes in PR titles.

## How it works

When a pull request is opened or updated, this action:

1. Reads the PR title and checks it against allowed gitmoji prefixes from `pr-title-checker-config.json`
2. If the title starts with a valid gitmoji (unicode or `:shortcode:`), the check passes
3. If the title doesn't match, a **"Gitmoji missing"** label is added to the PR and the CI check fails
4. If the PR has a label listed in `ignoreLabels`, the check is skipped entirely

## Usage

```yaml
name: PR Title Gitmoji Check
on:
  pull_request:
    types: [opened, edited, labeled, unlabeled, synchronize]

jobs:
  check-title:
    runs-on: ubuntu-latest
    steps:
      - uses: your-org/pr-title-gitmoji-check@main
        with:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| Input                  | Description                                      | Required | Default        |
|------------------------|--------------------------------------------------|----------|----------------|
| `GITHUB_TOKEN`         | GitHub token for API calls                       | No       | `github.token` |
| `pass_on_octokit_error`| Force CI to pass if an API error occurs          | No       | `false`        |

## Configuration

Edit `pr-title-checker-config.json` to customize:

- **`LABEL`** — name and color of the failure label applied to PRs
- **`CHECKS.prefixes`** — allowed gitmoji prefixes (unicode and `:shortcode:` forms)
- **`CHECKS.ignoreLabels`** — PR labels that skip the title check
- **`CHECKS.regexp`** / **`CHECKS.regexpFlags`** — optional regex pattern to match titles
- **`CHECKS.alwaysPassCI`** — if `true`, logs the failure but doesn't fail the CI check
- **`MESSAGES`** — custom success, failure, and notice messages

## Requirements

The action runs as a composite shell script. GitHub-hosted runners include `jq` and `gh` CLI out of the box — no build step or `node_modules` required.
