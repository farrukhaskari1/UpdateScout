#!/usr/bin/env bash
# Fails when files intended for Git contain common secrets or personal data.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v rg >/dev/null 2>&1; then
  echo "Public-safety check requires ripgrep (rg)." >&2
  exit 2
fi

common_secret_pattern='BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|xox[baprs]-[0-9A-Za-z-]{10,}|sk-(live-)?[A-Za-z0-9]{20,}|rk_live_[A-Za-z0-9]{20,}|https?://[^/@[:space:]]+:[^/@[:space:]]+@'
personal_data_pattern='/Users/[^/[:space:]]+|[A-Za-z0-9._%+-]+@(gmail|yahoo|hotmail|outlook)\.[A-Za-z]{2,}'

scan() {
  local label="$1"
  local pattern="$2"
  local matches

  matches="$(rg -l -I --hidden \
    -g '!.git/**' \
    -g '!.build/**' \
    -g '!dist/**' \
    -g '!scripts/check-public.sh' \
    -e "$pattern" . || true)"

  if [[ -n "$matches" ]]; then
    echo "Public-safety check failed: $label detected in:" >&2
    printf '%s\n' "$matches" >&2
    return 1
  fi
}

scan "a possible credential" "$common_secret_pattern"
scan "a personal path or email address" "$personal_data_pattern"

risky_files="$(find . -type f \
  -not -path './.git/*' \
  -not -path './.build/*' \
  -not -path './dist/*' \
  -not -name '.env.example' \
  \( -iname '*.pem' -o -iname '*.key' -o -iname '*.p8' -o \
     -iname '*.p12' -o -iname '*.mobileprovision' -o -iname '.env' -o \
     -iname '.env.*' \) -print)"

if [[ -n "$risky_files" ]]; then
  echo "Public-safety check failed: credential-like files detected:" >&2
  printf '%s\n' "$risky_files" >&2
  exit 1
fi

echo "Public-safety check passed."
