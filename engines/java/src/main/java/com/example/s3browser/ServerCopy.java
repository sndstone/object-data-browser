package com.example.s3browser;

import com.fasterxml.jackson.databind.JsonNode;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.*;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

final class ServerCopy {
    private static String encode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8).replace("+", "%20");
    }

    private static String required(JsonNode p, String field) {
        String v = p.path(field).asText("");
        if (v.isEmpty()) throw new IllegalArgumentException(field + " is required.");
        return v;
    }

    static Map<String, Object> run(S3Client c, JsonNode p, int workers) {
        String sb = required(p, "sourceBucketName"),
                sk = required(p, "sourceKey"),
                b = required(p, "destinationBucketName"),
                k = required(p, "destinationKey");
        String selected = p.path("sourceVersionId").asText(p.path("versionId").asText(null));
        if (sb.equals(b) && sk.equals(k) && selected == null)
            throw new IllegalArgumentException(
                    "Source and destination must differ unless restoring a selected version.");
        var head =
                c.headObject(
                        HeadObjectRequest.builder().bucket(sb).key(sk).versionId(selected).build());
        long size = head.contentLength();
        String version = selected != null ? selected : head.versionId();
        String source =
                encode(sb + "/" + sk) + (version == null ? "" : "?versionId=" + encode(version));
        String destinationVersion, etag;
        if (size <= 5L * 1024 * 1024 * 1024) {
            var out =
                    c.copyObject(
                            CopyObjectRequest.builder()
                                    .bucket(b)
                                    .key(k)
                                    .copySource(source)
                                    .copySourceIfMatch(head.eTag())
                                    .build());
            destinationVersion = out.versionId();
            etag = out.copyObjectResult() == null ? null : out.copyObjectResult().eTag();
        } else {
            var tags =
                    c.getObjectTagging(
                            GetObjectTaggingRequest.builder()
                                    .bucket(sb)
                                    .key(sk)
                                    .versionId(version)
                                    .build());
            String tagging =
                    String.join(
                            "&",
                            tags.tagSet().stream()
                                    .map(t -> encode(t.key()) + "=" + encode(t.value()))
                                    .toList());
            var created =
                    c.createMultipartUpload(
                            CreateMultipartUploadRequest.builder()
                                    .bucket(b)
                                    .key(k)
                                    .contentType(head.contentType())
                                    .contentEncoding(head.contentEncoding())
                                    .contentDisposition(head.contentDisposition())
                                    .contentLanguage(head.contentLanguage())
                                    .cacheControl(head.cacheControl())
                                    .expires(head.expires())
                                    .metadata(head.metadata())
                                    .storageClass(head.storageClass())
                                    .serverSideEncryption(head.serverSideEncryption())
                                    .ssekmsKeyId(head.ssekmsKeyId())
                                    .bucketKeyEnabled(head.bucketKeyEnabled())
                                    .tagging(tagging.isEmpty() ? null : tagging)
                                    .build());
            String upload = created.uploadId();
            if (upload == null)
                throw new IllegalStateException("Multipart copy returned no upload ID.");
            ExecutorService executor =
                    Executors.newFixedThreadPool(Math.min(Math.max(workers, 1), 8));
            List<Future<CompletedPart>> futures = new ArrayList<>();
            try {
                long partSize = Math.max(128L * 1024 * 1024, (size + 9999) / 10000);
                for (long offset = 0; offset < size; offset += partSize) {
                    long start = offset, end = Math.min(offset + partSize - 1, size - 1);
                    int part = (int) (offset / partSize) + 1;
                    futures.add(
                            executor.submit(
                                    () -> {
                                        var out =
                                                c.uploadPartCopy(
                                                        UploadPartCopyRequest.builder()
                                                                .bucket(b)
                                                                .key(k)
                                                                .uploadId(upload)
                                                                .partNumber(part)
                                                                .copySource(source)
                                                                .copySourceRange(
                                                                        "bytes=" + start + "-"
                                                                                + end)
                                                                .copySourceIfMatch(head.eTag())
                                                                .build());
                                        if (out.copyPartResult() == null
                                                || out.copyPartResult().eTag() == null)
                                            throw new IllegalStateException(
                                                    "Copy part returned no ETag.");
                                        return CompletedPart.builder()
                                                .partNumber(part)
                                                .eTag(out.copyPartResult().eTag())
                                                .build();
                                    }));
                }
                List<CompletedPart> parts = new ArrayList<>();
                for (var future : futures) parts.add(future.get());
                var out =
                        c.completeMultipartUpload(
                                CompleteMultipartUploadRequest.builder()
                                        .bucket(b)
                                        .key(k)
                                        .uploadId(upload)
                                        .multipartUpload(
                                                CompletedMultipartUpload.builder()
                                                        .parts(parts)
                                                        .build())
                                        .build());
                destinationVersion = out.versionId();
                etag = out.eTag();
            } catch (Exception error) {
                for (var future : futures) future.cancel(true);
                executor.shutdownNow();
                try {
                    executor.awaitTermination(30, TimeUnit.SECONDS);
                } catch (InterruptedException x) {
                    Thread.currentThread().interrupt();
                }
                try {
                    c.abortMultipartUpload(
                            AbortMultipartUploadRequest.builder()
                                    .bucket(b)
                                    .key(k)
                                    .uploadId(upload)
                                    .build());
                } catch (Exception ignored) {
                }
                Throwable cause = error instanceof ExecutionException ? error.getCause() : error;
                if (cause instanceof RuntimeException runtime) throw runtime;
                if (error instanceof InterruptedException) Thread.currentThread().interrupt();
                throw new IllegalStateException(
                        "Multipart copy failed: " + cause.getMessage(), cause);
            } finally {
                executor.shutdownNow();
            }
        }
        if (etag == null)
            throw new IllegalStateException(
                    "Copy completion returned no ETag; source retained and destination requires"
                        + " reconciliation.");
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("successCount", 1);
        result.put("failureCount", 0);
        result.put("failures", List.of());
        result.put("sourceVersionId", version);
        result.put("sourceETag", head.eTag());
        result.put("destinationVersionId", destinationVersion);
        result.put("etag", etag);
        result.put("bytesCopied", size);
        result.put(
                "strategy",
                size > 5L * 1024 * 1024 * 1024 ? "multipart server-side copy" : "server-side copy");
        return result;
    }
}
