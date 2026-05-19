# Architecture

`nvim-context-mcp` is a read-only bridge between an MCP client and one or more live Neovim instances.

```text
Codex / Claude Code
  stdio MCP
    |
    v
nvim-context-mcp Rust binary
    |
    v
/tmp/nvim-context-mcp-<uid>/instances/<pid>.sock
    |
    v
Neovim Lua plugin
```

## Components

The Neovim plugin runs inside each Neovim instance and serves a tiny JSON-RPC-like protocol over a local Unix socket.

The Rust binary is the MCP server. It is launched by the client over stdio, reads registry files written by the Neovim plugin, chooses an instance, forwards read-only requests to the socket, and wraps the response as MCP content.

The registry is file based. Each Neovim instance writes an instance record under the state directory so the MCP server can discover live editors without a daemon.

## MCP Surface

The MCP server exposes these resources:

- `nvim://instances`
- `nvim://current`
- `nvim://instances/{instanceId}`

The MCP server exposes these tools:

- `nvim_list_instances`
- `nvim_get_visible_context`
- `nvim_list_buffers`
- `nvim_get_buffer_text`
- `nvim_get_diagnostics`

It does not expose edit, command, shell, or remote-control tools.

## Context Tools

`nvim_get_visible_context` returns the current tabs, windows, visible ranges, and bounded visible text.

`nvim_list_buffers` returns buffer metadata only: buffer number, path, filetype, modified/listed/loaded state, and line count. It does not include buffer text.

`nvim_get_buffer_text` returns text from one loaded buffer. Pass `bufnr` or `path`, plus `startLine`, `endLine`, `maxLines`, or `maxBytes` to keep the result small. If no buffer is specified, it reads the current buffer.

`nvim_get_diagnostics` returns current `vim.diagnostic` messages for one buffer when `bufnr` or `path` is provided.
If no buffer is specified, it returns diagnostics for all loaded buffers, bounded by `maxDiagnostics`.
Pass `severity` to filter to `ERROR`, `WARN`, `INFO`, or `HINT`.

The tools are intentionally pull-based to avoid filling the agent context with unneeded editor state. A client can list buffers first, inspect visible windows, and then request text or diagnostics for only the relevant buffer and line range.

## State Directory

By default, instance registry files and sockets live under:

```text
/tmp/nvim-context-mcp-<uid>/instances/
```

The Neovim plugin creates the state directory and instances directory with `0700` permissions.

Override with:

```bash
export NVIM_CONTEXT_MCP_STATE_DIR=/custom/state/dir
```

Use the same value for Neovim and the MCP server if you override it.

## Naming

`nvim-context-mcp` is intentionally explicit:

- `nvim`: clear ecosystem signal
- `context`: describes the primary value, not just the transport
- `mcp`: makes the integration protocol obvious

The tradeoff is that it is protocol-oriented. Good alternatives if the project positioning changes include `nvim-visible-mcp`, `mcp-neovim-context`, `nvim-lens-mcp`, or `neovim-readonly-mcp`.

This repo uses `nvim-context-mcp` because the user-facing value is editor context, while the implementation keeps the MCP surface read-only.
