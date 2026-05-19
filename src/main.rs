mod mcp;
mod nvim;
mod protocol;
mod registry;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    mcp::run_stdio_server().await
}
