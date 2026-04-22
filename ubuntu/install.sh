#!/usr/bin/env bash
# doghouse-setup.sh
# One-shot bootstrap for Windows/WSL/Ubuntu users setting up doghouse + Claude Code.
# Run inside a fresh WSL Ubuntu terminal:  bash doghouse-setup.sh
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

# Idempotent line-in-file: remove any line matching $regex, then append $line
ensure_line() {
  local file="$1" regex="$2" line="$3"
  touch "$file"
  sed -i "\|$regex|d" "$file"
  printf "%s\n" "$line" >> "$file"
}

# ═══ STEP 0: preflight ═══
step_preflight() {
  hdr "Preflight"
  [ "$EUID" -eq 0 ] && die "Don't run as root. Run as your normal user; sudo will be invoked where needed."
  command -v sudo >/dev/null || die "sudo not installed."
  sudo -v || die "Unable to obtain sudo."
  command -v curl >/dev/null || die "curl not installed. Run: sudo apt install -y curl"
  if grep -qi microsoft /proc/version 2>/dev/null; then
    # Distinguish WSL1 (Microsoft-capitalized, no version suffix) from WSL2 (microsoft-standard or WSL2 in kernel release)
    if grep -qiE "WSL2|microsoft-standard" /proc/sys/kernel/osrelease 2>/dev/null; then
      ok "WSL2 detected"
    else
      die "WSL1 detected — Claude Code and Node.js require WSL2.
  From Windows PowerShell, upgrade your distro:
    wsl --list --verbose
    wsl --set-version <your-distro-name> 2
    wsl --set-default-version 2
  Then reopen this terminal and re-run the installer."
    fi
  else
    warn "Not WSL — proceeding anyway."
  fi
  log "Checking internet connectivity..."
  curl -sS --max-time 5 -o /dev/null https://github.com || die "Can't reach github.com. Check your internet connection and try again."
  ok "Internet reachable"
  ok "Preflight passed"
}

# ═══ STEP 1: system prerequisites ═══
step_prereqs() {
  hdr "Installing system prerequisites"
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    git curl ca-certificates build-essential \
    jq unzip openssh-client tmate
  ok "Prereqs installed"
}

# ═══ STEP 2: Node.js via nvm (for npx / MCP servers) ═══
# Important: WSL's Windows interop exposes Windows-side Node (/mnt/c/Program Files/nodejs/)
# into the Linux PATH. Windows npm's WSL detection is broken and incorrectly reports
# "WSL 1 is not supported" even on WSL2. We must install and use Linux Node via nvm,
# ignoring whatever Windows has on PATH.
step_node() {
  hdr "Installing Node.js (for MCP servers: playwright, context7, linear)"

  # Detect if Windows Node is leaking into PATH — warn the user
  local win_node
  win_node=$(command -v node 2>/dev/null || true)
  if [[ "$win_node" == /mnt/c/* ]]; then
    warn "Windows Node detected at $win_node — will be superseded by Linux nvm install."
  fi

  # Install nvm if missing
  [ ! -d "$HOME/.nvm" ] && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash

  # Always source nvm — don't trust PATH state, since Windows interop pollutes it
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"

  # Install/activate LTS (idempotent — nvm detects already-installed)
  nvm install --lts >/dev/null
  nvm use --lts >/dev/null

  # Verify we're now pointing at Linux Node, not Windows
  local node_path npm_path
  node_path=$(command -v node)
  npm_path=$(command -v npm)
  [[ "$node_path" == /mnt/c/* ]] && die "PATH still resolving to Windows Node ($node_path). Uninstall Windows Node.js or fix PATH ordering."
  [[ "$npm_path"  == /mnt/c/* ]] && die "PATH still resolving to Windows npm ($npm_path). Uninstall Windows Node.js or fix PATH ordering."

  ok "Linux Node $(node --version) at $node_path"
}

# ═══ STEP 3: uv (for uvx / Python MCP servers) ═══
step_uv() {
  hdr "Installing uv (for Python MCP servers: serena)"
  if command -v uvx >/dev/null; then
    ok "uvx already available"
    return
  fi
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  ok "uv $(uv --version 2>/dev/null | awk '{print $2}') installed"
}

# ═══ STEP 4: shell hygiene ═══
step_shell() {
  hdr "Configuring shell"

  # Bridge: login shells (from tmux, SSH) source ~/.bashrc
  ensure_line "$HOME/.bash_profile" '\.bashrc' '[ -f ~/.bashrc ] && source ~/.bashrc'
  ok "~/.bash_profile sources ~/.bashrc"

  # Defense-in-depth: never hang on git credential prompts
  ensure_line "$HOME/.bashrc" 'GIT_TERMINAL_PROMPT' 'export GIT_TERMINAL_PROMPT=0'
  export GIT_TERMINAL_PROMPT=0
  ok "GIT_TERMINAL_PROMPT=0 set"

  # ~/.local/bin on PATH (native-binary Claude, uv, user-scoped pip)
  ensure_line "$HOME/.bashrc" '\.local/bin' 'export PATH="$HOME/.local/bin:$PATH"'
  export PATH="$HOME/.local/bin:$PATH"
  ok "~/.local/bin on PATH"
}

# ═══ STEP 4b: Claude Code (idempotent — skips if already installed) ═══
step_claude() {
  hdr "Installing Claude Code"
  if command -v claude >/dev/null 2>&1; then
    ok "Claude Code already installed: $(claude --version 2>&1 | head -1 || echo 'installed')"
    return
  fi
  log "Installing via npm (global)..."
  npm install -g @anthropic-ai/claude-code
  command -v claude >/dev/null 2>&1 || die "Claude install completed but 'claude' not on PATH. Check npm global prefix."
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

  # Pre-seed GitHub host key — avoids yes/no TOFU prompt that would hang the script
  if ! ssh-keygen -F github.com >/dev/null 2>&1; then
    ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
    ok "GitHub host key cached in ~/.ssh/known_hosts"
  fi
}

# ═══ STEP 7: deploy key handoff (user-paced, no timers) ═══
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
      429)      warn "Rate limited (HTTP 429). Key format is valid — proceeding without full verification."; break ;;
      000)      warn "Couldn't reach api.anthropic.com. Network issue — proceeding without verification."; break ;;
      *)        warn "Unexpected response (HTTP $http_status). Proceeding — you can validate manually with 'claude' later."; break ;;
    esac
  done

  ensure_line "$HOME/.bashrc" 'ANTHROPIC_API_KEY' "export ANTHROPIC_API_KEY=\"$key\""
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

# ═══ STEP 11: verify Claude starts cleanly ═══
step_verify() {
  hdr "Verifying Claude Code"
  if ! command -v claude >/dev/null; then
    warn "claude not on PATH — doghouse/install.sh may not install it. Skipping verify."
    return
  fi

  log "Launching Claude in background for 10s to check for startup errors..."
  timeout 12 claude --debug >/dev/null 2>&1 &
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
  printf "\n${BOLD}═══ Doghouse + Claude Code Setup ═══${RESET}\n"
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
