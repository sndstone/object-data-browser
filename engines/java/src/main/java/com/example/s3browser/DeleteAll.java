package com.example.s3browser;

import com.fasterxml.jackson.databind.JsonNode;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.*;
import java.net.URI;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Full-bucket deletion with bounded retries and a tightly guarded compatible-store metadata reset.
 */
final class DeleteAll {
    private static final Map<String, AtomicBoolean> JOBS = new ConcurrentHashMap<>();

    private record Entry(ObjectIdentifier id, String etag, Long size, String modified) {}

    private static boolean retryable(String c) {
        return Set.of(
                        "InternalError",
                        "InternalServerError",
                        "ServiceUnavailable",
                        "SlowDown",
                        "RequestTimeout",
                        "OperationAborted",
                        "503",
                        "500")
                .contains(c);
    }

    private static boolean stale(String c) {
        return retryable(c)
                || Set.of("NoSuchKey", "NoSuchObject", "InvalidObjectState").contains(c);
    }

    private static String code(Exception e) {
        return e instanceof S3Exception s && s.awsErrorDetails() != null
                ? Objects.toString(s.awsErrorDetails().errorCode(), "Unknown")
                : "Unknown";
    }

    private static void check(AtomicBoolean cancel) {
        if (cancel.get() || Thread.currentThread().isInterrupted())
            throw new IllegalStateException("Deletion cancelled.");
    }

    private static void backoff(int attempt, AtomicBoolean cancel) {
        for (int i = 0; i < (1 << Math.min(attempt, 5)); i++) {
            check(cancel);
            try {
                Thread.sleep(100);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                check(cancel);
            }
        }
        check(cancel);
    }

    private static String versioning(S3Client c, String b) {
        var r = c.getBucketVersioning(GetBucketVersioningRequest.builder().bucket(b).build());
        return r.statusAsString() == null || r.statusAsString().isEmpty()
                ? "never-enabled"
                : r.statusAsString();
    }

    static boolean eligible(JsonNode profile) {
        String host =
                Objects.toString(URI.create(profile.path("endpointUrl").asText()).getHost(), "")
                        .toLowerCase(Locale.ROOT);
        return "s3Compatible".equals(profile.path("endpointType").asText("s3Compatible"))
                && !host.isEmpty()
                && !(host.equals("amazonaws.com")
                        || host.endsWith(".amazonaws.com")
                        || host.endsWith(".amazonaws.com.cn")
                        || host.endsWith(".c2s.ic.gov")
                        || host.endsWith(".sc2s.sgov.gov"));
    }

    private static Entry present(S3Client c, String b, Entry e) {
        return c
                .listObjectsV2(
                        ListObjectsV2Request.builder()
                                .bucket(b)
                                .prefix(e.id.key())
                                .maxKeys(1)
                                .build())
                .contents()
                .stream()
                .filter(o -> e.id.key().equals(o.key()))
                .findFirst()
                .map(
                        o ->
                                new Entry(
                                        e.id,
                                        o.eTag(),
                                        o.size(),
                                        Objects.toString(o.lastModified(), null)))
                .orElse(null);
    }

    private static boolean same(Entry a, Entry b) {
        return b != null
                && a.etag != null
                && a.etag.equals(b.etag)
                && Objects.equals(a.size, b.size)
                && Objects.equals(a.modified, b.modified);
    }

    private static void single(S3Client c, String b, Entry e, int retries, AtomicBoolean cancel) {
        for (int attempt = 0; attempt <= retries; attempt++) {
            check(cancel);
            try {
                c.deleteObject(
                        DeleteObjectRequest.builder()
                                .bucket(b)
                                .key(e.id.key())
                                .versionId(e.id.versionId())
                                .ifMatch(e.etag)
                                .build());
                return;
            } catch (Exception x) {
                if (attempt == retries || !retryable(code(x))) throw x;
                backoff(attempt, cancel);
            }
        }
    }

    private static String recover(
            S3Client c,
            String b,
            Entry e,
            int retries,
            boolean repair,
            AtomicBoolean cancel,
            String batchError) {
        check(cancel);
        if (e.id.versionId() != null)
            throw new IllegalStateException("Version deletion failed: " + batchError);
        if (batchError != null && !stale(batchError))
            throw new IllegalStateException(batchError + "; recovery skipped.");
        var before = present(c, b, e);
        if (before == null) return "deleted";
        // Successful-but-persistent entries first get the same ordinary batch retry budget.
        if (batchError == null)
            for (int attempt = 0; attempt < retries; attempt++) {
                backoff(attempt, cancel);
                var response =
                        c.deleteObjects(
                                DeleteObjectsRequest.builder()
                                        .bucket(b)
                                        .delete(Delete.builder().objects(e.id).quiet(false).build())
                                        .build());
                if (!response.errors().isEmpty()
                        && !stale(Objects.toString(response.errors().getFirst().code(), "Unknown")))
                    throw new IllegalStateException(
                            "Recovery skipped: " + response.errors().getFirst().code());
                before = present(c, b, e);
                if (before == null) return "deleted after ordinary retries";
            }
        if (!repair)
            throw new IllegalStateException(
                    "Key remains after bounded deletion; metadata recovery is not eligible.");
        if (!same(e, before)) throw new IllegalStateException("Object changed; recovery skipped.");
        try {
            single(c, b, e, retries, cancel);
        } catch (Exception x) {
            if (!stale(code(x))) throw x;
        }
        check(cancel);
        var current = present(c, b, e);
        if (current == null) return "deleted after individual DELETE";
        if (!same(e, current)) throw new IllegalStateException("Object changed; recovery skipped.");
        if (!"never-enabled".equals(versioning(c, b)))
            throw new IllegalStateException("Versioning changed; recovery skipped.");
        try {
            var h = c.headObject(HeadObjectRequest.builder().bucket(b).key(e.id.key()).build());
            if (!Objects.equals(h.eTag(), e.etag)
                    || h.objectLockMode() != null
                    || "ON".equals(h.objectLockLegalHoldStatusAsString()))
                throw new IllegalStateException("Object changed or protected; recovery skipped.");
        } catch (S3Exception x) {
            if (!Set.of("NoSuchKey", "NotFound", "404").contains(code(x))) throw x;
        }
        check(cancel);
        // A conditional, non-retried PUT prevents overwriting a concurrent replacement.
        PutObjectResponse reset;
        try {
            reset =
                    c.putObject(
                            PutObjectRequest.builder()
                                    .bucket(b)
                                    .key(e.id.key())
                                    .ifMatch(e.etag)
                                    .build(),
                            RequestBody.empty());
        } catch (Exception x) {
            throw new IllegalStateException(
                    "Empty PUT failed or completion is unknown; no further overwrite attempted.",
                    x);
        }
        try {
            check(cancel);
            if (reset.eTag() == null)
                throw new IllegalStateException("PUT returned no identity validator.");
            single(c, b, new Entry(e.id, reset.eTag(), 0L, null), retries, cancel);
            if (present(c, b, e) != null) throw new IllegalStateException("Key is still listed.");
        } catch (Exception x) {
            throw new IllegalStateException("overwritten with an empty object; delete failed", x);
        }
        return "deleted after empty PUT metadata reset";
    }

    static Map<String, Object> run(S3Client client, JsonNode params) {
        JsonNode cfg = params.path("config");
        String bucket = cfg.path("bucketName").asText("").trim();
        if (bucket.isEmpty()) throw new IllegalArgumentException("Bucket name is required.");
        String prefix = cfg.path("prefix").asText("");
        int retries = Math.min(Math.max(cfg.path("maxRetries").asInt(3), 0), 10),
                pageSize = Math.min(Math.max(cfg.path("listMaxKeys").asInt(1000), 1), 1000),
                batchSize = Math.min(Math.max(cfg.path("batchSize").asInt(1000), 1), 1000),
                workers = Math.min(Math.max(cfg.path("maxWorkers").asInt(4), 1), 16);
        String id = params.path("jobId").asText("tool-" + UUID.randomUUID());
        AtomicBoolean cancel = new AtomicBoolean();
        JOBS.put(id, cancel);
        long deleted = 0, failed = 0, empty = 0, skipped = 0, unknown = 0;
        String state;
        try {
            state = versioning(client, bucket);
        } catch (Exception x) {
            state = "unknown";
        }
        boolean versions = !state.equals("never-enabled"),
                repair = state.equals("never-enabled") && eligible(params.path("profile"));
        List<String> lines = new ArrayList<>();
        lines.add(
                "Bucket: "
                        + bucket
                        + "; versioning: "
                        + state
                        + "; metadata recovery eligible: "
                        + repair
                        + ".");
        String previous = "";
        int repeats = 0;
        Set<ObjectIdentifier> pendingVersions = new HashSet<>();
        int exit = 0;
        ExecutorService executor = Executors.newFixedThreadPool(workers);
        try {
            while (true) {
                check(cancel);
                List<Entry> entries = new ArrayList<>();
                if (versions) {
                    var p =
                            client.listObjectVersions(
                                    ListObjectVersionsRequest.builder()
                                            .bucket(bucket)
                                            .prefix(prefix)
                                            .maxKeys(pageSize)
                                            .build());
                    for (var v : p.versions()) {
                        if (v.versionId() == null)
                            throw new IllegalStateException(
                                    "Version listing omitted version ID; refusing key-only"
                                        + " deletion.");
                        entries.add(
                                new Entry(
                                        ObjectIdentifier.builder()
                                                .key(v.key())
                                                .versionId(v.versionId())
                                                .build(),
                                        null,
                                        null,
                                        null));
                    }
                    for (var v : p.deleteMarkers()) {
                        if (v.versionId() == null)
                            throw new IllegalStateException(
                                    "Version listing omitted marker ID; refusing key-only"
                                        + " deletion.");
                        entries.add(
                                new Entry(
                                        ObjectIdentifier.builder()
                                                .key(v.key())
                                                .versionId(v.versionId())
                                                .build(),
                                        null,
                                        null,
                                        null));
                    }
                } else {
                    var p =
                            client.listObjectsV2(
                                    ListObjectsV2Request.builder()
                                            .bucket(bucket)
                                            .prefix(prefix)
                                            .maxKeys(pageSize)
                                            .build());
                    for (var v : p.contents())
                        entries.add(
                                new Entry(
                                        ObjectIdentifier.builder().key(v.key()).build(),
                                        v.eTag(),
                                        v.size(),
                                        Objects.toString(v.lastModified(), null)));
                }
                if (versions) {
                    var listed = new HashSet<>(entries.stream().map(Entry::id).toList());
                    for (var prior : pendingVersions) if (!listed.contains(prior)) deleted++;
                    pendingVersions.retainAll(listed);
                }
                if (entries.isEmpty()) break;
                String page = entries.stream().map(e -> e.id.toString()).toList().toString();
                if (page.equals(previous)) {
                    repeats++;
                    if (!versions || repeats > retries)
                        throw new IllegalStateException(
                                "Keys remain after bounded deletion retries; stopped repeated"
                                    + " listing.");
                    backoff(repeats - 1, cancel);
                } else {
                    repeats = 0;
                }
                previous = page;
                for (int offset = 0; offset < entries.size(); offset += batchSize) {
                    List<Entry>
                            batch =
                                    entries.subList(
                                            offset, Math.min(offset + batchSize, entries.size())),
                            pending = new ArrayList<>(batch);
                    Map<ObjectIdentifier, String> errors = new HashMap<>();
                    for (int attempt = 0; attempt <= retries; attempt++) {
                        check(cancel);
                        List<Entry> retry = new ArrayList<>();
                        try {
                            var response =
                                    client.deleteObjects(
                                            DeleteObjectsRequest.builder()
                                                    .bucket(bucket)
                                                    .delete(
                                                            Delete.builder()
                                                                    .objects(
                                                                            pending.stream()
                                                                                    .map(Entry::id)
                                                                                    .toList())
                                                                    .quiet(false)
                                                                    .build())
                                                    .build());
                            for (var e : pending) {
                                var error =
                                        response.errors().stream()
                                                .filter(
                                                        x ->
                                                                Objects.equals(x.key(), e.id.key())
                                                                        && Objects.equals(
                                                                                x.versionId(),
                                                                                e.id.versionId()))
                                                .findFirst();
                                if (error.isPresent()) {
                                    String c = Objects.toString(error.get().code(), "Unknown");
                                    if (attempt < retries && retryable(c)) retry.add(e);
                                    else errors.put(e.id, c);
                                } else if (response.deleted().stream()
                                        .noneMatch(
                                                x ->
                                                        Objects.equals(x.key(), e.id.key())
                                                                && Objects.equals(
                                                                        x.versionId(),
                                                                        e.id.versionId())))
                                    errors.put(e.id, "UnknownOutcome");
                            }
                        } catch (Exception x) {
                            for (var e : pending)
                                if (attempt < retries && retryable(code(x))) retry.add(e);
                                else errors.put(e.id, code(x));
                        }
                        if (retry.isEmpty()) break;
                        pending = retry;
                        backoff(attempt, cancel);
                    }
                    List<Future<String>> jobs = new ArrayList<>();
                    List<Entry> recovered = new ArrayList<>();
                    for (var e : batch) {
                        String error = errors.get(e.id);
                        if (versions && error == null) {
                            pendingVersions.add(e.id);
                            continue;
                        }
                        recovered.add(e);
                        jobs.add(
                                executor.submit(
                                        () ->
                                                recover(
                                                        client, bucket, e, retries, repair, cancel,
                                                        error)));
                    }
                    for (int i = 0; i < jobs.size(); i++)
                        try {
                            String result = jobs.get(i).get();
                            deleted++;
                            if (!result.equals("deleted") && lines.size() < 200)
                                lines.add(recovered.get(i).id.key() + ": " + result);
                        } catch (ExecutionException x) {
                            failed++;
                            String message =
                                    Objects.toString(x.getCause().getMessage(), "Unknown failure");
                            if (message.contains("overwritten with an empty object")) empty++;
                            if (message.contains("skipped") || message.contains("not eligible"))
                                skipped++;
                            if (message.contains("unknown") || message.contains("UnknownOutcome"))
                                unknown++;
                            if (lines.size() < 200)
                                lines.add(recovered.get(i).id.key() + ": " + message);
                        }
                    if (failed > 0)
                        throw new IllegalStateException(
                                "Stopped with unresolved objects; bucket was not deleted.");
                    long delay = cfg.path("deletionDelayMs").asLong(0);
                    if (delay > 0) Thread.sleep(Math.min(delay, 60_000));
                }
            }
        } catch (Exception x) {
            exit = cancel.get() ? 130 : 1;
            if (x instanceof InterruptedException) Thread.currentThread().interrupt();
            lines.add(Objects.toString(x.getMessage(), "Deletion failed."));
        } finally {
            executor.shutdownNow();
            JOBS.remove(id);
        }
        lines.add(
                "Confirmed deletions: "
                        + deleted
                        + "; failures: "
                        + failed
                        + "; empty objects left behind: "
                        + empty
                        + ".");
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("label", "delete-all");
        out.put("running", false);
        out.put(
                "lastStatus",
                "Deleted " + deleted + " entries from " + bucket + "; " + failed + " failures.");
        out.put("jobId", id);
        out.put("cancellable", false);
        out.put("outputLines", lines);
        out.put("exitCode", exit);
        out.put("deletedCount", deleted);
        out.put("failedCount", failed);
        out.put("emptyObjectsLeft", empty);
        out.put("skippedRecoveryCount", skipped);
        out.put("unknownOutcomeCount", unknown);
        out.put("verifiedEmpty", exit == 0);
        out.put("versioningState", state);
        return out;
    }

    static Map<String, Object> cancel(JsonNode params) {
        String id = params.path("jobId").asText("");
        var job = JOBS.get(id);
        if (job != null) job.set(true);
        return Map.of(
                "jobId",
                id,
                "running",
                job != null,
                "cancellable",
                false,
                "lastStatus",
                job != null
                        ? "Cancellation requested; waiting for in-flight request reconciliation."
                        : "No active deletion with this job ID.",
                "outputLines",
                List.of());
    }
}
