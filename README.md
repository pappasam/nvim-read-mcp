# nvim-context-mcp

[![Testing](https://github.com/pappasam/nvim-context-mcp/actions/workflows/testing.yml/badge.svg?branch=main)](https://github.com/pappasam/nvim-context-mcp/actions/workflows/testing.yml?query=branch%3Amain)

Read-only MCP bridge for live Neovim context.

This repository provides:

- a Neovim plugin, via `lua/nvim_context_mcp/init.lua`
- an MCP server for Codex and Claude Code, via the Rust `nvim-context-mcp` binary
- plugin packaging metadata for Codex and Claude Code, via `.codex-plugin/`, `.claude-plugin/`, and `.mcp.json`

The Neovim plugin runs inside each Neovim instance and listens on a local Unix socket for a small read-only JSON protocol. The Rust binary is the MCP server that an agent launches over stdio. It discovers live Neovim instances, connects to the most recently active one, and exposes editor context without edit, command, shell, or remote-control tools.

## Documentation

- [Architecture](ARCHITECTURE.md) describes the runtime model, MCP resources, tools, state directory, and read-only boundaries.
- [Contributing](CONTRIBUTING.md) covers local setup, development workflow, checks, and release notes for contributors.

## Install

Install the MCP server binary, then load the Neovim plugin.

### Pre-Built Binary

Download the archive for your platform from the [GitHub releases](https://github.com/pappasam/nvim-context-mcp/releases) page.

Linux and macOS archives are named like:

```text
nvim-context-mcp-v0.1.0-x86_64-unknown-linux-gnu.tar.gz
nvim-context-mcp-v0.1.0-x86_64-apple-darwin.tar.gz
nvim-context-mcp-v0.1.0-aarch64-apple-darwin.tar.gz
```

Windows archives are named like:

```text
nvim-context-mcp-v0.1.0-x86_64-pc-windows-msvc.zip
```

To install manually on Linux or macOS:

```bash
version=v0.1.0
target=x86_64-unknown-linux-gnu
curl -LO "https://github.com/pappasam/nvim-context-mcp/releases/download/${version}/nvim-context-mcp-${version}-${target}.tar.gz"
tar -xzf "nvim-context-mcp-${version}-${target}.tar.gz"
install -d ~/.local/bin
install -m 0755 "nvim-context-mcp-${version}-${target}/nvim-context-mcp" ~/.local/bin/nvim-context-mcp
```

Verify the archive checksum with the `SHA256SUMS` file attached to the same release:

```bash
curl -LO "https://github.com/pappasam/nvim-context-mcp/releases/download/${version}/SHA256SUMS"
sha256sum --check --ignore-missing SHA256SUMS
```

On macOS, use `shasum -a 256` to compare the downloaded archive against `SHA256SUMS`.

If you use [mise-en-place](https://mise.jdx.dev/), install from GitHub releases with the `github` backend:

```bash
mise use -g github:pappasam/nvim-context-mcp
```

Pin a specific release with:

```bash
mise use -g github:pappasam/nvim-context-mcp@0.1.0
```

### From Source

Build the MCP server:

```bash
cargo install --path .
```

### Neovim Plugin

Load the Neovim plugin with your plugin manager, or add this repo to `runtimepath` and call:

```lua
require("nvim_context_mcp").setup()
```

Optional configuration:

```lua
require("nvim_context_mcp").setup({
  -- Defaults to /tmp/nvim-context-mcp-<uid>.
  state_dir = "/custom/state/dir",
  include_visible_text = true,
  include_terminal_buffers = false,
  max_lines_per_window = 200,
  max_bytes_per_window = 20000,
  max_lines_per_buffer = 1000,
  max_bytes_per_buffer = 100000,
  max_diagnostics = 1000,
})
```

## Codex

After the binary is on `PATH`:

```bash
codex mcp add nvim-context-mcp -- nvim-context-mcp
```

This repo also includes `.codex-plugin/plugin.json` and `.mcp.json` so it can be packaged as a Codex plugin.

## Claude Code

Add the MCP server to Claude Code with this MCP server entry:

```json
{
  "mcpServers": {
    "nvim-context-mcp": {
      "command": "nvim-context-mcp"
    }
  }
}
```
