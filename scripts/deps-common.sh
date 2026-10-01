# Sourced by scripts/outdated.sh (the pre-push gate) and
# scripts/bump-deps.sh (the pre-commit bump), from the repo root, so both
# read the exemptions and the two outdated reports the same way. Each
# function prints why it failed, prefixed with the caller's $prefix, and
# returns 1.

# require_tools TOOL...: fails when any TOOL is not on PATH.
require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || {
      echo "$prefix required tool '$tool' missing — cannot check dependencies."
      return 1
    }
  done
}

# load_exemptions: sets EXEMPT_JSON from scripts/dep-exemptions.json, a
# map of package name → {version, reason}. `version` is the newest
# upstream release being declined, and `reason` says why.
load_exemptions() {
  EXEMPT_JSON=$(cat scripts/dep-exemptions.json 2>/dev/null) || EXEMPT_JSON=""
  jq -e 'type == "object" and all(.[];
           type == "object"
           and (.version | type) == "string" and (.version | length) > 0
           and (.reason | type) == "string" and (.reason | length) > 0)' \
    <<<"$EXEMPT_JSON" >/dev/null 2>&1 || {
    echo "$prefix scripts/dep-exemptions.json is missing or malformed — each entry needs a \"version\" and a \"reason\"."
    return 1
  }
}

# exemption_version NAME: the release NAME's entry declines, or nothing.
exemption_version() {
  jq -r --arg n "$1" '.[$n].version // empty' <<<"$EXEMPT_JSON"
}

# pnpm_outdated [ARG...]: sets PNPM_ROWS to one "name<TAB>latest" line
# per JS dependency behind latest, across the workspace. pnpm's latest is
# the newest release past minimumReleaseAge, so it can trail npm_latest;
# ARGs go to pnpm, so --config.minimum-release-age=0 reports the
# registry's latest instead.
pnpm_outdated() {
  local json err rc
  err=$(mktemp)
  # pnpm outdated exits 1 when it FINDS outdated deps, so the exit code
  # alone can't tell findings from breakage: a JSON object on stdout is
  # the success signal. Warnings go to stderr, kept out of the JSON.
  json=$(pnpm -r outdated --format json "$@" 2>"$err") && rc=0 || rc=$?
  if ((rc > 1)) || ! jq -e 'type == "object"
      and all(.[]; (.latest | type) == "string")' <<<"$json" >/dev/null 2>&1; then
    cat "$err"
    echo "$json"
    rm -f "$err"
    echo "$prefix pnpm outdated produced no JSON report (exit $rc) — cannot check JS deps."
    return 1
  fi
  rm -f "$err"
  PNPM_ROWS=$(jq -r 'to_entries[] | [.key, .value.latest] | @tsv' <<<"$json")
}

# npm_latest NAME: prints the release NAME's "latest" dist-tag names on
# the registry, however young it is. Its failure message goes to stderr,
# since callers capture stdout.
npm_latest() {
  local latest
  latest=$(pnpm view "$1" dist-tags.latest) && [[ "$latest" =~ ^[^[:space:]]+$ ]] || {
    echo "$prefix could not read $1's latest release from the registry — cannot check its exemption." >&2
    return 1
  }
  echo "$latest"
}

# hex_outdated: sets HEX_OUT to the `mix hex.outdated` report and
# HEX_ROWS to one "name latest status" line per Hex dependency behind
# latest. status is "possible", "not" when a requirement (in mix.exs
# or another dependency) excludes latest, or "cooldown" when the
# requirements admit latest but it is still in the configured Hex
# cooldown window and so not yet installable. Hex marks no cooldown on a
# release the requirements exclude, so that one is "not".
hex_outdated() {
  local rc
  # hex.outdated exits 1 when updates exist.
  HEX_OUT=$(mix hex.outdated 2>&1) && rc=0 || rc=$?
  if ((rc > 1)) || ! HEX_ROWS=$(awk '
      /^Dependency / { table = 1; next }
      table && NF == 0 { exit }
      table {
        # Only is optional, so find Status by its first word.
        for (i = 4; i <= NF; i++) if ($i == "Up-to-date" || $i == "Update") break
        if (i > NF) { bad = 1; exit }
        status = $i
        for (j = i + 1; j <= NF; j++) status = status " " $j
        if (status ~ /^Up-to-date/) next
        if (status == "Update possible (cooldown)") print $1, $(i - 1), "cooldown"
        else if (status == "Update possible") print $1, $(i - 1), "possible"
        else if (status == "Update not possible") print $1, $(i - 1), "not"
        else { bad = 1; exit }
      }
      END { exit bad || !table }' <<<"$HEX_OUT"); then
    echo "$HEX_OUT"
    echo "$prefix mix hex.outdated produced no readable dependency table (exit $rc) — cannot check Hex deps."
    return 1
  fi
}
