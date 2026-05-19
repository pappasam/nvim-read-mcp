use std::time::Duration;

use serde_json::Value;
use serde_json::json;
use tokio::io::AsyncBufReadExt;
use tokio::io::AsyncWriteExt;
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::time::timeout;

use crate::registry::InstanceRecord;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(2);

pub async fn call(instance: &InstanceRecord, method: &str, params: Value) -> anyhow::Result<Value> {
    let socket_path = instance.socket_path.clone();
    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });

    timeout(REQUEST_TIMEOUT, async move {
        let mut stream = UnixStream::connect(socket_path).await?;
        stream.write_all(request.to_string().as_bytes()).await?;
        stream.write_all(b"\n").await?;
        stream.shutdown().await?;

        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).await?;
        let response: Value = serde_json::from_str(&line)?;
        if let Some(error) = response.get("error") {
            anyhow::bail!("Neovim RPC error: {error}");
        }

        Ok(response.get("result").cloned().unwrap_or(Value::Null))
    })
    .await?
}
