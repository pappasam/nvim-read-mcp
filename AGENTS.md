# AGENTS.md

This is a read-only MCP bridge for live Neovim context.

Before changing behavior, read:

- `README.md` for setup and user-facing usage
- `ARCHITECTURE.md` for the runtime model, MCP surface, state directory behavior, and read-only boundary
- `CONTRIBUTING.md` for development workflow and documentation expectations

Keep Rust changes focused around the existing module boundaries in `src/`.

Keep Lua plugin changes focused in `lua/nvim_context_mcp/init.lua` unless the plugin grows enough to justify splitting modules.

When editing Markdown, do not hard-wrap prose lines. Preserve soft-wrapped paragraphs unless a list, table, code block, or existing local structure requires line breaks.

Preserve the read-only security posture. New tools should expose editor context, not editor mutation, shell commands, arbitrary Lua execution, or remote-control behavior.

Run the full local validation with:

```sh
make tests
```

Use narrower targets only when they match the change:

- `make lint` for Rust formatting and compile checks
- `make lua-smoke` for a headless Neovim plugin smoke test
- `make fix` before committing Rust formatting changes

Prefer pull-based context APIs. Add metadata/listing tools before adding bulk text output, and make text-producing tools accept bounds such as line ranges, `maxLines`, or `maxBytes`.
