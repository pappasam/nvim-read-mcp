# Contributing

This project has two runtime pieces: Rust for the MCP stdio server and Lua for the Neovim-side plugin.

## Local Setup

Build the MCP server from the repository root:

```bash
cargo build
```

Install it onto your `PATH` when you want to exercise it from an MCP client:

```bash
cargo install --path .
```

Load the Lua plugin in Neovim with your plugin manager, or temporarily add the repository to `runtimepath` and call:

```lua
require("nvim_context_mcp").setup()
```

If you use Neovim 0.13 nightly and the built-in `vim.pack` plugin manager, install this local checkout from your `init.lua`:

```lua
vim.pack.add({
  {
    src = "/path/to/nvim-context-mcp",
    name = "nvim-context-mcp",
  },
}, { confirm = false })

require("nvim_context_mcp").setup()
```

`vim.pack` manages its own plugin checkout under your package directory. When you are actively editing this repository and want Neovim to load these files directly without reinstalling the package, prepend the checkout to `runtimepath` instead:

```lua
vim.opt.runtimepath:prepend("/path/to/nvim-context-mcp")
require("nvim_context_mcp").setup()
```

## End-to-End Local Testing

Start with the automated checks:

```bash
make tests
```

Then install the MCP server binary that Codex or Claude Code will launch:

```bash
cargo install --path .
command -v nvim-context-mcp
```

If you prefer not to install while iterating, build the debug binary and point the MCP client at the absolute path to `target/debug/nvim-context-mcp`:

```bash
cargo build
```

Start Neovim with the plugin enabled, then open a real project file. The plugin writes instance records and sockets under `/tmp/nvim-context-mcp-<uid>/instances/` by default. You can verify the Lua side from inside Neovim with:

```vim
:lua print(vim.inspect(require("nvim_context_mcp").visible_context()))
```

For an isolated test state directory, use the same `NVIM_CONTEXT_MCP_STATE_DIR` value for Neovim and the MCP client process. This is useful when you have more than one Neovim instance running:

```bash
export NVIM_CONTEXT_MCP_STATE_DIR=/tmp/nvim-context-mcp-e2e
```

### Codex

With `nvim-context-mcp` installed on `PATH`, register the local MCP server:

```bash
codex mcp add nvim-context-mcp -- nvim-context-mcp
```

To test an uninstalled debug build instead, register the absolute binary path:

```bash
codex mcp add nvim-context-mcp -- /path/to/nvim-context-mcp/target/debug/nvim-context-mcp
```

Restart Codex after changing MCP configuration. With Neovim still running, ask Codex to inspect the Neovim context or explicitly call the `nvim_list_instances`, `nvim_get_visible_context`, `nvim_list_buffers`, `nvim_get_buffer_text`, or `nvim_get_diagnostics` MCP tools.

### Claude Code

Claude Code can use the same stdio MCP server command. With the installed binary on `PATH`, add this MCP server entry:

```json
{
  "mcpServers": {
    "nvim-context-mcp": {
      "command": "nvim-context-mcp"
    }
  }
}
```

For an uninstalled debug build, use the absolute binary path:

```json
{
  "mcpServers": {
    "nvim-context-mcp": {
      "command": "/path/to/nvim-context-mcp/target/debug/nvim-context-mcp"
    }
  }
}
```

Restart Claude Code after changing MCP configuration. With Neovim still running, ask Claude Code to list live Neovim instances or read the visible buffer context.

## Development Workflow

Keep Rust changes focused around the existing module boundaries:

- `src/main.rs` starts the stdio MCP server.
- `src/mcp.rs` owns MCP method dispatch, resource responses, tool schemas, and tool calls.
- `src/nvim.rs` owns the Unix socket request to a Neovim instance.
- `src/registry.rs` owns state directory selection and instance discovery.
- `src/protocol.rs` owns the small JSON-RPC envelope types used by the stdio server.

Keep Lua changes focused in `lua/nvim_context_mcp/init.lua` unless the plugin grows enough to justify splitting modules.

Preserve the read-only security posture. New tools should expose editor context, not editor mutation, shell commands, arbitrary Lua execution, or remote-control behavior.

Prefer pull-based context APIs. Add metadata/listing tools before adding bulk text output, and make text-producing tools accept bounds such as line ranges, `maxLines`, or `maxBytes`.

## Checks

Before committing Rust changes, run:

```bash
make tests
```

Use `make lint` for Rust formatting and compile checks, `make lua-smoke` for the headless Neovim plugin smoke test, and `make fix` to format Rust files in-place.

There is currently no dedicated Lua unit test harness. For deeper Lua changes, also start Neovim with the plugin enabled and exercise the affected MCP method through the Rust server or by calling the module functions directly in Neovim.

## Documentation

Update `README.md` when setup or user-facing usage changes.

Update `ARCHITECTURE.md` when the runtime model, MCP resources, tools, state directory behavior, or security boundary changes.

Keep Markdown prose soft-wrapped rather than hard-wrapped. Prefer one sentence or paragraph per line when practical so diffs stay clean.

## Releases

GitHub releases include pre-built MCP server binaries as release assets. The release workflow runs when a GitHub release is published, builds supported platform binaries from the release tag, packages each binary with `README.md` and `LICENSE`, generates `SHA256SUMS`, and attaches all files to the GitHub release.

Publish a release with:

```bash
make release VERSION=0.1.0
```

Use concise release notes that mention user-facing changes and any compatibility notes.

## Commit Style

Group changes by behavior. For example, keep a new MCP tool and its Rust/Lua/docs changes together, but put independent cleanup in a separate commit.

Use concise imperative commit messages, such as `Add buffer diagnostics tool` or `Document state directory behavior`.
