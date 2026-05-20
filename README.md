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

Install the Neovim plugin from a release tag. On first startup, the plugin downloads the matching MCP server binary from the same GitHub release, verifies its checksum, installs it under Neovim's data directory, and exposes it as `nvim-context-mcp` through `~/.local/bin` when possible.

```lua
vim.pack.add({
  {
    src = "https://github.com/pappasam/nvim-context-mcp",
    name = "nvim-context-mcp",
    version = vim.version.range("*"),
  },
}, { confirm = false })

require("nvim_context_mcp").setup()
```

Then install the Codex or Claude Code plugin below. The agent plugin starts `nvim-context-mcp` automatically, while the Neovim plugin owns the matching binary.

Check the managed binary status from Neovim with:

```vim
:NvimContextMcp status
```

Install or repair the managed binary explicitly with:

```vim
:NvimContextMcp install
```

Optional binary configuration:

```lua
require("nvim_context_mcp").setup({
  binary = {
    auto_install = true,
    expose_on_path = true,
    bin_dir = vim.fn.expand("~/.local/bin"),
  },
})
```

When upgrading, update the Neovim package with `:PackUpdate nvim-context-mcp`. The next Neovim startup downloads the matching MCP server binary for the new plugin release.

### Manual Binary Install

Download the archive for your platform from the [GitHub releases](https://github.com/pappasam/nvim-context-mcp/releases) page.

Linux and macOS archives are named like:

```text
nvim-context-mcp-<version>-x86_64-unknown-linux-gnu.tar.gz
nvim-context-mcp-<version>-aarch64-unknown-linux-gnu.tar.gz
nvim-context-mcp-<version>-aarch64-apple-darwin.tar.gz
```

To install manually on Linux or macOS:

```bash
version=<latest-release-tag>
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
mise use -g github:pappasam/nvim-context-mcp@latest
```

### From Source

Build the MCP server:

```bash
cargo install --path .
```

### Neovim Plugin

Load the Neovim plugin with your plugin manager, tracking the same release stream as the MCP server binary. If you are actively developing from a local checkout, add that checkout to `runtimepath` instead:

```lua
vim.opt.runtimepath:prepend("/path/to/nvim-context-mcp")
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
  binary = {
    auto_install = true,
    expose_on_path = true,
    bin_dir = vim.fn.expand("~/.local/bin"),
  },
})
```

## Codex

Install the Codex plugin instead of adding the MCP server by hand. The plugin declares this repo's `.mcp.json`, so Codex starts the MCP server automatically when the plugin is enabled. Neovim still needs to load the Lua plugin as shown above; the Lua plugin downloads the matching `nvim-context-mcp` binary and exposes it on `PATH` when possible.

```bash
codex plugin marketplace add pappasam/nvim-context-mcp
codex plugin add nvim-context-mcp@nvim-context-mcp
```

For a local checkout:

```bash
codex plugin marketplace add /path/to/nvim-context-mcp
codex plugin add nvim-context-mcp@nvim-context-mcp
```

After installing the Codex plugin, restart Codex, start Neovim with `require("nvim_context_mcp").setup()` configured, then ask Codex to inspect the visible Neovim context. If Codex cannot find `nvim-context-mcp`, run `:NvimContextMcp status` in Neovim and make sure the reported link directory is on your shell `PATH`.

The equivalent raw MCP command, if you need to debug the plugin, is:

```bash
codex mcp add nvim-context-mcp -- nvim-context-mcp
```

This repo includes `.agents/plugins/marketplace.json` and `plugins/nvim-context-mcp/` so it can be installed as a Codex plugin.

## Claude Code

Install the Claude Code plugin instead of editing `settings.json` by hand. The plugin declares this repo's `.mcp.json`, so Claude Code starts the MCP server automatically when the plugin is enabled. Neovim still needs to load the Lua plugin as shown above; the Lua plugin downloads the matching `nvim-context-mcp` binary and exposes it on `PATH` when possible.

From inside Claude Code:

```bash
/plugin marketplace add pappasam/nvim-context-mcp
/plugin install nvim-context-mcp@nvim-context-mcp
/reload-plugins
```

Or use the non-interactive CLI:

```bash
claude plugin marketplace add pappasam/nvim-context-mcp
claude plugin install nvim-context-mcp@nvim-context-mcp
```

For a local checkout, load the plugin directly for one Claude Code session:

```bash
claude --plugin-dir /path/to/nvim-context-mcp
```

After installing or loading the Claude Code plugin, start Neovim with `require("nvim_context_mcp").setup()` configured, then ask Claude Code to list live Neovim instances or read the visible buffer context. If Claude Code cannot find `nvim-context-mcp`, run `:NvimContextMcp status` in Neovim and make sure the reported link directory is on your shell `PATH`.

The equivalent raw MCP configuration, if you need to debug the plugin, is:

```json
{
  "mcpServers": {
    "nvim-context-mcp": {
      "command": "nvim-context-mcp"
    }
  }
}
```

To avoid repeated Claude Code approval prompts with the plugin, add the exact tool allowlist to `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "mcp__plugin_nvim-context-mcp_nvim-context-mcp__nvim_list_instances",  
      "mcp__plugin_nvim-context-mcp_nvim-context-mcp__nvim_get_visible_context",
      "mcp__plugin_nvim-context-mcp_nvim-context-mcp__nvim_list_buffers",  
      "mcp__plugin_nvim-context-mcp_nvim-context-mcp__nvim_get_buffer_text",  
      "mcp__plugin_nvim-context-mcp_nvim-context-mcp__nvim_get_diagnostics",
    ]
  }
}
```

This explicit allowlist is narrower than allowing the whole MCP server and will not automatically approve future tools if the server grows. If you are comfortable auto-approving all current and future tools from this server, the broader rule is:

```json
{
  "permissions": {
    "allow": ["mcp__plugin_nvim-context-mcp_nvim-context-mcp__*"]
  }
}
```

After editing `settings.json`, restart Claude Code or use `/permissions` to verify that the new allow rules are loaded.
