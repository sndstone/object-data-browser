package com.example.s3browser;

import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.*;
import java.util.function.Consumer;

/** A completion window: submitted tasks and their futures are bounded, not just threads. */
final class BoundedTasks<T> implements AutoCloseable {
    private final CompletionService<T> completions;
    private final Set<Future<T>> pending = new HashSet<>();
    private final int limit;
    private final Consumer<T> consume;

    BoundedTasks(ExecutorService executor, int limit, Consumer<T> consume) {
        if (limit < 1) throw new IllegalArgumentException("Positive task window required.");
        this.completions = new ExecutorCompletionService<>(executor);
        this.limit = limit;
        this.consume = consume;
    }

    void submit(Callable<T> task) throws InterruptedException, ExecutionException {
        if (pending.size() == limit) collect();
        pending.add(completions.submit(task));
    }

    void finish() throws InterruptedException, ExecutionException {
        while (!pending.isEmpty()) collect();
    }

    private void collect() throws InterruptedException, ExecutionException {
        Future<T> completed = completions.take();
        pending.remove(completed);
        consume.accept(completed.get());
    }

    int pendingCount() { return pending.size(); }

    @Override public void close() {
        pending.forEach(task -> task.cancel(true));
        pending.clear();
    }
}
