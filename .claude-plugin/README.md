# Claude Code Integration

Claude Code can use this repository through its MCP configuration. Build or
install the `nvim-context-mcp` binary, start Neovim with the Lua plugin enabled,
then add an MCP server entry that runs:

```json
{
  "mcpServers": {
    "nvim-context-mcp": {
      "command": "nvim-context-mcp"
    }
  }
}
```

This directory is intentionally documentation-only for now. The integration
surface is the MCP server; no editor-control tools are exposed.
