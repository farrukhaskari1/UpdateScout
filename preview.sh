#!/usr/bin/env bash
#
# UpdateScout preview — runs the same checks the app runs, prints a report.
#
# Read-only. It never installs, upgrades, removes, or modifies anything;
# every command below is a query. Read it before you run it.
#
#   ./preview.sh
#
set -uo pipefail   # deliberately no -e: a missing tool must not abort the survey

BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'

have() { command -v "$1" >/dev/null 2>&1; }

section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }
missing() { printf '  %snot installed%s\n' "$DIM" "$RESET"; }
clean()   { printf '  %sup to date%s\n' "$GREEN" "$RESET"; }

printf '%sUpdateScout preview%s  —  %s\n' "$BOLD" "$RESET" "$(date '+%Y-%m-%d %H:%M')"
printf '%smacOS %s (%s)  ·  %s%s\n' "$DIM" "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)" "$(uname -m)" "$RESET"

# ---------------------------------------------------------------- inventory
section "What's installed"
for tool in brew mas mise rustup npm pnpm yarn bun pipx uv pip3 gem cargo go composer rbenv pyenv asdf volta deno; do
  if have "$tool"; then
    printf '  %-10s %s%s%s\n' "$tool" "$DIM" "$(command -v "$tool")" "$RESET"
  fi
done
printf '  %s%s apps in /Applications%s\n' "$DIM" "$(ls -1d /Applications/*.app 2>/dev/null | wc -l | tr -d ' ')" "$RESET"
printf '  %s%s of them ship a Sparkle feed%s\n' "$DIM" \
  "$(for a in /Applications/*.app; do /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$a/Contents/Info.plist" 2>/dev/null; done | wc -l | tr -d ' ')" "$RESET"

# ---------------------------------------------------------------- pending
section "macOS"
su_out="$(softwareupdate --list 2>&1)"
if grep -q "No new software available" <<<"$su_out"; then
  clean
else
  grep -E '^\s*\*|^\s+Title:' <<<"$su_out" | sed 's/^/  /'
fi
printf '  %smajor upgrades offered:%s\n' "$DIM" "$RESET"
softwareupdate --list-full-installers 2>/dev/null | grep -E '^\s*\*' | sed 's/^/    /' | tail -5 \
  || printf '    %snone reported%s\n' "$DIM" "$RESET"

section "Homebrew"
if have brew; then
  out="$(brew outdated --greedy 2>/dev/null)"
  [[ -n "$out" ]] && sed 's/^/  /' <<<"$out" || clean
else missing; fi

section "Mac App Store"
if have mas; then
  out="$(mas outdated 2>/dev/null)"
  [[ -n "$out" ]] && sed 's/^/  /' <<<"$out" || clean
else missing; fi

section "mise"
if have mise; then
  out="$(mise outdated 2>/dev/null)"
  [[ -n "$out" ]] && sed 's/^/  /' <<<"$out" || clean
else missing; fi

section "rustup"
if have rustup; then
  out="$(rustup check 2>/dev/null | grep -i 'update available')"
  [[ -n "$out" ]] && sed 's/^/  /' <<<"$out" || clean
else missing; fi

section "npm (global)"
if have npm; then
  out="$(npm outdated -g 2>/dev/null | tail -n +2)"
  [[ -n "$out" ]] && sed 's/^/  /' <<<"$out" || clean
else missing; fi

section "pipx"
if have pipx; then
  out="$(pipx list --short 2>/dev/null)"
  [[ -n "$out" ]] && sed 's/^/  /' <<<"$out" \
    && printf '  %s(the app compares these against PyPI; pipx itself can'"'"'t)%s\n' "$DIM" "$RESET" \
    || printf '  %snothing installed%s\n' "$DIM" "$RESET"
else missing; fi

section "uv tools"
if have uv; then
  out="$(uv tool list 2>/dev/null)"
  [[ -n "$out" ]] && sed 's/^/  /' <<<"$out" || printf '  %snothing installed%s\n' "$DIM" "$RESET"
else missing; fi

section "RubyGems"
if have gem; then
  out="$(gem outdated 2>/dev/null)"
  [[ -n "$out" ]] && sed 's/^/  /' <<<"$out" || clean
else missing; fi

section "cargo"
if have cargo; then
  out="$(cargo install --list 2>/dev/null | grep -v '^ ')"
  [[ -n "$out" ]] && sed 's/^/  /' <<<"$out" \
    && printf '  %s(compared against crates.io by the app)%s\n' "$DIM" "$RESET" \
    || printf '  %snothing installed%s\n' "$DIM" "$RESET"
else missing; fi

section "Go binaries"
if have go; then
  bin="$(go env GOBIN)"; [[ -z "$bin" ]] && bin="$(go env GOPATH)/bin"
  if [[ -d "$bin" ]]; then
    ls -1 "$bin" 2>/dev/null | sed 's/^/  /' || printf '  %sempty%s\n' "$DIM" "$RESET"
  else printf '  %sno GOBIN%s\n' "$DIM" "$RESET"; fi
else missing; fi

section "Composer"
if have composer; then
  out="$(composer global outdated --direct --no-interaction 2>/dev/null | tail -n +2)"
  [[ -n "$out" ]] && sed 's/^/  /' <<<"$out" || clean
else missing; fi

section "Apps with Sparkle feeds"
count=0
for app in /Applications/*.app; do
  feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app/Contents/Info.plist" 2>/dev/null)" || continue
  ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null)"
  printf '  %-34s %-12s %s%s%s\n' "$(basename "$app" .app)" "${ver:-?}" "$DIM" "${feed:0:52}" "$RESET"
  count=$((count+1))
done
[[ $count -eq 0 ]] && printf '  %snone found%s\n' "$DIM" "$RESET"
printf '\n  %sThe app fetches each of these feeds and compares versions —\n  this script only lists them.%s\n' "$DIM" "$RESET"

printf '\n%sDone.%s Paste this output back into the chat for a read.\n' "$BOLD" "$RESET"
