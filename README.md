# nvim-context-mcp

Read-only MCP bridge for live Neovim context.

This repository is both:

- a Neovim plugin, via `lua/nvim_context_mcp/init.lua`
- an MCP server for Codex and Claude Code, via the Rust `nvim-context-mcp` binary
- a Codex plugin package, via `.codex-plugin/plugin.json` and `.mcp.json`

The Neovim plugin runs inside each Neovim instance and listens on a local Unix socket for a tiny read-only JSON protocol. The Rust binary is the MCP server that Codex or Claude launches over stdio. It discovers live Neovim instances, connects to the most recently active one, and exposes visible editor context.

## Naming

`nvim-context-mcp` is a solid working name because it is explicit:

- `nvim`: clear ecosystem signal
- `context`: describes the primary value, not just the transport
- `mcp`: makes the integration protocol obvious

The tradeoff is that it is still protocol-oriented. Good alternatives if the project positioning changes:

- `nvim-visible-mcp`: best if the product promise is exactly "what is visible"
- `mcp-neovim-context`: more discoverable for people searching MCP servers
- `nvim-lens-mcp`: shorter, nicer, but less literal
- `neovim-readonly-mcp`: very clear security posture, but longer

This repo uses `nvim-context-mcp` because the user-facing value is editor context; the implementation still keeps the MCP surface read-only.

## Architecture

```text
Codex / Claude Code
  stdio MCP
    |
    v
nvim-context-mcp Rust binary
    |
    v
~/.local/state/nvim-context-mcp/instances/<pid>.sock
    |
    v
Neovim Lua plugin
```

The MCP server exposes:

- `nvim://instances`
- `nvim://current`
- `nvim://instances/{instanceId}`
- tool: `nvim_list_instances`
- tool: `nvim_get_visible_context`
- tool: `nvim_list_buffers`
- tool: `nvim_get_buffer_text`
- tool: `nvim_get_diagnostics`

It does not expose edit, command, shell, or remote-control tools.

The tools are intentionally pull-based to avoid filling the agent context with
unneeded editor state. A client can list buffers first, inspect visible windows,
and then request text or diagnostics for only the relevant buffer and line range.

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
})
```

## Context Tools

`nvim_get_visible_context` returns the current tabs, windows, visible ranges, and
bounded visible text.

`nvim_list_buffers` returns buffer metadata only: buffer number, path, filetype,
modified/listed/loaded state, and line count. It does not include buffer text.

`nvim_get_buffer_text` returns text from one loaded buffer. Pass `bufnr` or
`path`, plus `startLine`, `endLine`, `maxLines`, or `maxBytes` to keep the result
small. If no buffer is specified, it reads the current buffer.

`nvim_get_diagnostics` returns current `vim.diagnostic` messages for one buffer
when `bufnr` or `path` is provided. If no buffer is specified, it returns
diagnostics for all loaded buffers.

## Codex

After the binary is on `PATH`:

```bash
codex mcp add nvim-context-mcp -- nvim-context-mcp
```

This repo also includes `.codex-plugin/plugin.json` and `.mcp.json` so it can be packaged as a Codex plugin.

## Claude Code

Add the MCP server to Claude Code with the command:

```json
{
  "mcpServers": {
    "nvim-context-mcp": {
      "command": "nvim-context-mcp"
    }
  }
}
```

## State Directory

By default, instance registry files and sockets live under:

```text
~/.local/state/nvim-context-mcp/instances/
```

Override with:

```bash
export NVIM_CONTEXT_MCP_STATE_DIR=/custom/state/dir
```

Use the same value for Neovim and the MCP server if you override it.
