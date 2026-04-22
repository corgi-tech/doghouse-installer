# doghouse-installer

One-shot bootstrap that sets up **Claude Code + doghouse** on a fresh machine.

Each supported platform has its own installer script in a dedicated subdirectory.

## Quick install

Pick the command for your platform, paste it into a terminal, follow the prompts.

### Ubuntu / WSL

```bash
curl -fsSL https://raw.githubusercontent.com/corgi-tech/doghouse-installer/main/ubuntu/install.sh -o /tmp/install.sh && bash /tmp/install.sh
```

### macOS *(coming soon)*

```bash
# Not yet available
```

### Arch / Manjaro *(coming soon)*

```bash
# Not yet available
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
- **macOS**: (TBD — script not yet written)
- **Arch / Manjaro**: (TBD — script not yet written)

## Repository layout

```
doghouse-installer/
├── README.md          ← this file
├── ubuntu/
│   └── install.sh     ← Ubuntu / WSL installer
├── macos/             ← (planned)
│   └── install.sh
└── arch/              ← (planned)
    └── install.sh
```

Shared logic may be factored out later once a second platform lands. For now each script is fully standalone.

## Troubleshooting

If the script fails partway through, just re-run it. Every step detects "already done" and skips.

If the SSH deploy key step fails repeatedly, double-check:
- The public key was copied and pasted exactly (no trailing whitespace, no line breaks inside the key material)
- It was added to the `doghouse` repo's **Deploy keys** section (not the org-wide SSH keys)
- The key's status in GitHub settings is "active"

Claude's own debug logs live in `~/.claude/debug/`.
