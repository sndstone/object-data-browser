package com.example.s3browser;

import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.*;
import java.util.function.Consumer;

/** A completion window: submitted tasks and their futures are bounded, not just threads. */
final class BoundedTasks<T> implements AutoCloseable {
    private static final long DRAIN_SECONDS = 120;
    private final ExecutorService executor;
    private final BlockingQueue<Task> completions = new LinkedBlockingQueue<>();
    private final Set<Task> pending = new HashSet<>();
    private final int limit;
    private final Consumer<T> consume;

    BoundedTasks(ExecutorService executor, int limit, Consumer<T> consume) {
        if (limit < 1) throw new IllegalArgumentException("Positive task window required.");
        this.executor = executor;
        this.limit = limit;
        this.consume = consume;
    }

    void submit(Callable<T> task) throws InterruptedException, ExecutionException {
        if (pending.size() == limit) collect();
        Task submitted = new Task(task);
        executor.execute(submitted);
        pending.add(submitted);
    }

    void finish() throws InterruptedException, ExecutionException {
        while (!pending.isEmpty()) collect();
    }

    private void collect() throws InterruptedException, ExecutionException {
        Task completed = completions.take();
        pending.remove(completed);
        consume.accept(completed.get());
    }

    int pendingCount() { return pending.size(); }

    @Override public void close() {
        pending.forEach(task -> task.cancel(true));
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(DRAIN_SECONDS);
        for (Task task : pending) {
            if (!await(deadline, nanos -> task.exited.await(nanos, TimeUnit.NANOSECONDS))) {
                warn("Timed out draining cancelled tasks; a worker may still be running.");
                break;
            }
        }
        pending.clear();
    }

    static void shutdownAndAwait(ExecutorService executor) {
        executor.shutdownNow();
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(DRAIN_SECONDS);
        if (!await(deadline, nanos -> executor.awaitTermination(nanos, TimeUnit.NANOSECONDS)))
            warn("Timed out waiting for transfer executor termination; a worker may still be running.");
    }

    private static void warn(String message) {
        Main.emitStructuredLog("WARN", "Transfer", message, "engine");
    }

    private interface Waiter {
        boolean await(long nanos) throws InterruptedException;
    }

    // An interrupted owner still drains its workers, then restores its interrupt status.
    private static boolean await(long deadline, Waiter waiter) {
        boolean interrupted = Thread.interrupted();
        try {
            while (true) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) return false;
                try { return waiter.await(remaining); }
                catch (InterruptedException error) { interrupted = true; }
            }
        } finally {
            if (interrupted) Thread.currentThread().interrupt();
        }
    }

    private final class Task extends FutureTask<T> {
        private final CountDownLatch exited = new CountDownLatch(1);
        private boolean started;

        Task(Callable<T> callable) { super(callable); }

        @Override public void run() {
            synchronized (this) {
                if (isCancelled()) return;
                started = true;
            }
            try { super.run(); }
            finally {
                exited.countDown();
                completions.add(this);
            }
        }

        @Override public synchronized boolean cancel(boolean interrupt) {
            boolean cancelled = super.cancel(interrupt);
            // A cancelled queued task will never enter its callable. For a running task,
            // Future.isDone/get reflect cancellation immediately, not callable completion.
            if (!started) exited.countDown();
            return cancelled;
        }
    }
}
