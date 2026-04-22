# doghouse-installer

One-shot bootstrap that sets up **Claude Code + doghouse** on a fresh machine.

Each supported platform has its own installer script in a dedicated subdirectory.

## Quick install

Pick the command for your platform, paste it into a terminal, follow the prompts.

### Ubuntu / WSL

```bash
curl -fsSL https://raw.githubusercontent.com/corgi-tech/doghouse-installer/main/ubuntu/install.sh -o /tmp/install.sh && bash /tmp/install.sh
```

### macOS

```bash
curl -fsSL https://raw.githubusercontent.com/corgi-tech/doghouse-installer/main/macos/install.sh -o /tmp/install.sh && bash /tmp/install.sh
```

### Arch / Manjaro / EndeavourOS

```bash
curl -fsSL https://raw.githubusercontent.com/corgi-tech/doghouse-installer/main/arch/install.sh -o /tmp/install.sh && bash /tmp/install.sh
```

All installer scripts are **idempotent** — safe to re-run at any time.

## What the installers do

Every platform installer follows the same outline, adapted to the local package manager and toolchain:

1. Preflight checks (sudo, network, shell)
2. Install system prereqs: `git`, `curl`, `build-essential`, `jq`, `openssh-client`, `tmate`
3. Install Node.js (for MCP servers: `playwright`, `context7`, `linear`)
4. Install `uv` (for Python-based MCP servers: `serena`)
5. Configure shell: `~/.bash_profile` → `~/.bashrc` bridge, `GIT_TERMINAL_PROMPT=0`, `~/.local/bin` on PATH
6. Install Claude Code
7. Prompt for git user name + email
8. Generate `~/.ssh/id_ed25519`
9. Pause for the user to hand the public key to an admin to register as a deploy key on the doghouse repo
10. Prompt for the Anthropic API key — validated against the live API
11. Clone doghouse via SSH
12. Run `doghouse/install.sh`
13. Verify `claude` launches cleanly

## Prerequisites

Platform-specific, but generally:

- **Ubuntu / WSL**: Windows 10+ with WSL installed (`wsl --install -d Ubuntu-24.04` in PowerShell), or a native Ubuntu machine. Internet connection.
- **macOS**: macOS 11+ recommended. Xcode Command Line Tools must be installed before running — if missing, the script will tell you to run `xcode-select --install` and re-run.
- **Arch / Manjaro / EndeavourOS**: Any recent Arch-family release. `sudo` access. Internet connection.

## Repository layout

```
doghouse-installer/
├── README.md          ← this file
├── ubuntu/
│   └── install.sh     ← Ubuntu / WSL installer (apt + bash)
├── macos/
│   └── install.sh     ← macOS installer (brew + zsh-aware)
└── arch/
    └── install.sh     ← Arch / Manjaro / EndeavourOS installer (pacman)
```

Each script is fully standalone — no shared library. The three scripts share ~90% of their logic (SSH keys, API key prompt, doghouse clone, Claude install, verify). Only the package-manager and shell-detection steps differ.

Refactoring into a shared `lib/` is future work once a fourth platform or CI test harness arrives.

## Troubleshooting

If the script fails partway through, just re-run it. Every step detects "already done" and skips.

If the SSH deploy key step fails repeatedly, double-check:
- The public key was copied and pasted exactly (no trailing whitespace, no line breaks inside the key material)
- It was added to the `doghouse` repo's **Deploy keys** section (not the org-wide SSH keys)
- The key's status in GitHub settings is "active"

Claude's own debug logs live in `~/.claude/debug/`.
