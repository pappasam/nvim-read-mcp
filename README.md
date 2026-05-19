# nvim-context-mcp

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

Build the MCP server:

```bash
cargo install --path .
```

Load the Neovim plugin with your plugin manager, or add this repo to `runtimepath` and call:

```lua
require("nvim_context_mcp").setup()
```

Optional configuration:

```lua
require("nvim_context_mcp").setup({
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
