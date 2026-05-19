use serde::Deserialize;
use serde::Serialize;
use serde::de::DeserializeOwned;
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

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InstanceParams {
    instance_id: Option<String>,
}

#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct BufferTextParams {
    instance_id: Option<String>,
    bufnr: Option<u64>,
    path: Option<String>,
    start_line: Option<u64>,
    end_line: Option<u64>,
    max_lines: Option<u64>,
    max_bytes: Option<u64>,
}

#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct DiagnosticsParams {
    instance_id: Option<String>,
    bufnr: Option<u64>,
    path: Option<String>,
    max_diagnostics: Option<u64>,
    severity: Option<String>,
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
            read_only_tool(
                "nvim_list_instances",
                "List live Neovim instances registered by the read-only plugin.",
                json!({})
            ),
            read_only_tool(
                "nvim_get_visible_context",
                "Get visible windows from the most recent Neovim instance, or a specific instance.",
                instance_properties()
            ),
            read_only_tool(
                "nvim_list_buffers",
                "List Neovim buffers with metadata only. Does not include buffer text.",
                instance_properties()
            ),
            read_only_tool(
                "nvim_get_buffer_text",
                "Get text from one loaded Neovim buffer. Use nvim_list_buffers first, then request a bounded line range when possible.",
                json!({
                    "instanceId": instance_id_property(),
                    "bufnr": integer_property("Buffer number. Defaults to the current buffer when omitted."),
                    "path": string_property("Buffer path. Used only when bufnr is omitted."),
                    "startLine": bounded_integer_property("1-based first line to return."),
                    "endLine": bounded_integer_property("1-based last line to return."),
                    "maxLines": bounded_integer_property("Maximum number of lines to return."),
                    "maxBytes": bounded_integer_property("Maximum bytes of text to return.")
                })
            ),
            read_only_tool(
                "nvim_get_diagnostics",
                "Get current Neovim diagnostics for one buffer, or all loaded buffers if no buffer is specified.",
                json!({
                    "instanceId": instance_id_property(),
                    "bufnr": integer_property("Buffer number. Defaults to all loaded buffers when omitted."),
                    "path": string_property("Buffer path. Used only when bufnr is omitted."),
                    "maxDiagnostics": bounded_integer_property("Maximum number of diagnostics to return."),
                    "severity": string_property("Optional severity filter: ERROR, WARN, INFO, or HINT.")
                })
            )
        ]
    })
}

fn read_only_tool(name: &str, description: &str, properties: Value) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        },
        "annotations": {
            "readOnlyHint": true
        }
    })
}

fn instance_properties() -> Value {
    json!({
        "instanceId": instance_id_property()
    })
}

fn instance_id_property() -> Value {
    string_property("Optional Neovim instance ID or pid.")
}

fn string_property(description: &str) -> Value {
    json!({
        "type": "string",
        "description": description
    })
}

fn integer_property(description: &str) -> Value {
    json!({
        "type": "integer",
        "description": description
    })
}

fn bounded_integer_property(description: &str) -> Value {
    json!({
        "type": "integer",
        "minimum": 1,
        "description": description
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
            let params: InstanceParams = decode_args(arguments)?;
            visible_context(params.instance_id.as_deref()).await?
        }
        "nvim_list_buffers" => {
            let params: InstanceParams = decode_args(arguments)?;
            nvim_context(params.instance_id.as_deref(), "buffers", Value::Null).await?
        }
        "nvim_get_buffer_text" => {
            let params: BufferTextParams = decode_args(arguments)?;
            let instance_id = params.instance_id.clone();
            nvim_context(
                instance_id.as_deref(),
                "buffer_text",
                serde_json::to_value(params)?,
            )
            .await?
        }
        "nvim_get_diagnostics" => {
            let params: DiagnosticsParams = decode_args(arguments)?;
            let instance_id = params.instance_id.clone();
            nvim_context(
                instance_id.as_deref(),
                "diagnostics",
                serde_json::to_value(params)?,
            )
            .await?
        }
        other => anyhow::bail!("unknown tool: {other}"),
    };

    tool_response(value)
}

fn decode_args<T>(arguments: Value) -> anyhow::Result<T>
where
    T: Default + DeserializeOwned,
{
    if arguments.is_null() {
        return Ok(T::default());
    }

    serde_json::from_value(arguments).map_err(Into::into)
}

fn tool_response(value: Value) -> anyhow::Result<Value> {
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
    nvim_context(instance_id, "visible_context", Value::Null).await
}

async fn nvim_context(
    instance_id: Option<&str>,
    method: &str,
    params: Value,
) -> anyhow::Result<Value> {
    let Some(instance) = registry::find_instance(instance_id).await? else {
        return Ok(json!({
            "instances": [],
            "message": "No live Neovim instances registered."
        }));
    };

    nvim::call(&instance, method, params).await
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn diagnostics_schema_includes_bounds_and_filter() {
        let tools = tools_list();
        let diagnostics_tool = tools["tools"]
            .as_array()
            .unwrap()
            .iter()
            .find(|tool| tool["name"] == "nvim_get_diagnostics")
            .unwrap();
        let properties = &diagnostics_tool["inputSchema"]["properties"];

        assert_eq!(properties["maxDiagnostics"]["minimum"], 1);
        assert_eq!(properties["severity"]["type"], "string");
    }

    #[test]
    fn decodes_diagnostics_bounds_and_filter() {
        let params: DiagnosticsParams = decode_args(json!({
            "instanceId": "host:42",
            "bufnr": 7,
            "maxDiagnostics": 3,
            "severity": "WARN"
        }))
        .unwrap();

        assert_eq!(params.instance_id.as_deref(), Some("host:42"));
        assert_eq!(params.bufnr, Some(7));
        assert_eq!(params.max_diagnostics, Some(3));
        assert_eq!(params.severity.as_deref(), Some("WARN"));
    }
}
