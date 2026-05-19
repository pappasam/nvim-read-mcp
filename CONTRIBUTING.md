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

## Commit Style

Group changes by behavior. For example, keep a new MCP tool and its Rust/Lua/docs changes together, but put independent cleanup in a separate commit.

Use concise imperative commit messages, such as `Add buffer diagnostics tool` or `Document state directory behavior`.
