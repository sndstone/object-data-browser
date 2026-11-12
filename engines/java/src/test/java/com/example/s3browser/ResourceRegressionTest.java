package com.example.s3browser;

import software.amazon.awssdk.core.exception.SdkClientException;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.*;
import java.io.*;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.nio.file.attribute.FileTime;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

/** Fault injection for bounded dispatch, retry isolation, source identity and cleanup. */
final class ResourceRegressionTest {
    static void run() throws Exception {
        boundedDispatch();
        failureCancelsPending();
        sourceSnapshots();
        rangeRetries();
        multipartCleanup();
        batchNames();
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    private static void boundedDispatch() throws Exception {
        ExecutorService executor = Executors.newFixedThreadPool(3);
        AtomicInteger completed = new AtomicInteger(), active = new AtomicInteger(), peak = new AtomicInteger();
        try (BoundedTasks<Integer> tasks = new BoundedTasks<>(executor, 3, completed::addAndGet)) {
            for (int i = 0; i < 100_000; i++) {
                tasks.submit(() -> {
                    peak.accumulateAndGet(active.incrementAndGet(), Math::max);
                    active.decrementAndGet();
                    return 1;
                });
                check(tasks.pendingCount() <= 3, "Pending work independent of logical range count");
            }
            tasks.finish();
            check(tasks.pendingCount() == 0, "Completion drains window");
            check(completed.get() == 100_000 && peak.get() <= 3, "All ranges complete with bounded workers");
        } finally { executor.shutdownNow(); }
    }

    private static void failureCancelsPending() throws Exception {
        ExecutorService executor = Executors.newFixedThreadPool(2);
        CountDownLatch blocked = new CountDownLatch(1), cancelled = new CountDownLatch(1);
        try {
            try (BoundedTasks<Void> tasks = new BoundedTasks<>(executor, 2, ignored -> {})) {
                tasks.submit(() -> {
                    blocked.countDown();
                    try { new CountDownLatch(1).await(); }
                    catch (InterruptedException expected) { cancelled.countDown(); throw expected; }
                    return null;
                });
                check(blocked.await(2, TimeUnit.SECONDS), "Slow first worker started");
                tasks.submit(() -> { throw new IOException("later range failed"); });
                try {
                    tasks.finish();
                    throw new AssertionError("Worker failure hidden behind slow first range");
                } catch (ExecutionException expected) {
                    check(expected.getCause().getMessage().equals("later range failed"), "Failure collected in completion order");
                }
            }
            check(cancelled.await(2, TimeUnit.SECONDS), "Outstanding worker interrupted on failure");
        } finally { executor.shutdownNow(); }
    }

    private static void sourceSnapshots() throws Exception {
        Path directory = Files.createTempDirectory("odb-source-");
        Path path = directory.resolve("source"), old = directory.resolve("old");
        try {
            Files.writeString(path, "original");
            var snapshot = UploadSource.Snapshot.capture(path);
            try (UploadSource source = new UploadSource(path, snapshot)) {
                // All parts read the same handle even when the pathname is replaced.
                Files.move(path, old);
                Files.writeString(path, "replaced");
                try (var stream = new FilePartStream(source.channel, 0, snapshot.size(), () -> {})) {
                    check(new String(stream.readAllBytes()).equals("original"), "Stable handle survives path replacement");
                }
                try { source.verify(); throw new AssertionError("Replacement accepted"); }
                catch (IOException expected) { check(expected.getMessage().contains("changed"), "Replacement detected"); }
            }
            snapshot = UploadSource.Snapshot.capture(path);
            Files.setLastModifiedTime(path, FileTime.fromMillis(snapshot.modified().toMillis() + 2000));
            try { new UploadSource(path, snapshot); throw new AssertionError("Queued source mutation accepted"); }
            catch (IOException expected) { /* Verified before any upload is initiated. */ }
        } finally {
            Files.deleteIfExists(path); Files.deleteIfExists(old); Files.delete(directory);
        }
    }

    private static void rangeRetries() throws Exception {
        Path target = Files.createTempFile("odb-range-", ".part");
        byte[] desired = {1, 2, 3, 4};
        try (FileChannel output = FileChannel.open(target, StandardOpenOption.WRITE)) {
            AtomicInteger opens = new AtomicInteger();
            long copied = RangedDownload.transfer(output, 0, 3, 4, "source-etag", 3, () -> {
                InputStream body = opens.incrementAndGet() == 1 ? new InputStream() {
                    int offset;
                    @Override public int read() throws IOException {
                        if (offset == 2) throw new IOException("connection reset");
                        return desired[offset++];
                    }
                    @Override public int read(byte[] bytes, int start, int length) throws IOException {
                        if (offset == 2) throw new IOException("connection reset");
                        bytes[start] = (byte) read();
                        return 1;
                    }
                } : new ByteArrayInputStream(desired);
                return new RangedDownload.Response(body, "bytes 0-3/4", "source-etag", 4L);
            }, () -> {});
            check(copied == 4 && opens.get() == 2, "Only completed range bytes acknowledged");
            check(Arrays.equals(Files.readAllBytes(target), desired), "Retry rewrites original range offset");

            opens.set(0);
            try {
                RangedDownload.transfer(output, 0, 3, 4, "source-etag", 3, () -> {
                    opens.incrementAndGet();
                    return new RangedDownload.Response(new ByteArrayInputStream(desired), "bytes 0-3/4", "changed", 4L);
                }, () -> {});
                throw new AssertionError("Changed source accepted");
            } catch (IOException expected) { check(opens.get() == 1, "Validator conflicts never retried"); }

            opens.set(0);
            output.close();
            try {
                RangedDownload.transfer(output, 0, 3, 4, "source-etag", 3, () -> {
                    opens.incrementAndGet();
                    return new RangedDownload.Response(new ByteArrayInputStream(desired), "bytes 0-3/4", "source-etag", 4L);
                }, () -> {});
                throw new AssertionError("Local write failure ignored");
            } catch (IOException expected) { check(opens.get() == 1, "Local disk failures never retried"); }
        } finally { Files.delete(target); }
    }

    private static void multipartCleanup() throws Exception {
        for (String outcome : new String[] {"openFailure", "partFailure", "rejected", "success", "unknown"}) {
            AtomicInteger aborts = new AtomicInteger();
            S3Client client = (S3Client) java.lang.reflect.Proxy.newProxyInstance(S3Client.class.getClassLoader(),
                new Class<?>[] {S3Client.class}, (proxy, method, args) -> {
                    if (method.getName().equals("abortMultipartUpload")) {
                        aborts.incrementAndGet(); return AbortMultipartUploadResponse.builder().build();
                    }
                    if (method.getName().equals("completeMultipartUpload")) {
                        if (outcome.equals("rejected")) throw S3Exception.builder().statusCode(400).message("rejected").build();
                        if (outcome.equals("unknown")) throw SdkClientException.create("lost completion response");
                        return CompleteMultipartUploadResponse.builder().eTag("committed").build();
                    }
                    return null;
                });
            try (MultipartUploadSession upload = new MultipartUploadSession(client, "bucket", "key", "upload")) {
                if (outcome.equals("openFailure") || outcome.equals("partFailure")) throw new IOException(outcome);
                upload.complete(CompletedMultipartUpload.builder().parts(List.of()).build());
            } catch (IOException | RuntimeException expected) {
                check(!outcome.equals("success"), "Successful completion failed");
            }
            check(aborts.get() == (Set.of("success", "unknown").contains(outcome) ? 0 : 1),
                "Abort all definite failures and retain uncertain completions: " + outcome);
        }
    }

    private static void batchNames() throws Exception {
        Path directory = Files.createTempDirectory("odb-batch-");
        try {
            var allocator = new DownloadDestination.Allocator(directory);
            for (int index = 0; index < 100; index++) {
                try (DownloadDestination staged = new DownloadDestination(directory)) {
                    Files.writeString(staged.path, "data");
                    Path target = staged.publish(allocator, "file.txt", "keepBoth");
                    check(target.getFileName().toString().equals(index == 0 ? "file.txt" : "file (" + index + ").txt"),
                        "Batch index updated after publication");
                }
            }
        } finally {
            try (var files = Files.list(directory)) { for (Path path : files.toList()) Files.delete(path); }
            Files.delete(directory);
        }
    }
}
