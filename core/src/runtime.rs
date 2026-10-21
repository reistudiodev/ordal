//! The core's single Tokio runtime. Exported async functions hand their work
//! to it, so database I/O never runs on the caller's executor or the UI thread,
//! whichever platform is calling.

use std::future::Future;
use std::sync::LazyLock;

use crate::error::{CoreError, Result};

static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .thread_name("dbclient-core")
        .enable_all()
        .build()
        .expect("failed to start the Tokio runtime")
});

pub(crate) fn handle() -> &'static tokio::runtime::Handle {
    RUNTIME.handle()
}

/// Runs `fut` on the core runtime and waits for it from any executor.
pub(crate) async fn run<F, T>(fut: F) -> Result<T>
where
    F: Future<Output = Result<T>> + Send + 'static,
    T: Send + 'static,
{
    handle()
        .spawn(fut)
        .await
        .map_err(|e| CoreError::internal(format!("background task failed: {e}")))?
}
