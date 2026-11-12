package com.example.s3browser;

import software.amazon.awssdk.core.exception.SdkClientException;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.*;

/** Covers every exit after creation; uncertain completion is retained for reconciliation. */
final class MultipartUploadSession implements AutoCloseable {
    private final S3Client client;
    private final String bucket, key;
    final String uploadId;
    private boolean committed, uncertain;

    MultipartUploadSession(S3Client client, String bucket, String key, String uploadId) {
        if (uploadId == null || uploadId.isBlank()) throw new IllegalStateException("Multipart upload returned no ID.");
        this.client = client;
        this.bucket = bucket;
        this.key = key;
        this.uploadId = uploadId;
    }

    CompleteMultipartUploadResponse complete(CompletedMultipartUpload parts) {
        try {
            var result = client.completeMultipartUpload(CompleteMultipartUploadRequest.builder()
                .bucket(bucket).key(key).uploadId(uploadId).multipartUpload(parts).build());
            committed = true;
            return result;
        } catch (SdkClientException error) {
            uncertain = true;
            throw new IllegalStateException("Multipart completion outcome is unknown; reconcile the destination before retrying.", error);
        } catch (S3Exception error) {
            // A lost response followed by an SDK retry can produce NoSuchUpload after a commit.
            if (error.statusCode() >= 500 || error.statusCode() == 404 || error.statusCode() == 408) {
                uncertain = true;
                throw new IllegalStateException("Multipart completion outcome is unknown; reconcile the destination before retrying.", error);
            }
            throw error;
        }
    }

    @Override public void close() {
        if (!committed && !uncertain) {
            try {
                client.abortMultipartUpload(AbortMultipartUploadRequest.builder()
                    .bucket(bucket).key(key).uploadId(uploadId).build());
            } catch (RuntimeException ignored) {
                // Preserve the original failure. Server lifecycle rules remain a cleanup fallback.
            }
        }
    }
}
