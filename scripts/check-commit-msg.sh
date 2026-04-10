#!/usr/bin/env bash
# Blocks commit messages that contain AI co-author lines.
# Enforces Conventional Commits format: type(scope)?: description

set -euo pipefail

COMMIT_MSG_FILE="$1"
COMMIT_MSG=$(cat "$COMMIT_MSG_FILE")

# Strip comment lines before validation
STRIPPED=$(grep -v '^\s*#' "$COMMIT_MSG_FILE" || true)

# 1. Block AI co-author
if echo "$STRIPPED" | grep -qiE '^Co-Authored-By:.*claude|^Co-Authored-By:.*codex|^Co-Authored-By:.*openai|^Co-Authored-By:.*anthropic'; then
  echo "❌ [commit-msg] AI co-author는 커밋 메시지에 포함할 수 없습니다."
  echo "   Co-Authored-By: Claude / Codex / OpenAI / Anthropic 라인을 제거하세요."
  exit 1
fi

# 2. Conventional Commits format check (first non-empty, non-comment line)
SUBJECT=$(echo "$STRIPPED" | grep -v '^\s*$' | head -1)

CONVENTIONAL_PATTERN='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\(.+\))?: .+'
if ! echo "$SUBJECT" | grep -qE "$CONVENTIONAL_PATTERN"; then
  echo "❌ [commit-msg] Conventional Commits 형식이 아닙니다."
  echo "   형식: type(scope)?: description"
  echo "   허용 type: feat | fix | docs | style | refactor | perf | test | build | ci | chore | revert"
  echo ""
  echo "   예시: feat: 로그인 기능 추가"
  echo "         fix(auth): 토큰 만료 처리 수정"
  echo ""
  echo "   입력된 메시지: $SUBJECT"
  exit 1
fi

exit 0
