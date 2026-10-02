package com.example.s3browser;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import software.amazon.awssdk.core.interceptor.*;
import software.amazon.awssdk.core.sync.RequestBody;

/** Resources belong to one running generation; nothing here is serialized with run state. */
final class BenchmarkRuntime implements AutoCloseable {
    static final int HISTORY_LIMIT = 10_000;
    static final ThreadLocal<Counts> COUNTS = new ThreadLocal<>();
    static final class Counts { long retries, errors; }
    static final class Metrics implements ExecutionInterceptor {
        private static final ExecutionAttribute<AtomicInteger> ATTEMPTS =
                new ExecutionAttribute<>("object-browser-benchmark-attempts");
        @Override public void beforeExecution(Context.BeforeExecution c, ExecutionAttributes a) {
            if (COUNTS.get() != null) a.putAttribute(ATTEMPTS, new AtomicInteger());
        }
        @Override public void beforeTransmission(Context.BeforeTransmission c, ExecutionAttributes a) {
            var attempts = a.getAttribute(ATTEMPTS);
            if (attempts != null && attempts.getAndIncrement() > 0 && COUNTS.get() != null)
                COUNTS.get().retries++;
        }
        @Override public void onExecutionFailure(Context.FailedExecution c, ExecutionAttributes a) {
            if (COUNTS.get() != null) COUNTS.get().errors++;
        }
    }

    final ExecutorService executor;
    long sliceStarted;
    long lastPersistNanos;
    double baseElapsed;
    private final long budget;
    private final long maxEntry;
    private final boolean inMemory;
    private final LinkedHashMap<String, byte[]> cache = new LinkedHashMap<>(16, .75f, true);
    private long cacheBytes;
    private BufferedWriter csv;
    BenchmarkRuntime(Map<String, Object> config) {
        int workers = Math.min(64, Math.max(1, number(config, "concurrentThreads", 1)));
        workers = Math.min(workers, Math.max(1, number(config, "maxPoolConnections", 10)));
        executor = Executors.newFixedThreadPool(workers, task -> {
            Thread thread = new Thread(task, "s3-benchmark-request");
            thread.setDaemon(true);
            return thread;
        });
        budget = (long) Math.min(1024, Math.max(0, number(config, "dataCacheMb", 64))) * 1024 * 1024;
        maxEntry = Math.max(256 * 1024, budget / workers);
        inMemory = !Boolean.FALSE.equals(config.get("inMemoryData"));
    }
    static int number(Map<String, Object> c, String key, int fallback) {
        return c.get(key) instanceof Number n ? n.intValue() : fallback;
    }
    static byte[] pattern(String runId, String key, int size, boolean random) {
        if (!random) return new byte[] {'A'};
        byte[] seed = (runId + ":" + key + ":" + size).getBytes(StandardCharsets.UTF_8);
        byte[] pattern = new byte[Math.max(64, Math.min(seed.length * 8, 4096))];
        for (int i = 0; i < pattern.length; i++) pattern[i] = (byte) (seed[i % seed.length] + i * 17);
        return pattern;
    }
    static void fill(byte[] target, byte[] pattern, long offset, int count) {
        int written = 0;
        while (written < count) {
            int start = (int) ((offset + written) % pattern.length);
            int length = Math.min(count - written, pattern.length - start);
            System.arraycopy(pattern, start, target, written, length);
            written += length;
        }
    }
    final class Payload implements AutoCloseable {
        final byte[] bytes;
        final Path path;
        Payload(byte[] bytes, Path path) { this.bytes = bytes; this.path = path; }
        RequestBody body() {
            return path != null ? RequestBody.fromFile(path) : RequestBody.fromContentProvider(
                    () -> new ByteArrayInputStream(bytes), bytes.length, "application/octet-stream");
        }
        @Override public void close() throws IOException { if (path != null) Files.deleteIfExists(path); }
    }
    Payload payload(String runId, String key, int size, boolean random) throws IOException {
        String identity = runId + '\0' + key + '\0' + size + '\0' + random;
        if (inMemory && size <= maxEntry) {
            synchronized (cache) {
                byte[] hit = cache.get(identity);
                if (hit != null) return new Payload(hit, null);
            }
            byte[] bytes = new byte[size];
            fill(bytes, pattern(runId, key, size, random), 0, size);
            synchronized (cache) {
                if (size <= budget) {
                    while (cacheBytes + size > budget && !cache.isEmpty()) {
                        var iterator = cache.entrySet().iterator();
                        cacheBytes -= iterator.next().getValue().length;
                        iterator.remove();
                    }
                    byte[] replaced = cache.put(identity, bytes);
                    cacheBytes += size - (replaced == null ? 0 : replaced.length);
                }
            }
            return new Payload(bytes, null);
        }
        Path path = Files.createTempFile("object-browser-benchmark-", ".payload");
        try {
            byte[] buffer = new byte[256 * 1024], pattern = pattern(runId, key, size, random);
            try (OutputStream output = Files.newOutputStream(path)) {
                for (long offset = 0; offset < size; offset += buffer.length) {
                    int count = (int) Math.min(buffer.length, size - offset);
                    fill(buffer, pattern, offset, count);
                    output.write(buffer, 0, count);
                }
            }
            return new Payload(null, path);
        } catch (IOException | RuntimeException error) { Files.deleteIfExists(path); throw error; }
    }
    record Consumption(long bytes, boolean valid, String checksum) {}
    private static final class CrcDigest extends MessageDigest {
        private final java.util.zip.Checksum checksum;
        CrcDigest(String algorithm) {
            super(algorithm);
            checksum = "crc32c".equals(algorithm) ? new java.util.zip.CRC32C() : new java.util.zip.CRC32();
        }
        @Override protected void engineUpdate(byte value) { checksum.update(value); }
        @Override protected void engineUpdate(byte[] bytes, int offset, int count) { checksum.update(bytes, offset, count); }
        @Override protected byte[] engineDigest() {
            long value = checksum.getValue();
            checksum.reset();
            return new byte[] {(byte) (value >> 24), (byte) (value >> 16), (byte) (value >> 8), (byte) value};
        }
        @Override protected void engineReset() { checksum.reset(); }
    }
    private static MessageDigest digest(String algorithm) throws IOException {
        if (algorithm.equals("crc32") || algorithm.equals("crc32c")) return new CrcDigest(algorithm);
        try {
            return MessageDigest.getInstance(switch (algorithm) {
                case "sha256" -> "SHA-256";
                case "sha1" -> "SHA-1";
                case "md5" -> "MD5";
                default -> throw new IOException("Unsupported benchmark checksum algorithm.");
            });
        } catch (NoSuchAlgorithmException error) {
            throw new IOException("Selected benchmark checksum algorithm is unavailable.", error);
        }
    }
    static Consumption consume(InputStream input, String run, String key, int size, boolean random,
                               boolean validate, String algorithm) throws IOException {
        byte[] buffer = new byte[256 * 1024];
        byte[] expected = validate ? new byte[buffer.length] : null;
        byte[] pattern = validate ? pattern(run, key, size, random) : null;
        MessageDigest actualHash = validate ? digest(algorithm) : null;
        MessageDigest expectedHash = validate ? digest(algorithm) : null;
        long total = 0;
        int count;
        while ((count = input.read(buffer)) != -1) {
            if (validate) {
                fill(expected, pattern, total, count);
                actualHash.update(buffer, 0, count);
                expectedHash.update(expected, 0, count);
            }
            total += count;
        }
        byte[] actual = validate ? actualHash.digest() : null;
        boolean valid = total == size && (!validate || MessageDigest.isEqual(actual, expectedHash.digest()));
        return new Consumption(total, valid, validate ? HexFormat.of().formatHex(actual) : null);
    }
    long cacheBytes() { synchronized (cache) { return cacheBytes; } }
    BufferedWriter csv(Path path) throws IOException {
        if (csv == null) {
            Files.createDirectories(path.getParent());
            boolean header = !Files.exists(path);
            csv = Files.newBufferedWriter(path, StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND);
            if (header) csv.write("second,operation,operationCount,latencyMs,sizeBytes,bytesTransferred,success,checksumState,key,elapsedMs\n");
        }
        return csv;
    }
    void flushRecords() throws IOException { if (csv != null) csv.flush(); }
    @Override public void close() {
        executor.shutdownNow();
        synchronized (cache) { cache.clear(); cacheBytes = 0; }
        if (csv != null) try { csv.close(); } catch (IOException ignored) { }
    }
}
