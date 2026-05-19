use std::path::PathBuf;
use std::time::Duration;
use std::time::SystemTime;
use std::time::UNIX_EPOCH;

use serde::Deserialize;
use serde::Serialize;

const STALE_AFTER: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstanceRecord {
    pub schema_version: u32,
    pub source: String,
    pub instance_id: String,
    pub pid: u32,
    pub host: String,
    pub cwd: String,
    pub socket_path: String,
    pub updated_at: i64,
    pub active_path: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstanceSummary {
    #[serde(flatten)]
    pub record: InstanceRecord,
    pub age_ms: u64,
    pub stale: bool,
}

pub fn state_dir() -> PathBuf {
    if let Ok(path) = std::env::var("NVIM_CONTEXT_MCP_STATE_DIR") {
        return PathBuf::from(path);
    }

    if let Ok(path) = std::env::var("NVIM_READ_MCP_STATE_DIR") {
        return PathBuf::from(path);
    }

    if let Some(path) = std::env::var_os("XDG_STATE_HOME") {
        return PathBuf::from(path).join("nvim-context-mcp");
    }

    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".local/state/nvim-context-mcp")
}

pub async fn list_instances() -> anyhow::Result<Vec<InstanceSummary>> {
    let dir = state_dir().join("instances");
    let mut read_dir = match tokio::fs::read_dir(&dir).await {
        Ok(read_dir) => read_dir,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(err) => return Err(err.into()),
    };

    let now = unix_seconds();
    let mut instances = Vec::new();
    while let Some(entry) = read_dir.next_entry().await? {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }

        let contents = match tokio::fs::read_to_string(&path).await {
            Ok(contents) => contents,
            Err(_) => continue,
        };
        let record: InstanceRecord = match serde_json::from_str(&contents) {
            Ok(record) => record,
            Err(_) => continue,
        };
        if record.schema_version != 1 || record.source != "nvim-context-mcp" {
            continue;
        }

        let age_ms = now
            .saturating_sub(record.updated_at)
            .try_into()
            .unwrap_or(0_u64)
            * 1000;
        instances.push(InstanceSummary {
            stale: Duration::from_millis(age_ms) > STALE_AFTER,
            record,
            age_ms,
        });
    }

    instances.sort_by(|left, right| right.record.updated_at.cmp(&left.record.updated_at));
    Ok(instances)
}

pub async fn find_instance(instance_id: Option<&str>) -> anyhow::Result<Option<InstanceRecord>> {
    let instances = list_instances().await?;
    let selected = if let Some(instance_id) = instance_id {
        instances
            .into_iter()
            .find(|entry| {
                entry.record.instance_id == instance_id
                    || entry.record.pid.to_string() == instance_id
            })
            .map(|entry| entry.record)
    } else {
        instances
            .into_iter()
            .find(|entry| !entry.stale)
            .map(|entry| entry.record)
    };

    Ok(selected)
}

fn unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .try_into()
        .unwrap_or(i64::MAX)
}
