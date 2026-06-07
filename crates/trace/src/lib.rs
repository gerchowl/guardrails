//! guardrails-trace — the observability spine in one call.
//!
//! EnvFilter (RUST_LOG-style, runtime-configurable) + optional structured **JSONL** to a local file.
//! One mechanism, four payoffs: **debug** · **perf attribution** (spans) · **governance audit** ·
//! the **agentic-pane "full traces"** product feature. The JSONL file *is* the local, queryable
//! audit trail — never shipped off-box unless you export it.
//!
//! Level contract (see guardrails `docs/CONVENTIONS.md`) — **frequency dictates level**:
//! * `error` — a failure needing attention
//! * `warn`  — degraded but recovered
//! * `info`  — low-frequency lifecycle/operational events (NEVER per-iteration)
//! * `debug` — developer diagnosis
//! * `trace` — per-frame/-item firehose (+ spans/timings)
//!
//! Lean releases (Tier-1 of the compile-target split): set `tracing/release_max_level_info` in your
//! binary's Cargo.toml to *statically remove* `debug!`/`trace!` call sites in release — zero cost,
//! smaller binary — while keeping `info!`/`warn!`/`error!` for production observability.

pub use tracing::{self, debug, error, info, instrument, trace, warn, Level};
pub use tracing::{debug_span, error_span, info_span, trace_span, warn_span};

use std::path::Path;
use tracing_subscriber::{fmt, prelude::*, EnvFilter};

/// Level from `RUST_LOG`, defaulting to `info` (the right production floor).
fn env_filter() -> EnvFilter {
    EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"))
}

/// Minimal init: human-readable logs to stderr, level from `RUST_LOG` (default `info`).
/// Uses `try_init`, so a double call is a harmless no-op.
pub fn init() {
    let _ = tracing_subscriber::registry()
        .with(env_filter())
        .with(fmt::layer().with_target(false))
        .try_init();
}

/// Full spine: stderr (human) **plus** structured JSONL appended to `path` — the local audit trail /
/// agentic-pane trace. Returns a `WorkerGuard`; **keep it alive** for the process lifetime (dropping
/// it flushes the non-blocking writer). Returns `None` only if `path` has no file name.
#[must_use = "keep the WorkerGuard alive or buffered events are dropped on exit"]
pub fn init_jsonl(path: impl AsRef<Path>) -> Option<tracing_appender::non_blocking::WorkerGuard> {
    let path = path.as_ref();
    let dir = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let file = path.file_name()?;
    let (writer, guard) = tracing_appender::non_blocking(tracing_appender::rolling::never(dir, file));
    let _ = tracing_subscriber::registry()
        .with(env_filter())
        .with(fmt::layer().with_target(false))
        .with(fmt::layer().json().with_writer(writer))
        .try_init();
    Some(guard)
}

#[cfg(test)]
mod tests {
    #[test]
    fn jsonl_captures_structured_events() {
        let path = std::env::temp_dir().join("guardrails_trace_smoke.jsonl");
        let _ = std::fs::remove_file(&path);
        {
            let _guard = super::init_jsonl(&path).expect("init_jsonl");
            super::info!(kind = "smoke", n = 3, "hello from guardrails-trace");
        } // guard drops → flush
        let s = std::fs::read_to_string(&path).unwrap_or_default();
        assert!(s.contains("hello from guardrails-trace"), "missing message: {s}");
        assert!(s.contains("\"level\"") && s.contains("\"kind\""), "not structured JSON: {s}");
    }
}
