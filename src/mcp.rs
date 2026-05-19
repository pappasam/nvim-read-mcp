use serde::Deserialize;
use serde_json::Value;
use serde_json::json;
use tokio::io::AsyncBufReadExt;
use tokio::io::AsyncWriteExt;
use tokio::io::BufReader;

use crate::nvim;
use crate::protocol::JsonRpcRequest;
use crate::protocol::JsonRpcResponse;
use crate::registry;

const SERVER_NAME: &str = "nvim-context-mcp";
const JSON_MIME: &str = "application/json";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InstanceParams {
    instance_id: Option<String>,
}

pub async fn run_stdio_server() -> anyhow::Result<()> {
    let stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();
    let mut lines = BufReader::new(stdin).lines();

    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }

        let response = match serde_json::from_str::<JsonRpcRequest>(&line) {
            Ok(request) => handle_request(request).await,
            Err(err) => JsonRpcResponse::error(None, -32700, format!("Parse error: {err}")),
        };

        if response.id.is_none() {
            continue;
        }

        stdout
            .write_all(serde_json::to_string(&response)?.as_bytes())
            .await?;
        stdout.write_all(b"\n").await?;
        stdout.flush().await?;
    }

    Ok(())
}

async fn handle_request(request: JsonRpcRequest) -> JsonRpcResponse {
    if request.jsonrpc.as_deref() != Some("2.0") {
        return JsonRpcResponse::error(request.id, -32600, "Expected JSON-RPC 2.0 request");
    }

    let id = request.id;
    let result = match request.method.as_str() {
        "initialize" => Ok(initialize_result()),
        "notifications/initialized" => return JsonRpcResponse::result(id, Value::Null),
        "resources/list" => list_resources().await,
        "resources/read" => read_resource(&request.params).await,
        "tools/list" => Ok(tools_list()),
        "tools/call" => call_tool(&request.params).await,
        _ => return JsonRpcResponse::error(id, -32601, "Method not found"),
    };

    match result {
        Ok(result) => JsonRpcResponse::result(id, result),
        Err(err) => JsonRpcResponse::error(id, -32603, err.to_string()),
    }
}

fn initialize_result() -> Value {
    json!({
        "protocolVersion": "2025-06-18",
        "serverInfo": {
            "name": SERVER_NAME,
            "version": env!("CARGO_PKG_VERSION")
        },
        "capabilities": {
            "resources": {},
            "tools": {}
        }
    })
}

async fn list_resources() -> anyhow::Result<Value> {
    let instances = registry::list_instances().await?;
    let mut resources = vec![
        json!({
            "uri": "nvim://instances",
            "name": "Neovim instances",
            "description": "Live Neovim instances registered by the nvim-context-mcp plugin.",
            "mimeType": JSON_MIME
        }),
        json!({
            "uri": "nvim://current",
            "name": "Current Neovim visible context",
            "description": "Visible context from the most recently active non-stale Neovim instance.",
            "mimeType": JSON_MIME
        }),
    ];

    for instance in instances {
        resources.push(json!({
            "uri": format!("nvim://instances/{}", instance.record.instance_id),
            "name": format!("Neovim {}", instance.record.instance_id),
            "description": instance.record.active_path.unwrap_or(instance.record.cwd),
            "mimeType": JSON_MIME
        }));
    }

    Ok(json!({ "resources": resources }))
}

async fn read_resource(params: &Value) -> anyhow::Result<Value> {
    let uri = params
        .get("uri")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("missing resource URI"))?;

    let value = match uri {
        "nvim://instances" => serde_json::to_value(registry::list_instances().await?)?,
        "nvim://current" => visible_context(None).await?,
        _ => {
            let instance_id = uri
                .strip_prefix("nvim://instances/")
                .ok_or_else(|| anyhow::anyhow!("unknown resource URI: {uri}"))?;
            visible_context(Some(instance_id)).await?
        }
    };

    Ok(json!({
        "contents": [{
            "uri": uri,
            "mimeType": JSON_MIME,
            "text": serde_json::to_string_pretty(&value)?
        }]
    }))
}

fn tools_list() -> Value {
    json!({
        "tools": [
            {
                "name": "nvim_list_instances",
                "description": "List live Neovim instances registered by the read-only plugin.",
                "inputSchema": {
                    "type": "object",
                    "properties": {},
                    "additionalProperties": false
                },
                "annotations": {
                    "readOnlyHint": true
                }
            },
            {
                "name": "nvim_get_visible_context",
                "description": "Get visible windows from the most recent Neovim instance, or a specific instance.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "instanceId": {
                            "type": "string",
                            "description": "Optional Neovim instance ID or pid."
                        }
                    },
                    "additionalProperties": false
                },
                "annotations": {
                    "readOnlyHint": true
                }
            }
        ]
    })
}

async fn call_tool(params: &Value) -> anyhow::Result<Value> {
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("missing tool name"))?;
    let arguments = params.get("arguments").cloned().unwrap_or(Value::Null);

    let value = match name {
        "nvim_list_instances" => serde_json::to_value(registry::list_instances().await?)?,
        "nvim_get_visible_context" => {
            let params: InstanceParams =
                serde_json::from_value(arguments).unwrap_or(InstanceParams { instance_id: None });
            visible_context(params.instance_id.as_deref()).await?
        }
        other => anyhow::bail!("unknown tool: {other}"),
    };

    Ok(json!({
        "content": [{
            "type": "text",
            "text": serde_json::to_string_pretty(&value)?
        }],
        "structuredContent": value,
        "isError": false
    }))
}

async fn visible_context(instance_id: Option<&str>) -> anyhow::Result<Value> {
    let Some(instance) = registry::find_instance(instance_id).await? else {
        return Ok(json!({
            "instances": [],
            "message": "No live Neovim instances registered."
        }));
    };

    nvim::call(&instance, "visible_context", Value::Null).await
}
