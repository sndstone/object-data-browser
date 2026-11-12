use crate::SidecarError;
use std::future::Future;
use tokio::task::JoinSet;

/// Backpressure applies before allocation, including completed but uncollected
/// tasks. Download ranges do not need an object-sized result/future vector.
pub async fn run_bounded<T, F, Fut, C>(
    count: u64,
    concurrency: usize,
    mut task: F,
    mut collect: C,
) -> Result<(), SidecarError>
where
    T: Send + 'static,
    F: FnMut(u64) -> Fut,
    Fut: Future<Output = Result<T, SidecarError>> + Send + 'static,
    C: FnMut(T),
{
    let limit = concurrency.max(1);
    let mut tasks = JoinSet::new();
    let mut next = 0;
    loop {
        while next < count && tasks.len() < limit {
            tasks.spawn(task(next));
            next += 1;
        }
        match tasks.join_next().await {
            None => return Ok(()),
            Some(Ok(Ok(value))) => collect(value),
            Some(result) => {
                tasks.abort_all();
                while tasks.join_next().await.is_some() {}
                return Err(match result {
                    Ok(Err(error)) => error,
                    Err(error) => SidecarError::new("engine_unavailable", error.to_string()),
                    _ => unreachable!(),
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };

    #[tokio::test]
    async fn large_range_count_never_allocates_a_large_pending_queue() {
        let outstanding = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let mut completed = 0;
        run_bounded(
            100_000,
            4,
            |_| {
                let now = outstanding.fetch_add(1, Ordering::SeqCst) + 1;
                peak.fetch_max(now, Ordering::SeqCst);
                let outstanding = outstanding.clone();
                async move {
                    tokio::task::yield_now().await;
                    outstanding.fetch_sub(1, Ordering::SeqCst);
                    Ok(())
                }
            },
            |_| completed += 1,
        )
        .await
        .unwrap();
        assert_eq!(completed, 100_000);
        assert!(peak.load(Ordering::SeqCst) <= 4);
    }

    #[tokio::test]
    async fn first_failure_stops_further_dispatch_and_drains_workers() {
        let mut dispatched = 0;
        let error = run_bounded(
            100_000,
            2,
            |index| {
                dispatched += 1;
                async move {
                    if index == 0 {
                        return Err(SidecarError::new("object_conflict", "changed"));
                    }
                    tokio::time::sleep(std::time::Duration::from_secs(60)).await;
                    Ok(())
                }
            },
            |_| {},
        )
        .await
        .unwrap_err();
        assert_eq!(error.code, "object_conflict");
        assert_eq!(dispatched, 2);
    }
}
