#!/usr/bin/env bash
# install.sh (macOS)
# One-shot bootstrap for macOS users setting up doghouse + Claude Code.
# Run in a terminal:  bash install.sh
# Safe to re-run at any time — every step is idempotent.

set -euo pipefail

# ═══ CONFIG — edit if the repo moves ═══
DOGHOUSE_REPO_SSH="git@github.com:corgi-tech/doghouse.git"
DOGHOUSE_DIR="$HOME/doghouse"
DOGHOUSE_DEPLOY_KEYS_URL="https://github.com/corgi-tech/doghouse/settings/keys"

# ═══ UI helpers ═══
BOLD=$(tput bold 2>/dev/null || true); RESET=$(tput sgr0 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true); GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true); BLUE=$(tput setaf 4 2>/dev/null || true)

log()  { printf "${BLUE}▸${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}✓${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}!${RESET} %s\n" "$*"; }
die()  { printf "${RED}✗${RESET} %s\n" "$*" >&2; exit 1; }
hdr()  { printf "\n${BOLD}══ %s ══${RESET}\n" "$*"; }

prompt_input() {
  local label="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -rp "  $label [$default]: " reply
    printf "%s" "${reply:-$default}"
  else
    read -rp "  $label: " reply
    printf "%s" "$reply"
  fi
}

confirm_continue() { read -rp "  $1 (Enter to continue, Ctrl-C to abort) " _; }

# macOS sed requires an empty backup-ext argument to -i
ensure_line() {
  local file="$1" regex="$2" line="$3"
  touch "$file"
  sed -i '' "\|$regex|d" "$file"
  printf "%s\n" "$line" >> "$file"
}

# ═══ Shell detection (macOS default: zsh since Catalina 10.15) ═══
RC_FILE=""; PROFILE_FILE=""; SHELL_NAME=""
detect_shell_rcs() {
  SHELL_NAME=$(basename "${SHELL:-zsh}")
  case "$SHELL_NAME" in
    zsh)  RC_FILE="$HOME/.zshrc";  PROFILE_FILE="$HOME/.zprofile"  ;;
    bash) RC_FILE="$HOME/.bashrc"; PROFILE_FILE="$HOME/.bash_profile" ;;
    *)    die "Unsupported shell: $SHELL_NAME. This script supports zsh (default) and bash." ;;
  esac
}

# ═══ STEP 0: preflight ═══
step_preflight() {
  hdr "Preflight"
  [ "$EUID" -eq 0 ] && die "Don't run as root. Run as your normal user; sudo will be invoked where needed."
  [ "$(uname)" = "Darwin" ] || die "This script is for macOS. For Ubuntu/WSL see ../ubuntu/install.sh; for Arch see ../arch/install.sh."
  command -v sudo >/dev/null || die "sudo not installed."
  sudo -v || die "Unable to obtain sudo."
  command -v curl >/dev/null || die "curl not installed (should be pre-installed on macOS)."
  log "Checking internet connectivity..."
  curl -sS --max-time 5 -o /dev/null https://github.com || die "Can't reach github.com. Check your internet connection."
  ok "macOS $(sw_vers -productVersion) on $(uname -m)"
  ok "Shell: $SHELL_NAME (rc=$RC_FILE, profile=$PROFILE_FILE)"
  ok "Internet reachable"
}

# ═══ STEP 1: system prerequisites (Xcode CLT + Homebrew + packages) ═══
BREW_PREFIX=""
step_prereqs() {
  hdr "Installing system prerequisites"

  # Xcode Command Line Tools — installing requires a GUI popup, so fail-fast with instructions
  if ! xcode-select -p >/dev/null 2>&1; then
    die "Xcode Command Line Tools not installed.
  Run:    xcode-select --install
  Click 'Install' in the popup, wait for it to finish (~5 min), then re-run this script."
  fi
  ok "Xcode Command Line Tools present"

  # Homebrew
  if ! command -v brew >/dev/null 2>&1; then
    log "Installing Homebrew (non-interactive)..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  # Locate brew binary — /opt/homebrew on Apple silicon, /usr/local on Intel
  if [ -x /opt/homebrew/bin/brew ]; then
    BREW_PREFIX="/opt/homebrew"
  elif [ -x /usr/local/bin/brew ]; then
    BREW_PREFIX="/usr/local"
  else
    die "Homebrew install succeeded but brew binary not found at /opt/homebrew or /usr/local."
  fi
  eval "$("$BREW_PREFIX/bin/brew" shellenv)"
  ok "Homebrew at $BREW_PREFIX"

  log "Installing brew packages: git jq tmate..."
  brew install git jq tmate >/dev/null
  ok "Prereqs installed"
}

# ═══ STEP 2: Node.js via nvm ═══
# Always source nvm and install LTS — both nvm and "nvm install --lts" are idempotent.
# Don't trust PATH state; a stale brew-installed node or an outdated shim can cause
# step_claude to invoke the wrong npm later.
step_node() {
  hdr "Installing Node.js (for MCP servers: playwright, context7, linear)"

  # Install nvm if missing
  [ ! -d "$HOME/.nvm" ] && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash

  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"

  nvm install --lts >/dev/null
  nvm use --lts >/dev/null

  ok "Linux/macOS Node $(node --version) at $(command -v node)"
}

# ═══ STEP 3: uv ═══
step_uv() {
  hdr "Installing uv (for Python MCP servers: serena)"
  if command -v uvx >/dev/null 2>&1; then
    ok "uvx already available"
    return
  fi
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  ok "uv $(uv --version 2>/dev/null | awk '{print $2}') installed"
}

# ═══ STEP 4: shell hygiene ═══
step_shell() {
  hdr "Configuring shell ($SHELL_NAME)"

  # Bash users need a ~/.bash_profile that sources ~/.bashrc — zsh reads ~/.zshrc natively
  if [ "$SHELL_NAME" = "bash" ]; then
    ensure_line "$PROFILE_FILE" '\.bashrc' '[ -f ~/.bashrc ] && source ~/.bashrc'
    ok "$PROFILE_FILE sources $RC_FILE"
  fi

  # Defense-in-depth: never hang on git credential prompts
  ensure_line "$RC_FILE" 'GIT_TERMINAL_PROMPT' 'export GIT_TERMINAL_PROMPT=0'
  export GIT_TERMINAL_PROMPT=0
  ok "GIT_TERMINAL_PROMPT=0 in $RC_FILE"

  # ~/.local/bin on PATH
  ensure_line "$RC_FILE" '\.local/bin' 'export PATH="$HOME/.local/bin:$PATH"'
  export PATH="$HOME/.local/bin:$PATH"
  ok "~/.local/bin on PATH in $RC_FILE"

  # Persist brew shellenv so new shells have brew on PATH
  ensure_line "$RC_FILE" 'brew shellenv' "eval \"\$($BREW_PREFIX/bin/brew shellenv)\""
  ok "brew shellenv persisted in $RC_FILE"
}

# ═══ STEP 4b: Claude Code ═══
step_claude() {
  hdr "Installing Claude Code"
  if command -v claude >/dev/null 2>&1; then
    ok "Claude Code already installed: $(claude --version 2>&1 | head -1 || echo 'installed')"
    return
  fi
  log "Installing via npm (global)..."
  npm install -g @anthropic-ai/claude-code
  command -v claude >/dev/null 2>&1 || die "Claude install completed but 'claude' not on PATH."
  ok "Claude Code installed: $(claude --version 2>&1 | head -1)"
}

# ═══ STEP 5: git identity ═══
step_git_identity() {
  hdr "Git identity"
  local existing_name existing_email name email
  existing_name=$(git config --global user.name 2>/dev/null || true)
  existing_email=$(git config --global user.email 2>/dev/null || true)
  name=$(prompt_input "Git user name" "$existing_name")
  email=$(prompt_input "Git user email" "$existing_email")
  [ -z "$name" ] && die "Git user name is required."
  [ -z "$email" ] && die "Git user email is required."
  git config --global user.name "$name"
  git config --global user.email "$email"
  ok "Git identity: $name <$email>"
}

# ═══ STEP 6: SSH key + known_hosts seed ═══
step_ssh_key() {
  hdr "SSH key setup"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if [ -f "$HOME/.ssh/id_ed25519" ]; then
    ok "SSH key already exists: ~/.ssh/id_ed25519"
  else
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "$(whoami)-$(hostname)-doghouse" >/dev/null
    ok "SSH key generated"
  fi
  if ! ssh-keygen -F github.com >/dev/null 2>&1; then
    ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
    ok "GitHub host key cached in ~/.ssh/known_hosts"
  fi
}

# ═══ STEP 7: deploy key handoff (user-paced) ═══
step_deploy_key() {
  hdr "Register your SSH key as a GitHub deploy key"
  printf "\n${BOLD}Send this public key to Paul:${RESET}\n\n"
  printf "%s\n\n" "$(cat "$HOME/.ssh/id_ed25519.pub")"
  printf "Paul will add it as a deploy key at:\n  ${BLUE}%s${RESET}\n\n" "$DOGHOUSE_DEPLOY_KEYS_URL"

  local output
  while :; do
    local added
    added=$(prompt_input "Has Paul added the key? (y/n)" "")
    if [[ "$added" != "y" ]]; then
      printf "  ${YELLOW}No rush — take your time. Re-answer when it's done.${RESET}\n"
      continue
    fi
    log "Testing GitHub SSH auth..."
    output=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes -T git@github.com 2>&1 || true)
    if printf "%s" "$output" | grep -q "successfully authenticated"; then
      ok "$(printf "%s" "$output" | head -1)"
      return
    fi
    warn "Auth didn't succeed yet: $(printf "%s" "$output" | tail -1)"
    printf "  ${YELLOW}Double-check the key was pasted exactly (no extra spaces or line breaks).${RESET}\n"
    printf "  ${YELLOW}Then answer 'y' again to retry.${RESET}\n"
  done
}

# ═══ STEP 8: Claude API key ═══
step_api_key() {
  hdr "Claude API key"
  log "Get a key from: https://console.anthropic.com/settings/keys"

  local existing key
  existing="${ANTHROPIC_API_KEY:-}"
  if [ -n "$existing" ] && [[ "$existing" =~ ^sk-ant- ]]; then
    local keep
    keep=$(prompt_input "API key already set (${existing:0:12}...). Keep it? (y/n)" "y")
    [[ "$keep" == "y" ]] && { ok "Keeping existing key"; return; }
  fi

  while :; do
    key=$(prompt_input "Paste your Claude API key (starts with sk-ant-)")
    if ! [[ "$key" =~ ^sk-ant-[A-Za-z0-9_-]+$ ]]; then
      warn "Key format looks wrong. Expected: sk-ant-<alphanumerics>. Try again."
      continue
    fi
    log "Testing key against Anthropic API..."
    local http_status
    http_status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
      https://api.anthropic.com/v1/messages \
      -H "x-api-key: $key" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' 2>/dev/null || echo "000")
    case "$http_status" in
      200)      ok "API key verified by Anthropic"; break ;;
      401|403)  warn "API rejected the key (HTTP $http_status). Check for typos and try again." ;;
      429)      warn "Rate limited (HTTP 429). Key format is valid — proceeding."; break ;;
      000)      warn "Couldn't reach api.anthropic.com. Proceeding without verification."; break ;;
      *)        warn "Unexpected response (HTTP $http_status). Proceeding."; break ;;
    esac
  done

  ensure_line "$RC_FILE" 'ANTHROPIC_API_KEY' "export ANTHROPIC_API_KEY=\"$key\""
  export ANTHROPIC_API_KEY="$key"
  ok "API key set (${key:0:12}...)"
}

# ═══ STEP 9: clone doghouse ═══
step_clone_doghouse() {
  hdr "Cloning doghouse"
  if [ -d "$DOGHOUSE_DIR/.git" ]; then
    ok "doghouse already at $DOGHOUSE_DIR — pulling latest"
    ( cd "$DOGHOUSE_DIR" && git pull --ff-only ) || warn "Pull failed; continuing with existing copy."
    return
  fi
  git clone "$DOGHOUSE_REPO_SSH" "$DOGHOUSE_DIR"
  ok "doghouse cloned to $DOGHOUSE_DIR"
}

# ═══ STEP 10: run doghouse install.sh ═══
step_install_doghouse() {
  hdr "Running doghouse/install.sh"
  if [ ! -f "$DOGHOUSE_DIR/install.sh" ]; then
    die "Expected $DOGHOUSE_DIR/install.sh but it's missing. Clone may be incomplete or on the wrong branch."
  fi
  ( cd "$DOGHOUSE_DIR" && bash install.sh )
  ok "doghouse install.sh completed"
}

# ═══ STEP 11: verify Claude launches cleanly ═══
step_verify() {
  hdr "Verifying Claude Code"
  if ! command -v claude >/dev/null; then
    warn "claude not on PATH — run 'claude' manually to check."
    return
  fi
  log "Launching Claude in background for 10s to check for startup errors..."
  # macOS lacks GNU timeout by default — use sleep + kill pattern instead
  claude --debug >/dev/null 2>&1 &
  local pid=$!
  sleep 10
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  local newest
  newest=$(ls -t "$HOME/.claude/debug/"*.txt 2>/dev/null | head -1 || true)
  if [ -z "$newest" ]; then
    warn "No debug log produced — run 'claude' manually to check."
    return
  fi
  if grep -qE "fatal:|Username for 'https" "$newest"; then
    warn "Git errors found in debug log:"
    grep -E "fatal:|Username for" "$newest" | head -5
    warn "See full log: $newest"
    return
  fi
  ok "Claude launched cleanly — no git errors in debug log"
}

# ═══ MAIN ═══
main() {
  detect_shell_rcs
  printf "\n${BOLD}═══ Doghouse + Claude Code Setup (macOS) ═══${RESET}\n"
  printf "You'll be prompted for:\n"
  printf "  • Git user name + email\n"
  printf "  • A pause to hand off an SSH key to Paul\n"
  printf "  • Your Claude API key\n\n"
  confirm_continue "Ready?"

  step_preflight
  step_prereqs
  step_node
  step_uv
  step_shell
  step_claude
  step_git_identity
  step_ssh_key
  step_deploy_key
  step_api_key
  step_clone_doghouse
  step_install_doghouse
  step_verify

  printf "\n${GREEN}${BOLD}═══ All done ═══${RESET}\n"
  printf "Open a new terminal window and run: ${BOLD}claude${RESET}\n"
  printf "Debug logs live in: ~/.claude/debug/\n"
  printf "If anything breaks, re-run this script — every step is idempotent.\n\n"
}

main "$@"
