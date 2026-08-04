#!/usr/bin/env bash
set -euo pipefail

original_path="${PATH:-}"
PATH=/usr/bin:/bin
export PATH
export TOKI_REVIEW_ORIGINAL_PATH="$original_path"

unset GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_COMMON_DIR
unset GIT_CONFIG_PARAMETERS
unset GIT_DIR
unset GIT_EXEC_PATH
unset GIT_INDEX_FILE
unset GIT_NAMESPACE
unset GIT_OBJECT_DIRECTORY
unset GIT_WORK_TREE

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_dir="$(cd "$script_dir/.." && pwd)"
repo="."
lane=""
scope_kind=""
scope_value=""

usage() {
  printf '%s\n' \
    "Usage: run_review_lane.sh --lane ID [--repo PATH] (--uncommitted | --base BRANCH | --commit SHA)"
}

set_scope() {
  local next_kind="$1"
  local next_value="$2"
  if [[ -n "$scope_kind" ]]; then
    printf 'run_review_lane.sh: choose exactly one review scope\n' >&2
    exit 2
  fi
  scope_kind="$next_kind"
  scope_value="$next_value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      repo="$2"
      shift 2
      ;;
    --lane)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      lane="$2"
      shift 2
      ;;
    --uncommitted)
      set_scope "uncommitted" ""
      shift
      ;;
    --base)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      set_scope "base" "$2"
      shift 2
      ;;
    --commit)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      set_scope "commit" "$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'run_review_lane.sh: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$lane" || -z "$scope_kind" ]]; then
  usage >&2
  exit 2
fi
if [[ ! "$lane" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
  printf 'run_review_lane.sh: invalid lane id\n' >&2
  exit 2
fi

if ! IFS= read -r -d '' repo_root < <(
  python3 "$script_dir/resolve_repo_root.py" "$repo"
); then
  exit 2
fi
temp_dir="$(mktemp -d)"
cleanup() {
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT

scope_file="$temp_dir/scope.json"
prompt_file="$temp_dir/prompt.md"
result_file="$temp_dir/result.json"
resolver_args=(--repo "$repo_root")
codex_scope_args=()

case "$scope_kind" in
  uncommitted)
    resolver_args+=(--uncommitted)
    codex_scope_args+=(--uncommitted)
    ;;
  base)
    resolver_args+=(--base "$scope_value")
    codex_scope_args+=(--base "$scope_value")
    ;;
  commit)
    resolver_args+=(--commit "$scope_value")
    codex_scope_args+=(--commit "$scope_value")
    ;;
esac

python3 "$script_dir/resolve_review_scope.py" "${resolver_args[@]}" > "$scope_file"

lane_prompt="$(
  python3 - "$scope_file" "$lane" <<'PY'
import json
import sys

scope_path, requested_lane = sys.argv[1:]
with open(scope_path, encoding="utf-8") as handle:
    scope = json.load(handle)
if not scope.get("hasChanges"):
    raise SystemExit("run_review_lane.sh: the selected scope has no changes")
if not scope.get("safeToReview"):
    reasons = scope.get("blockingReasons") or ["the scope is unsafe"]
    raise SystemExit("run_review_lane.sh: " + " ".join(reasons))
for lane in scope.get("activatedLanes", []):
    if lane.get("id") == requested_lane:
        print(lane["prompt"])
        break
else:
    raise SystemExit(f"run_review_lane.sh: lane is not active for this scope: {requested_lane}")
PY
)"

common_prompt="$skill_dir/references/prompts/reviewer.md"
selected_prompt="$skill_dir/$lane_prompt"
schema_file="$skill_dir/references/schemas/review-findings.schema.json"
if [[ ! -f "$common_prompt" || ! -f "$selected_prompt" || ! -f "$schema_file" ]]; then
  printf 'run_review_lane.sh: a required prompt or schema file is missing\n' >&2
  exit 2
fi

{
  printf '# Selected review lane\n\n'
  printf 'Set the output lane field to: %s\n\n' "$lane"
  python3 - "$scope_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    resolved = json.load(handle)
scope = {
    "kind": resolved["scope"]["kind"],
    "comparisonMode": {
        "uncommitted": "working-tree",
        "base": "merge-base",
        "commit": "first-parent",
    }[resolved["scope"]["kind"]],
}
print("<review-scope-json>")
print(json.dumps(scope, ensure_ascii=False, separators=(",", ":")))
print("</review-scope-json>")
print()
PY
  sed -n '1,$p' "$common_prompt"
  printf '\n\n'
  sed -n '1,$p' "$selected_prompt"
} > "$prompt_file"

codex_candidate="${TOKI_REVIEW_CODEX_BIN:-codex}"
codex_path="$(PATH="$original_path" command -v "$codex_candidate" || true)"
if [[ -z "$codex_path" ]]; then
  printf 'run_review_lane.sh: review executable is unavailable\n' >&2
  exit 2
fi
codex_bin="$(
  python3 - "$repo_root" "$codex_path" <<'PY'
from pathlib import Path
import sys

repo = Path(sys.argv[1]).resolve()
candidate = Path(sys.argv[2]).resolve(strict=True)
try:
    candidate.relative_to(repo)
except ValueError:
    print(candidate)
else:
    print("run_review_lane.sh: review executable must be outside the repository", file=sys.stderr)
    raise SystemExit(2)
PY
)"
developer_config="$(
  python3 - "$prompt_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    prompt = handle.read()
print(f"developer_instructions={json.dumps(prompt, ensure_ascii=False)}")
PY
)"
codex_args=(
  exec
  --sandbox read-only
  --ephemeral
  --output-schema "$schema_file"
  --output-last-message "$result_file"
  review
  "${codex_scope_args[@]}"
  -c "$developer_config"
)

python3 "$script_dir/run_with_safe_git.py" \
  "$repo_root" \
  -- \
  "$codex_bin" \
  "${codex_args[@]}" > /dev/null

if [[ ! -s "$result_file" ]]; then
  printf 'run_review_lane.sh: Codex did not write a structured result\n' >&2
  exit 2
fi

python3 "$script_dir/merge_findings.py" validate --lane "$lane" "$result_file" >/dev/null
python3 - "$result_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
json.dump(result, sys.stdout, ensure_ascii=True, separators=(",", ":"))
sys.stdout.write("\n")
PY
