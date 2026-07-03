package com.example.s3browser;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
import software.amazon.awssdk.auth.credentials.AwsSessionCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.core.ResponseInputStream;
import software.amazon.awssdk.core.client.config.ClientOverrideConfiguration;
import software.amazon.awssdk.core.exception.SdkClientException;
import software.amazon.awssdk.core.retry.RetryPolicy;
import software.amazon.awssdk.http.apache.ApacheHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.model.AbortIncompleteMultipartUpload;
import software.amazon.awssdk.services.s3.model.AbortMultipartUploadRequest;
import software.amazon.awssdk.services.s3.model.Bucket;
import software.amazon.awssdk.services.s3.model.BucketLocationConstraint;
import software.amazon.awssdk.services.s3.model.BucketVersioningStatus;
import software.amazon.awssdk.services.s3.model.CORSConfiguration;
import software.amazon.awssdk.services.s3.model.CORSRule;
import software.amazon.awssdk.services.s3.model.CopyObjectRequest;
import software.amazon.awssdk.services.s3.model.CreateBucketConfiguration;
import software.amazon.awssdk.services.s3.model.CreateBucketRequest;
import software.amazon.awssdk.services.s3.model.CreateMultipartUploadRequest;
import software.amazon.awssdk.services.s3.model.DefaultRetention;
import software.amazon.awssdk.services.s3.model.Delete;
import software.amazon.awssdk.services.s3.model.DeleteBucketCorsRequest;
import software.amazon.awssdk.services.s3.model.DeleteBucketEncryptionRequest;
import software.amazon.awssdk.services.s3.model.DeleteBucketLifecycleRequest;
import software.amazon.awssdk.services.s3.model.DeleteBucketPolicyRequest;
import software.amazon.awssdk.services.s3.model.DeleteBucketRequest;
import software.amazon.awssdk.services.s3.model.DeleteBucketTaggingRequest;
import software.amazon.awssdk.services.s3.model.DeleteMarkerEntry;
import software.amazon.awssdk.services.s3.model.DeleteObjectRequest;
import software.amazon.awssdk.services.s3.model.DeleteObjectsRequest;
import software.amazon.awssdk.services.s3.model.ExpirationStatus;
import software.amazon.awssdk.services.s3.model.CompletedMultipartUpload;
import software.amazon.awssdk.services.s3.model.CompletedPart;
import software.amazon.awssdk.services.s3.model.CompleteMultipartUploadRequest;
import software.amazon.awssdk.services.s3.model.GetBucketCorsRequest;
import software.amazon.awssdk.services.s3.model.GetBucketEncryptionRequest;
import software.amazon.awssdk.services.s3.model.GetBucketLifecycleConfigurationRequest;
import software.amazon.awssdk.services.s3.model.GetBucketPolicyRequest;
import software.amazon.awssdk.services.s3.model.GetBucketTaggingRequest;
import software.amazon.awssdk.services.s3.model.GetBucketVersioningRequest;
import software.amazon.awssdk.services.s3.model.GetObjectLockConfigurationRequest;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.GetObjectTaggingRequest;
import software.amazon.awssdk.services.s3.model.HeadObjectRequest;
import software.amazon.awssdk.services.s3.model.LifecycleExpiration;
import software.amazon.awssdk.services.s3.model.LifecycleRule;
import software.amazon.awssdk.services.s3.model.LifecycleRuleFilter;
import software.amazon.awssdk.services.s3.model.ListBucketsRequest;
import software.amazon.awssdk.services.s3.model.ListObjectVersionsRequest;
import software.amazon.awssdk.services.s3.model.ListObjectsV2Request;
import software.amazon.awssdk.services.s3.model.NoncurrentVersionExpiration;
import software.amazon.awssdk.services.s3.model.NoncurrentVersionTransition;
import software.amazon.awssdk.services.s3.model.ObjectIdentifier;
import software.amazon.awssdk.services.s3.model.ObjectLockConfiguration;
import software.amazon.awssdk.services.s3.model.ObjectVersion;
import software.amazon.awssdk.services.s3.model.PutBucketCorsRequest;
import software.amazon.awssdk.services.s3.model.PutBucketEncryptionRequest;
import software.amazon.awssdk.services.s3.model.PutBucketLifecycleConfigurationRequest;
import software.amazon.awssdk.services.s3.model.PutBucketPolicyRequest;
import software.amazon.awssdk.services.s3.model.PutBucketTaggingRequest;
import software.amazon.awssdk.services.s3.model.PutBucketVersioningRequest;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.model.S3Exception;
import software.amazon.awssdk.services.s3.model.ServerSideEncryptionByDefault;
import software.amazon.awssdk.services.s3.model.ServerSideEncryptionConfiguration;
import software.amazon.awssdk.services.s3.model.ServerSideEncryptionRule;
import software.amazon.awssdk.services.s3.model.Tag;
import software.amazon.awssdk.services.s3.model.Tagging;
import software.amazon.awssdk.services.s3.model.Transition;
import software.amazon.awssdk.services.s3.model.UploadPartRequest;
import software.amazon.awssdk.services.s3.model.VersioningConfiguration;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;
import software.amazon.awssdk.services.s3.presigner.model.GetObjectPresignRequest;

import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;
import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

public final class Main {
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final DateTimeFormatter ISO = DateTimeFormatter.ISO_OFFSET_DATE_TIME.withZone(ZoneOffset.UTC);
    private static final TrustManager[] TRUST_ALL_MANAGERS = new TrustManager[] {
        new X509TrustManager() {
            @Override
            public void checkClientTrusted(java.security.cert.X509Certificate[] chain, String authType) {
            }

            @Override
            public void checkServerTrusted(java.security.cert.X509Certificate[] chain, String authType) {
            }

            @Override
            public java.security.cert.X509Certificate[] getAcceptedIssuers() {
                return new java.security.cert.X509Certificate[0];
            }
        }
    };
    private static final List<String> SUPPORTED_METHODS = List.of(
        "health",
        "getCapabilities",
        "testProfile",
        "listBuckets",
        "createBucket",
        "deleteBucket",
        "setBucketVersioning",
        "putBucketLifecycle",
        "deleteBucketLifecycle",
        "putBucketPolicy",
        "deleteBucketPolicy",
        "putBucketCors",
        "deleteBucketCors",
        "putBucketEncryption",
        "deleteBucketEncryption",
        "putBucketTagging",
        "deleteBucketTagging",
        "listObjects",
        "getBucketAdminState",
        "listObjectVersions",
        "getObjectDetails",
        "createFolder",
        "copyObject",
        "moveObject",
        "deleteObjects",
        "deleteObjectVersions",
        "startUpload",
        "startDownload",
        "pauseTransfer",
        "resumeTransfer",
        "cancelTransfer",
        "generatePresignedUrl",
        "runPutTestData",
        "runDeleteAll",
        "cancelToolExecution",
        "startBenchmark",
        "getBenchmarkStatus",
        "pauseBenchmark",
        "resumeBenchmark",
        "stopBenchmark",
        "exportBenchmarkResults"
    );

    private Main() {
    }

    private static void emitStructuredLog(String level, String category, String message, String source) {
        try {
            System.err.println("S3_BROWSER_LOG " + MAPPER.writeValueAsString(orderedMap(
                "level", level,
                "category", category,
                "message", message,
                "source", source
            )));
        } catch (IOException ignored) {
            System.err.println("S3_BROWSER_LOG {\"level\":\"" + level + "\",\"category\":\"" + category
                + "\",\"message\":\"" + message.replace("\"", "\\\"") + "\",\"source\":\"" + source + "\"}");
        }
    }

    public static void main(String[] args) throws Exception {
        var reader = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String line;
        while ((line = reader.readLine()) != null) {
            line = line.trim();
            if (line.isEmpty()) {
                continue;
            }

            String requestId = null;
            try {
                JsonNode payload = MAPPER.readTree(line);
                requestId = text(payload, "requestId");
                Map<String, Object> result = handleRequest(payload);
                writeResponse(orderedMap(
                    "requestId", requestId,
                    "ok", true,
                    "result", result
                ));
            } catch (Exception error) {
                SidecarException mapped = mapException(error);
                writeResponse(orderedMap(
                    "requestId", requestId,
                    "ok", false,
                    "error", orderedMap(
                        "code", mapped.code,
                        "message", mapped.message,
                        "details", mapped.details
                    )
                ));
            }
        }
    }

    private static void writeResponse(Map<String, Object> response) throws IOException {
        System.out.println(MAPPER.writeValueAsString(response));
    }

    private static Map<String, Object> handleRequest(JsonNode payload) throws Exception {
        String method = text(payload, "method");
        JsonNode params = payload.path("params");
        return switch (method) {
            case "health" -> health();
            case "getCapabilities" -> getCapabilities();
            case "testProfile" -> testProfile(params.path("profile"));
            case "listBuckets" -> listBuckets(params.path("profile"));
            case "createBucket" -> createBucket(params);
            case "deleteBucket" -> deleteBucket(params);
            case "setBucketVersioning" -> setBucketVersioning(params);
            case "putBucketLifecycle" -> putBucketLifecycle(params);
            case "deleteBucketLifecycle" -> deleteBucketLifecycle(params);
            case "putBucketPolicy" -> putBucketPolicy(params);
            case "deleteBucketPolicy" -> deleteBucketPolicy(params);
            case "putBucketCors" -> putBucketCors(params);
            case "deleteBucketCors" -> deleteBucketCors(params);
            case "putBucketEncryption" -> putBucketEncryption(params);
            case "deleteBucketEncryption" -> deleteBucketEncryption(params);
            case "putBucketTagging" -> putBucketTagging(params);
            case "deleteBucketTagging" -> deleteBucketTagging(params);
            case "listObjects" -> listObjects(params);
            case "getBucketAdminState" -> getBucketAdminState(params);
            case "listObjectVersions" -> listObjectVersions(params);
            case "getObjectDetails" -> getObjectDetails(params);
            case "createFolder" -> createFolder(params);
            case "copyObject" -> copyObject(params);
            case "moveObject" -> moveObject(params);
            case "deleteObjects" -> deleteObjects(params);
            case "deleteObjectVersions" -> deleteObjectVersions(params);
            case "startUpload" -> startUpload(params);
            case "startDownload" -> startDownload(params);
            case "pauseTransfer" -> transferControl(params, "paused");
            case "resumeTransfer" -> transferControl(params, "running");
            case "cancelTransfer" -> transferControl(params, "cancelled");
            case "generatePresignedUrl" -> generatePresignedUrl(params);
            case "runPutTestData" -> runPutTestData(params);
            case "runDeleteAll" -> runDeleteAll(params);
            case "cancelToolExecution" -> cancelToolExecution(params);
            case "startBenchmark" -> startBenchmark(params);
            case "getBenchmarkStatus" -> getBenchmarkStatus(params);
            case "pauseBenchmark" -> pauseBenchmark(params);
            case "resumeBenchmark" -> resumeBenchmark(params);
            case "stopBenchmark" -> stopBenchmark(params);
            case "exportBenchmarkResults" -> exportBenchmarkResults(params);
            default -> throw new SidecarException(
                "unsupported_feature",
                "Method " + method + " is not implemented in the Java engine."
            );
        };
    }

    private static Map<String, Object> health() {
        return orderedMap(
            "engine", "java",
            "version", "2.1.0",
            "available", true,
            "methods", SUPPORTED_METHODS,
            "nativeSdk", "aws-sdk-java-v2"
        );
    }

    private static Map<String, Object> getCapabilities() {
        List<Map<String, Object>> items = List.of(
            capability("bucket.lifecycle", "Lifecycle policy CRUD", "supported", null),
            capability("bucket.policy", "Bucket policy CRUD", "supported", null),
            capability("bucket.cors", "Bucket CORS CRUD", "supported", null),
            capability("bucket.encryption", "Bucket encryption", "supported", null),
            capability("bucket.tagging", "Bucket tagging", "supported", null),
            capability("bucket.versioning", "Bucket versioning", "supported", null),
            capability("object.copy_move", "Copy, move, rename", "supported", null),
            capability("object.resumable", "Resumable transfer jobs", "unknown", "Desktop host currently uses one request per sidecar process."),
            capability("tools.bulk-delete", "Delete-all maintenance tool", "supported", null),
            capability("benchmark", "Integrated benchmark mode", "supported", null)
        );
        return orderedMap("items", items);
    }

    private static Map<String, Object> testProfile(JsonNode profileNode) {
        Profile profile = parseProfile(profileNode);
        try (S3Client client = buildClient(profile)) {
            var output = client.listBuckets(ListBucketsRequest.builder().build());
            String endpoint = URI.create(profile.endpointUrl).getHost();
            if (endpoint == null || endpoint.isBlank()) {
                endpoint = profile.endpointUrl;
            }
            return orderedMap(
                "ok", true,
                "bucketCount", output.buckets().size(),
                "endpoint", endpoint
            );
        }
    }

    private static Map<String, Object> listBuckets(JsonNode profileNode) {
        Profile profile = parseProfile(profileNode);
        try (S3Client client = buildClient(profile)) {
            List<Map<String, Object>> items = new ArrayList<>();
            for (Bucket bucket : client.listBuckets(ListBucketsRequest.builder().build()).buckets()) {
                items.add(orderedMap(
                    "name", bucket.name(),
                    "region", profile.region,
                    "objectCountHint", 0,
                    "versioningEnabled", false,
                    "createdAt", serializeTime(bucket.creationDate())
                ));
            }
            return orderedMap("items", items);
        }
    }

    private static Map<String, Object> createBucket(JsonNode params) throws IOException {
        Profile profile = parseProfile(params.path("profile"));
        String bucketName = requiredText(params, "bucketName", "Bucket name is required.");
        boolean enableVersioning = params.path("enableVersioning").asBoolean(false);
        boolean enableObjectLock = params.path("enableObjectLock").asBoolean(false);
        try (S3Client client = buildClient(profile)) {
            CreateBucketRequest.Builder request = CreateBucketRequest.builder().bucket(bucketName);
            if (!"us-east-1".equals(profile.region)) {
                request.createBucketConfiguration(CreateBucketConfiguration.builder()
                    .locationConstraint(BucketLocationConstraint.fromValue(profile.region))
                    .build());
            }
            if (enableObjectLock) {
                request.objectLockEnabledForBucket(true);
            }
            client.createBucket(request.build());
            if (enableVersioning) {
                client.putBucketVersioning(PutBucketVersioningRequest.builder()
                    .bucket(bucketName)
                    .versioningConfiguration(VersioningConfiguration.builder()
                        .status(BucketVersioningStatus.ENABLED)
                        .build())
                    .build());
            }
        }
        return orderedMap(
            "name", bucketName,
            "region", profile.region,
            "objectCountHint", 0,
            "versioningEnabled", enableVersioning,
            "createdAt", nowIso()
        );
    }

    private static Map<String, Object> deleteBucket(JsonNode params) {
        BucketContext context = bucketContext(params);
        try (S3Client client = context.client()) {
            client.deleteBucket(DeleteBucketRequest.builder().bucket(context.bucketName()).build());
        }
        return orderedMap("deleted", true, "bucketName", context.bucketName());
    }

    private static Map<String, Object> setBucketVersioning(JsonNode params) {
        BucketContext context = bucketContext(params);
        boolean enabled = params.path("enabled").asBoolean(false);
        try (S3Client client = context.client()) {
            client.putBucketVersioning(PutBucketVersioningRequest.builder()
                .bucket(context.bucketName())
                .versioningConfiguration(VersioningConfiguration.builder()
                    .status(enabled ? BucketVersioningStatus.ENABLED : BucketVersioningStatus.SUSPENDED)
                    .build())
                .build());
        }
        return getBucketAdminState(params);
    }

    private static Map<String, Object> putBucketLifecycle(JsonNode params) throws IOException {
        BucketContext context = bucketContext(params);
        String lifecycleJson = requiredText(params, "lifecycleJson", "Bucket name and lifecycle JSON are required.");
        try (S3Client client = context.client()) {
            client.putBucketLifecycleConfiguration(PutBucketLifecycleConfigurationRequest.builder()
                .bucket(context.bucketName())
                .lifecycleConfiguration(software.amazon.awssdk.services.s3.model.BucketLifecycleConfiguration.builder()
                    .rules(parseLifecycleRules(MAPPER.readTree(lifecycleJson).path("Rules")))
                    .build())
                .build());
        }
        return getBucketAdminState(params);
    }

    private static Map<String, Object> deleteBucketLifecycle(JsonNode params) {
        BucketContext context = bucketContext(params);
        try (S3Client client = context.client()) {
            client.deleteBucketLifecycle(DeleteBucketLifecycleRequest.builder().bucket(context.bucketName()).build());
        }
        return getBucketAdminState(params);
    }

    private static Map<String, Object> putBucketPolicy(JsonNode params) {
        BucketContext context = bucketContext(params);
        String policyJson = requiredText(params, "policyJson", "Bucket name and policy JSON are required.");
        try (S3Client client = context.client()) {
            client.putBucketPolicy(PutBucketPolicyRequest.builder()
                .bucket(context.bucketName())
                .policy(policyJson)
                .build());
        }
        return getBucketAdminState(params);
    }

    private static Map<String, Object> deleteBucketPolicy(JsonNode params) {
        BucketContext context = bucketContext(params);
        try (S3Client client = context.client()) {
            client.deleteBucketPolicy(DeleteBucketPolicyRequest.builder().bucket(context.bucketName()).build());
        }
        return getBucketAdminState(params);
    }

    private static Map<String, Object> putBucketCors(JsonNode params) throws IOException {
        BucketContext context = bucketContext(params);
        String corsJson = requiredText(params, "corsJson", "Bucket name and CORS JSON are required.");
        try (S3Client client = context.client()) {
            client.putBucketCors(PutBucketCorsRequest.builder()
                .bucket(context.bucketName())
                .corsConfiguration(CORSConfiguration.builder()
                    .corsRules(parseCorsRules(MAPPER.readTree(corsJson)))
                    .build())
                .build());
        }
        return getBucketAdminState(params);
    }

    private static Map<String, Object> deleteBucketCors(JsonNode params) {
        BucketContext context = bucketContext(params);
        try (S3Client client = context.client()) {
            client.deleteBucketCors(DeleteBucketCorsRequest.builder().bucket(context.bucketName()).build());
        }
        return getBucketAdminState(params);
    }

    private static Map<String, Object> putBucketEncryption(JsonNode params) throws IOException {
        BucketContext context = bucketContext(params);
        String encryptionJson = requiredText(params, "encryptionJson", "Bucket name and encryption JSON are required.");
        try (S3Client client = context.client()) {
            client.putBucketEncryption(PutBucketEncryptionRequest.builder()
                .bucket(context.bucketName())
                .serverSideEncryptionConfiguration(parseEncryptionConfiguration(MAPPER.readTree(encryptionJson)))
                .build());
        }
        return getBucketAdminState(params);
    }

    private static Map<String, Object> deleteBucketEncryption(JsonNode params) {
        BucketContext context = bucketContext(params);
        try (S3Client client = context.client()) {
            client.deleteBucketEncryption(DeleteBucketEncryptionRequest.builder().bucket(context.bucketName()).build());
        }
        return getBucketAdminState(params);
    }

    private static Map<String, Object> putBucketTagging(JsonNode params) {
        BucketContext context = bucketContext(params);
        JsonNode tagsNode = params.path("tags");
        if (!tagsNode.isObject()) {
            throw new SidecarException("invalid_config", "Bucket name and tags are required.");
        }
        List<Tag> tagSet = new ArrayList<>();
        tagsNode.fields().forEachRemaining(entry -> tagSet.add(Tag.builder().key(entry.getKey()).value(entry.getValue().asText("")).build()));
        try (S3Client client = context.client()) {
            client.putBucketTagging(PutBucketTaggingRequest.builder()
                .bucket(context.bucketName())
                .tagging(Tagging.builder().tagSet(tagSet).build())
                .build());
        }
        return getBucketAdminState(params);
    }

    private static Map<String, Object> deleteBucketTagging(JsonNode params) {
        BucketContext context = bucketContext(params);
        try (S3Client client = context.client()) {
            client.deleteBucketTagging(DeleteBucketTaggingRequest.builder().bucket(context.bucketName()).build());
        }
        return getBucketAdminState(params);
    }

    private static Map<String, Object> listObjects(JsonNode params) {
        BucketContext context = bucketContext(params);
        String prefix = params.path("prefix").asText("");
        boolean flat = params.path("flat").asBoolean(false);
        String continuation = params.path("cursor").path("value").asText("");
        try (S3Client client = context.client()) {
            ListObjectsV2Request.Builder request = ListObjectsV2Request.builder()
                .bucket(context.bucketName())
                .prefix(prefix)
                .maxKeys(1000);
            if (!flat) {
                request.delimiter("/");
            }
            if (!continuation.isBlank()) {
                request.continuationToken(continuation);
            }
            var output = client.listObjectsV2(request.build());
            List<Map<String, Object>> items = new ArrayList<>();
            output.commonPrefixes().forEach(commonPrefix -> {
                String folderPrefix = commonPrefix.prefix();
                String folderName = folderPrefix.startsWith(prefix) ? folderPrefix.substring(prefix.length()) : folderPrefix;
                items.add(orderedMap(
                    "key", folderPrefix,
                    "name", folderName.isBlank() ? folderPrefix : folderName,
                    "size", 0,
                    "storageClass", "FOLDER",
                    "modifiedAt", nowIso(),
                    "isFolder", true,
                    "etag", null,
                    "metadataCount", 0
                ));
            });
            output.contents().forEach(object -> {
                String key = object.key();
                if (!flat && Objects.equals(key, prefix)) {
                    return;
                }
                String name = prefix.isBlank() || !key.startsWith(prefix) ? key : key.substring(prefix.length());
                items.add(orderedMap(
                    "key", key,
                    "name", name.isBlank() ? key : name,
                    "size", object.size(),
                    "storageClass", object.storageClassAsString(),
                    "modifiedAt", serializeTime(object.lastModified()),
                    "isFolder", false,
                    "etag", trimQuotesOrNull(object.eTag()),
                    "metadataCount", 0
                ));
            });
            items.sort((left, right) -> {
                boolean leftFolder = Boolean.TRUE.equals(left.get("isFolder"));
                boolean rightFolder = Boolean.TRUE.equals(right.get("isFolder"));
                if (leftFolder != rightFolder) {
                    return leftFolder ? -1 : 1;
                }
                return String.valueOf(left.get("key")).compareToIgnoreCase(String.valueOf(right.get("key")));
            });
            return orderedMap(
                "items", items,
                "nextCursor", orderedMap(
                    "value", output.nextContinuationToken(),
                    "hasMore", output.isTruncated()
                )
            );
        }
    }

    private static Map<String, Object> getBucketAdminState(JsonNode params) {
        BucketContext context = bucketContext(params);
        List<Map<String, Object>> apiCalls = new ArrayList<>();
        try (S3Client client = context.client()) {
            var versioning = recordApi(apiCalls, "GetBucketVersioning", () ->
                client.getBucketVersioning(GetBucketVersioningRequest.builder().bucket(context.bucketName()).build())
            );
            var encryption = optionalBucketApi(apiCalls, "GetBucketEncryption", () ->
                client.getBucketEncryption(GetBucketEncryptionRequest.builder().bucket(context.bucketName()).build())
            );
            var lifecycle = optionalBucketApi(apiCalls, "GetBucketLifecycleConfiguration", () ->
                client.getBucketLifecycleConfiguration(GetBucketLifecycleConfigurationRequest.builder().bucket(context.bucketName()).build())
            );
            var policy = optionalBucketApi(apiCalls, "GetBucketPolicy", () ->
                client.getBucketPolicy(GetBucketPolicyRequest.builder().bucket(context.bucketName()).build())
            );
            var cors = optionalBucketApi(apiCalls, "GetBucketCors", () ->
                client.getBucketCors(GetBucketCorsRequest.builder().bucket(context.bucketName()).build())
            );
            var tagging = optionalBucketApi(apiCalls, "GetBucketTagging", () ->
                client.getBucketTagging(GetBucketTaggingRequest.builder().bucket(context.bucketName()).build())
            );
            var objectLock = optionalBucketApi(apiCalls, "GetObjectLockConfiguration", () ->
                client.getObjectLockConfiguration(GetObjectLockConfigurationRequest.builder().bucket(context.bucketName()).build())
            );

            List<Map<String, Object>> lifecycleRules = new ArrayList<>();
            String lifecycleJson = "{\n  \"Rules\": []\n}";
            if (lifecycle != null) {
                lifecycle.rules().forEach(rule -> lifecycleRules.add(lifecycleRuleSummary(rule)));
                lifecycleJson = writeJson(orderedMap("Rules", lifecycle.rules().stream().map(Main::lifecycleRuleRaw).toList()));
            }

            String encryptionSummary = "Not configured";
            String encryptionJson = "{}";
            boolean encryptionEnabled = false;
            if (encryption != null && encryption.serverSideEncryptionConfiguration() != null) {
                encryptionEnabled = !encryption.serverSideEncryptionConfiguration().rules().isEmpty();
                encryptionJson = writeJson(encryptionRaw(encryption.serverSideEncryptionConfiguration()));
                if (encryptionEnabled) {
                    var applyDefault = encryption.serverSideEncryptionConfiguration().rules().getFirst().applyServerSideEncryptionByDefault();
                    encryptionSummary = applyDefault.kmsMasterKeyID() == null || applyDefault.kmsMasterKeyID().isBlank()
                        ? applyDefault.sseAlgorithmAsString()
                        : applyDefault.sseAlgorithmAsString() + " (" + applyDefault.kmsMasterKeyID() + ")";
                }
            }

            Map<String, String> tags = new LinkedHashMap<>();
            if (tagging != null) {
                tagging.tagSet().forEach(tag -> tags.put(tag.key(), tag.value()));
            }

            String policyJson = policy == null || policy.policy() == null || policy.policy().isBlank()
                ? "{}"
                : policy.policy();
            String corsJson = cors == null ? "[]" : writeJson(cors.corsRules().stream().map(Main::corsRuleRaw).toList());

            String objectLockMode = null;
            Integer objectLockRetentionDays = null;
            boolean objectLockEnabled = false;
            if (objectLock != null && objectLock.objectLockConfiguration() != null) {
                objectLockEnabled = true;
                ObjectLockConfiguration configuration = objectLock.objectLockConfiguration();
                if (configuration.rule() != null && configuration.rule().defaultRetention() != null) {
                    DefaultRetention retention = configuration.rule().defaultRetention();
                    objectLockMode = retention.modeAsString();
                    if (retention.days() != null) {
                        objectLockRetentionDays = retention.days();
                    } else if (retention.years() != null) {
                        objectLockRetentionDays = retention.years();
                    }
                }
            }

            return orderedMap(
                "bucketName", context.bucketName(),
                "versioningEnabled", versioning.status() == BucketVersioningStatus.ENABLED,
                "versioningStatus", versioning.statusAsString(),
                "objectLockEnabled", objectLockEnabled,
                "lifecycleEnabled", !lifecycleRules.isEmpty(),
                "policyAttached", policy != null && policy.policy() != null && !policy.policy().isBlank(),
                "corsEnabled", cors != null && !cors.corsRules().isEmpty(),
                "encryptionEnabled", encryptionEnabled,
                "encryptionSummary", encryptionSummary,
                "objectLockMode", objectLockMode,
                "objectLockRetentionDays", objectLockRetentionDays,
                "tags", tags,
                "lifecycleRules", lifecycleRules,
                "lifecycleJson", lifecycleJson,
                "policyJson", policyJson,
                "corsJson", corsJson,
                "encryptionJson", encryptionJson,
                "apiCalls", apiCalls
            );
        }
    }

    private static Map<String, Object> listObjectVersions(JsonNode params) {
        BucketContext context = bucketContext(params);
        String key = params.path("key").asText("");
        String filterValue = params.path("options").path("filterValue").asText("");
        String filterMode = params.path("options").path("filterMode").asText("prefix");
        String effectivePrefix = key.isBlank()
            ? ("prefix".equals(filterMode) ? filterValue : "")
            : key;
        try (S3Client client = context.client()) {
            var output = client.listObjectVersions(ListObjectVersionsRequest.builder()
                .bucket(context.bucketName())
                .prefix(effectivePrefix)
                .maxKeys(1000)
                .build());
            List<Map<String, Object>> items = new ArrayList<>();
            for (ObjectVersion version : output.versions()) {
                if (!key.isBlank() && !Objects.equals(version.key(), key)) {
                    continue;
                }
                items.add(orderedMap(
                    "key", version.key(),
                    "versionId", version.versionId(),
                    "modifiedAt", serializeTime(version.lastModified()),
                    "latest", version.isLatest(),
                    "deleteMarker", false,
                    "size", version.size(),
                    "storageClass", version.storageClassAsString()
                ));
            }
            for (DeleteMarkerEntry marker : output.deleteMarkers()) {
                if (!key.isBlank() && !Objects.equals(marker.key(), key)) {
                    continue;
                }
                items.add(orderedMap(
                    "key", marker.key(),
                    "versionId", marker.versionId(),
                    "modifiedAt", serializeTime(marker.lastModified()),
                    "latest", marker.isLatest(),
                    "deleteMarker", true,
                    "size", 0,
                    "storageClass", "DELETE_MARKER"
                ));
            }
            items.sort((left, right) -> String.valueOf(right.get("modifiedAt")).compareTo(String.valueOf(left.get("modifiedAt"))));
            long deleteMarkerCount = items.stream().filter(item -> Boolean.TRUE.equals(item.get("deleteMarker"))).count();
            return orderedMap(
                "items", items,
                "cursor", orderedMap("value", null, "hasMore", false),
                "totalCount", items.size(),
                "versionCount", items.size() - (int) deleteMarkerCount,
                "deleteMarkerCount", (int) deleteMarkerCount
            );
        }
    }

    private static Map<String, Object> getObjectDetails(JsonNode params) {
        BucketContext context = bucketContext(params);
        String key = requiredText(params, "key", "Bucket name and object key are required for object inspection.");
        List<Map<String, Object>> apiCalls = new ArrayList<>();
        List<Map<String, Object>> debugEvents = new ArrayList<>();
        debugEvents.add(orderedMap(
            "timestamp", nowIso(),
            "level", "DEBUG",
            "message", "Fetching object diagnostics for " + context.bucketName() + "/" + key + "."
        ));
        try (S3Client client = context.client()) {
            var head = recordApi(apiCalls, "HeadObject", () ->
                client.headObject(HeadObjectRequest.builder().bucket(context.bucketName()).key(key).build())
            );
            var tagging = optionalBucketApi(apiCalls, "GetObjectTagging", () ->
                client.getObjectTagging(GetObjectTaggingRequest.builder().bucket(context.bucketName()).key(key).build())
            );

            Map<String, String> metadata = new LinkedHashMap<>(head.metadata());
            Map<String, String> headers = new LinkedHashMap<>();
            putIfNotBlank(headers, "ETag", trimQuotes(head.eTag()));
            headers.put("Content-Length", String.valueOf(head.contentLength()));
            putIfNotBlank(headers, "Content-Type", head.contentType());
            putIfNotBlank(headers, "Last-Modified", serializeTime(head.lastModified()));
            putIfNotBlank(headers, "Storage-Class", head.storageClassAsString());
            putIfNotBlank(headers, "Cache-Control", head.cacheControl());

            Map<String, String> tags = new LinkedHashMap<>();
            if (tagging != null) {
                tagging.tagSet().forEach(tag -> tags.put(tag.key(), tag.value()));
            }

            debugEvents.add(orderedMap(
                "timestamp", nowIso(),
                "level", "INFO",
                "message", "Loaded metadata and " + tags.size() + " tag(s) for " + key + "."
            ));

            return orderedMap(
                "key", key,
                "metadata", metadata,
                "headers", headers,
                "tags", tags,
                "debugEvents", debugEvents,
                "apiCalls", apiCalls,
                "debugLogExcerpt", List.of(
                    "Resolved endpoint " + context.profile().endpointUrl + ".",
                    "Completed HEAD and tagging diagnostics for " + context.bucketName() + "/" + key + "."
                ),
                "rawDiagnostics", orderedMap(
                    "bucketName", context.bucketName(),
                    "engineState", "healthy"
                )
            );
        }
    }

    private static Map<String, Object> createFolder(JsonNode params) {
        BucketContext context = bucketContext(params);
        String key = requiredText(params, "key", "Bucket name and key are required to create a folder.");
        if (!key.endsWith("/")) {
            key += "/";
        }
        try (S3Client client = context.client()) {
            client.putObject(PutObjectRequest.builder()
                    .bucket(context.bucketName())
                    .key(key)
                    .build(),
                software.amazon.awssdk.core.sync.RequestBody.empty());
        }
        return orderedMap("created", true, "key", key);
    }

    private static Map<String, Object> copyObject(JsonNode params) {
        Profile profile = parseProfile(params.path("profile"));
        String sourceBucket = requiredText(params, "sourceBucketName", "Copy source and destination are required.");
        String sourceKey = requiredText(params, "sourceKey", "Copy source and destination are required.");
        String destinationBucket = requiredText(params, "destinationBucketName", "Copy source and destination are required.");
        String destinationKey = requiredText(params, "destinationKey", "Copy source and destination are required.");
        try (S3Client client = buildClient(profile)) {
            client.copyObject(CopyObjectRequest.builder()
                .copySource(urlEncode(sourceBucket + "/" + sourceKey))
                .bucket(destinationBucket)
                .key(destinationKey)
                .build());
        }
        return orderedMap("successCount", 1, "failureCount", 0, "failures", List.of());
    }

    private static Map<String, Object> moveObject(JsonNode params) {
        Map<String, Object> result = copyObject(params);
        Profile profile = parseProfile(params.path("profile"));
        try (S3Client client = buildClient(profile)) {
            client.deleteObject(DeleteObjectRequest.builder()
                .bucket(requiredText(params, "sourceBucketName", "Copy source and destination are required."))
                .key(requiredText(params, "sourceKey", "Copy source and destination are required."))
                .build());
        }
        return result;
    }

    private static Map<String, Object> deleteObjects(JsonNode params) {
        BucketContext context = bucketContext(params);
        List<String> keys = stringArray(params.path("keys"));
        if (keys.isEmpty()) {
            throw new SidecarException("invalid_config", "Bucket name and keys are required.");
        }
        try (S3Client client = context.client()) {
            var output = client.deleteObjects(DeleteObjectsRequest.builder()
                .bucket(context.bucketName())
                .delete(Delete.builder()
                    .objects(keys.stream().map(key -> ObjectIdentifier.builder().key(key).build()).toList())
                    .quiet(false)
                    .build())
                .build());
            return orderedMap(
                "successCount", output.deleted().size(),
                "failureCount", output.errors().size(),
                "failures", output.errors().stream().map(error -> orderedMap(
                    "target", error.key(),
                    "code", blankToDefault(error.code(), "unknown"),
                    "message", blankToDefault(error.message(), "Unknown delete error.")
                )).toList()
            );
        }
    }

    private static Map<String, Object> deleteObjectVersions(JsonNode params) {
        BucketContext context = bucketContext(params);
        JsonNode versionsNode = params.path("versions");
        if (!versionsNode.isArray() || versionsNode.isEmpty()) {
            throw new SidecarException("invalid_config", "Bucket name and versions are required.");
        }
        List<ObjectIdentifier> identifiers = new ArrayList<>();
        versionsNode.forEach(item -> identifiers.add(ObjectIdentifier.builder()
            .key(text(item, "key"))
            .versionId(blankToNull(text(item, "versionId")))
            .build()));
        try (S3Client client = context.client()) {
            var output = client.deleteObjects(DeleteObjectsRequest.builder()
                .bucket(context.bucketName())
                .delete(Delete.builder().objects(identifiers).quiet(false).build())
                .build());
            return orderedMap(
                "successCount", output.deleted().size(),
                "failureCount", output.errors().size(),
                "failures", output.errors().stream().map(error -> orderedMap(
                    "target", error.key(),
                    "versionId", blankToNull(error.versionId()),
                    "code", blankToDefault(error.code(), "unknown"),
                    "message", blankToDefault(error.message(), "Unknown delete error.")
                )).toList()
            );
        }
    }

    private static Map<String, Object> startUpload(JsonNode params) throws IOException {
        BucketContext context = bucketContext(params);
        List<String> filePaths = stringArray(params.path("filePaths"));
        Map<String, String> objectKeyByPath = stringMap(params.path("objectKeyByPath"));
        if (filePaths.isEmpty()) {
            throw new SidecarException("invalid_config", "Bucket name and file paths are required.");
        }
        String prefix = params.path("prefix").asText("");
        int multipartThresholdMiB = Math.max(params.path("multipartThresholdMiB").asInt(32), 1);
        int multipartChunkMiB = Math.max(params.path("multipartChunkMiB").asInt(8), 1);
        long multipartThresholdBytes = multipartThresholdMiB * 1024L * 1024L;
        int multipartChunkBytes = multipartChunkMiB * 1024 * 1024;
        List<Path> paths = filePaths.stream().map(Path::of).toList();
        long totalBytes = paths.stream().mapToLong(path -> {
            try {
                return Files.size(path);
            } catch (IOException error) {
                throw new RuntimeException(error);
            }
        }).sum();
        boolean usesMultipart = paths.stream().anyMatch(path -> {
            try {
                return Files.size(path) >= multipartThresholdBytes;
            } catch (IOException error) {
                throw new RuntimeException(error);
            }
        });
        int partsTotal = paths.stream().mapToInt(path -> {
            try {
                long size = Files.size(path);
                return size >= multipartThresholdBytes
                    ? (int) ((size + multipartChunkBytes - 1L) / multipartChunkBytes)
                    : 0;
            } catch (IOException error) {
                throw new RuntimeException(error);
            }
        }).sum();
        Integer partSizeBytes = partsTotal > 0 ? multipartChunkBytes : null;
        Integer partCount = partsTotal > 0 ? partsTotal : null;
        String jobId = "upload-" + UUID.randomUUID().toString().substring(0, 8);
        String label = "Upload " + filePaths.size() + " file(s) to " + context.bucketName();
        String strategyLabel = transferStrategyLabel("upload", usesMultipart);
        List<String> outputLines = new ArrayList<>(List.of(
            "Queued " + filePaths.size() + " file(s) for upload to " + context.bucketName() + "."
        ));
        AtomicLong bytesTransferred = new AtomicLong();
        AtomicInteger itemsCompleted = new AtomicInteger();
        AtomicInteger partsCompleted = new AtomicInteger();
        AtomicInteger partOutputLineCount = new AtomicInteger();
        Object progressLock = new Object();
        emitTransferEvent(transferJob(
            jobId,
            label,
            "upload",
            0,
            "queued",
            0L,
            totalBytes,
            strategyLabel,
            paths.getFirst().getFileName().toString(),
            filePaths.size(),
            itemsCompleted.get(),
            partSizeBytes,
            partCount == null ? null : partsCompleted.get(),
            partCount,
            true,
            false,
            true,
            List.copyOf(outputLines)
        ));
        ExecutorService executor = Executors.newFixedThreadPool(transferPoolSize(context.profile()));
        try (S3Client client = context.client()) {
            for (Path path : paths) {
                long fileSize = Files.size(path);
                String targetName = objectKeyByPath.getOrDefault(
                    path.toString(),
                    path.getFileName().toString()
                ).replace('\\', '/').replaceFirst("^/+", "");
                String key = prefix.isBlank() ? targetName : prefix + targetName;
                synchronized (progressLock) {
                    outputLines.add("Uploading " + path.getFileName() + " (" + fileSize + " bytes) to " + key + ".");
                }
                if (fileSize >= multipartThresholdBytes) {
                    String uploadId = client.createMultipartUpload(CreateMultipartUploadRequest.builder()
                        .bucket(context.bucketName())
                        .key(key)
                        .build()).uploadId();
                    int filePartCount = (int) ((fileSize + multipartChunkBytes - 1L) / multipartChunkBytes);
                    try (FileChannel channel = FileChannel.open(path, StandardOpenOption.READ)) {
                        List<Future<CompletedPart>> futures = new ArrayList<>(filePartCount);
                        for (int index = 0; index < filePartCount; index += 1) {
                            final int partNumber = index + 1;
                            final long partOffset = (long) index * multipartChunkBytes;
                            final int partLength = (int) Math.min(multipartChunkBytes, fileSize - partOffset);
                            futures.add(executor.submit(() -> {
                                byte[] chunk = readChunk(channel, partOffset, partLength);
                                var partResult = client.uploadPart(
                                    UploadPartRequest.builder()
                                        .bucket(context.bucketName())
                                        .key(key)
                                        .uploadId(uploadId)
                                        .partNumber(partNumber)
                                        .build(),
                                    RequestBody.fromBytes(chunk)
                                );
                                long transferredNow = bytesTransferred.addAndGet(partLength);
                                int partsCompletedNow = partsCompleted.incrementAndGet();
                                List<String> linesSnapshot;
                                int itemsCompletedNow;
                                synchronized (progressLock) {
                                    addPartOutputLine(outputLines, partOutputLineCount,
                                        "Uploaded part " + partNumber + " for " + path.getFileName() + ".");
                                    linesSnapshot = List.copyOf(outputLines);
                                    itemsCompletedNow = itemsCompleted.get();
                                }
                                emitTransferEvent(transferJob(
                                    jobId,
                                    label,
                                    "upload",
                                    progressFraction(transferredNow, totalBytes),
                                    "running",
                                    transferredNow,
                                    totalBytes,
                                    strategyLabel,
                                    path.getFileName().toString(),
                                    filePaths.size(),
                                    itemsCompletedNow,
                                    partSizeBytes,
                                    partsCompletedNow,
                                    partCount,
                                    true,
                                    false,
                                    true,
                                    linesSnapshot
                                ));
                                return CompletedPart.builder()
                                    .eTag(partResult.eTag())
                                    .partNumber(partNumber)
                                    .build();
                            }));
                        }
                        List<CompletedPart> completedParts = new ArrayList<>(filePartCount);
                        try {
                            for (Future<CompletedPart> future : futures) {
                                completedParts.add(future.get());
                            }
                        } catch (InterruptedException | ExecutionException error) {
                            futures.forEach(future -> future.cancel(true));
                            try {
                                client.abortMultipartUpload(AbortMultipartUploadRequest.builder()
                                    .bucket(context.bucketName())
                                    .key(key)
                                    .uploadId(uploadId)
                                    .build());
                            } catch (RuntimeException ignored) {
                            }
                            if (error instanceof InterruptedException) {
                                Thread.currentThread().interrupt();
                                throw new RuntimeException(error);
                            }
                            throw unwrapTransferFailure(error.getCause());
                        }
                        completedParts.sort(Comparator.comparingInt(CompletedPart::partNumber));
                        client.completeMultipartUpload(CompleteMultipartUploadRequest.builder()
                            .bucket(context.bucketName())
                            .key(key)
                            .uploadId(uploadId)
                            .multipartUpload(CompletedMultipartUpload.builder().parts(completedParts).build())
                            .build());
                    }
                } else {
                    client.putObject(
                        PutObjectRequest.builder()
                            .bucket(context.bucketName())
                            .key(key)
                            .build(),
                        RequestBody.fromFile(path)
                    );
                    bytesTransferred.addAndGet(fileSize);
                }
                itemsCompleted.incrementAndGet();
                synchronized (progressLock) {
                    outputLines.add("Finished uploading " + path.getFileName() + ".");
                    emitTransferEvent(transferJob(
                        jobId,
                        label,
                        "upload",
                        progressFraction(bytesTransferred.get(), totalBytes),
                        "running",
                        bytesTransferred.get(),
                        totalBytes,
                        strategyLabel,
                        path.getFileName().toString(),
                        filePaths.size(),
                        itemsCompleted.get(),
                        partSizeBytes,
                        partCount == null ? null : partsCompleted.get(),
                        partCount,
                        true,
                        false,
                        true,
                        List.copyOf(outputLines)
                    ));
                }
            }
        } catch (RuntimeException error) {
            if (error.getCause() instanceof IOException ioError) {
                throw ioError;
            }
            throw error;
        } finally {
            executor.shutdownNow();
        }
        outputLines.add("Uploaded " + filePaths.size() + " file(s) into " + context.bucketName() + ".");
        return transferJob(
            jobId,
            label,
            "upload",
            1.0,
            "completed",
            bytesTransferred.get(),
            totalBytes,
            strategyLabel,
            paths.getLast().getFileName().toString(),
            filePaths.size(),
            itemsCompleted.get(),
            partSizeBytes,
            partCount == null ? null : partsCompleted.get(),
            partCount,
            false,
            false,
            false,
            outputLines
        );
    }

    private static int transferPoolSize(Profile profile) {
        return Math.min(8, Math.max(profile.maxPoolConnections(), 1));
    }

    private static final int MAX_PART_OUTPUT_LINES = 64;

    private static void addPartOutputLine(List<String> outputLines, AtomicInteger partOutputLineCount, String line) {
        int count = partOutputLineCount.incrementAndGet();
        if (count <= MAX_PART_OUTPUT_LINES) {
            outputLines.add(line);
        } else if (count == MAX_PART_OUTPUT_LINES + 1) {
            outputLines.add("... further part progress lines omitted.");
        }
    }

    private static byte[] readChunk(FileChannel channel, long offset, int length) throws IOException {
        ByteBuffer buffer = ByteBuffer.allocate(length);
        long position = offset;
        while (buffer.hasRemaining()) {
            int read = channel.read(buffer, position);
            if (read < 0) {
                throw new IOException("Unexpected end of file at offset " + position + ".");
            }
            position += read;
        }
        return buffer.array();
    }

    private static RuntimeException unwrapTransferFailure(Throwable cause) throws IOException {
        if (cause instanceof IOException ioCause) {
            throw ioCause;
        }
        if (cause instanceof RuntimeException runtimeCause) {
            return runtimeCause;
        }
        return new RuntimeException(cause);
    }

    private static Map<String, Object> startDownload(JsonNode params) throws IOException {
        BucketContext context = bucketContext(params);
        List<String> keys = stringArray(params.path("keys"));
        String destinationPath = requiredText(params, "destinationPath", "Bucket, keys, and destination path are required.");
        if (keys.isEmpty()) {
            throw new SidecarException("invalid_config", "Bucket, keys, and destination path are required.");
        }
        Path destination = Path.of(destinationPath);
        Files.createDirectories(destination);
        int multipartThresholdMiB = Math.max(params.path("multipartThresholdMiB").asInt(32), 1);
        int multipartChunkMiB = Math.max(params.path("multipartChunkMiB").asInt(8), 1);
        long multipartThresholdBytes = multipartThresholdMiB * 1024L * 1024L;
        int multipartChunkBytes = multipartChunkMiB * 1024 * 1024;
        String jobId = "download-" + UUID.randomUUID().toString().substring(0, 8);
        String label = "Download " + keys.size() + " object(s) from " + context.bucketName();
        List<String> outputLines = new ArrayList<>(List.of(
            "Queued " + keys.size() + " object(s) for download to " + destinationPath + "."
        ));
        AtomicLong bytesTransferred = new AtomicLong();
        AtomicInteger itemsCompleted = new AtomicInteger();
        AtomicInteger partsCompleted = new AtomicInteger();
        AtomicInteger partOutputLineCount = new AtomicInteger();
        Object progressLock = new Object();
        ExecutorService executor = Executors.newFixedThreadPool(transferPoolSize(context.profile()));
        try (S3Client client = context.client()) {
            Map<String, Long> sizes = new LinkedHashMap<>();
            long totalBytesTally = 0L;
            for (String key : keys) {
                long size = client.headObject(
                    HeadObjectRequest.builder()
                        .bucket(context.bucketName())
                        .key(key)
                        .build()
                ).contentLength();
                sizes.put(key, size);
                totalBytesTally += size;
            }
            final long totalBytes = totalBytesTally;
            boolean usesMultipart = sizes.values().stream().anyMatch(size -> size >= multipartThresholdBytes);
            int partsTotal = sizes.values().stream()
                .mapToInt(size -> size >= multipartThresholdBytes
                    ? (int) ((size + multipartChunkBytes - 1L) / multipartChunkBytes)
                    : 0)
                .sum();
            Integer partSizeBytes = partsTotal > 0 ? multipartChunkBytes : null;
            Integer partCount = partsTotal > 0 ? partsTotal : null;
            String strategyLabel = transferStrategyLabel("download", usesMultipart);
            emitTransferEvent(transferJob(
                jobId,
                label,
                "download",
                0,
                "queued",
                0L,
                totalBytes,
                strategyLabel,
                keys.getFirst(),
                keys.size(),
                itemsCompleted.get(),
                partSizeBytes,
                partCount == null ? null : partsCompleted.get(),
                partCount,
                true,
                false,
                true,
                List.copyOf(outputLines)
            ));
            for (String key : keys) {
                long size = sizes.getOrDefault(key, 0L);
                Path target = destination.resolve(Path.of(key).getFileName());
                synchronized (progressLock) {
                    outputLines.add("Downloading " + key + " (" + size + " bytes) to " + target + ".");
                }
                if (size >= multipartThresholdBytes) {
                    try (RandomAccessFile file = new RandomAccessFile(target.toFile(), "rw")) {
                        file.setLength(size);
                        FileChannel channel = file.getChannel();
                        List<Future<?>> futures = new ArrayList<>();
                        for (long start = 0; start < size; start += multipartChunkBytes) {
                            final long rangeStart = start;
                            final long rangeEnd = Math.min(start + multipartChunkBytes - 1L, size - 1L);
                            futures.add(executor.submit(() -> {
                                byte[] bytes;
                                try (ResponseInputStream<?> stream = client.getObject(GetObjectRequest.builder()
                                    .bucket(context.bucketName())
                                    .key(key)
                                    .range("bytes=" + rangeStart + "-" + rangeEnd)
                                    .build())) {
                                    bytes = stream.readAllBytes();
                                }
                                long expectedLength = rangeEnd - rangeStart + 1L;
                                if (bytes.length != expectedLength) {
                                    throw new IOException("Short read for byte range " + rangeStart + "-" + rangeEnd
                                        + " of " + key + ": expected " + expectedLength + " byte(s), received "
                                        + bytes.length + ".");
                                }
                                ByteBuffer buffer = ByteBuffer.wrap(bytes);
                                long position = rangeStart;
                                while (buffer.hasRemaining()) {
                                    position += channel.write(buffer, position);
                                }
                                long transferredNow = bytesTransferred.addAndGet(bytes.length);
                                int partsCompletedNow = partsCompleted.incrementAndGet();
                                List<String> linesSnapshot;
                                int itemsCompletedNow;
                                synchronized (progressLock) {
                                    addPartOutputLine(outputLines, partOutputLineCount,
                                        "Downloaded byte range " + rangeStart + "-" + rangeEnd + " for " + key + ".");
                                    linesSnapshot = List.copyOf(outputLines);
                                    itemsCompletedNow = itemsCompleted.get();
                                }
                                emitTransferEvent(transferJob(
                                    jobId,
                                    label,
                                    "download",
                                    progressFraction(transferredNow, totalBytes),
                                    "running",
                                    transferredNow,
                                    totalBytes,
                                    strategyLabel,
                                    key,
                                    keys.size(),
                                    itemsCompletedNow,
                                    partSizeBytes,
                                    partsCompletedNow,
                                    partCount,
                                    true,
                                    false,
                                    true,
                                    linesSnapshot
                                ));
                                return null;
                            }));
                        }
                        try {
                            for (Future<?> future : futures) {
                                future.get();
                            }
                        } catch (InterruptedException | ExecutionException error) {
                            futures.forEach(future -> future.cancel(true));
                            if (error instanceof InterruptedException) {
                                Thread.currentThread().interrupt();
                                throw new RuntimeException(error);
                            }
                            throw unwrapTransferFailure(error.getCause());
                        }
                    }
                } else {
                    try (OutputStream outputStream = Files.newOutputStream(target);
                         ResponseInputStream<?> stream = client.getObject(GetObjectRequest.builder()
                             .bucket(context.bucketName())
                             .key(key)
                             .build())) {
                        byte[] buffer = new byte[Math.min(multipartChunkBytes, 1024 * 1024)];
                        int read;
                        while ((read = stream.read(buffer)) != -1) {
                            outputStream.write(buffer, 0, read);
                            long transferredNow = bytesTransferred.addAndGet(read);
                            synchronized (progressLock) {
                                emitTransferEvent(transferJob(
                                    jobId,
                                    label,
                                    "download",
                                    progressFraction(transferredNow, totalBytes),
                                    "running",
                                    transferredNow,
                                    totalBytes,
                                    strategyLabel,
                                    key,
                                    keys.size(),
                                    itemsCompleted.get(),
                                    partSizeBytes,
                                    partCount == null ? null : partsCompleted.get(),
                                    partCount,
                                    true,
                                    false,
                                    true,
                                    List.copyOf(outputLines)
                                ));
                            }
                        }
                    }
                }
                itemsCompleted.incrementAndGet();
                synchronized (progressLock) {
                    outputLines.add("Finished downloading " + key + ".");
                }
            }
            outputLines.add("Downloaded " + keys.size() + " object(s) into " + destinationPath + ".");
            return transferJob(
                jobId,
                label,
                "download",
                1.0,
                "completed",
                bytesTransferred.get(),
                totalBytes,
                strategyLabel,
                keys.getLast(),
                keys.size(),
                itemsCompleted.get(),
                partSizeBytes,
                partCount == null ? null : partsCompleted.get(),
                partCount,
                false,
                false,
                false,
                outputLines
            );
        } finally {
            executor.shutdownNow();
        }
    }

    private static Map<String, Object> transferControl(JsonNode params, String action) {
        String jobId = blankToDefault(text(params, "jobId"), "transfer-" + UUID.randomUUID().toString().substring(0, 8));
        return transferJob(
            jobId,
            "Transfer " + action,
            "transfer",
            "cancelled".equals(action) ? 1.0 : 0.0,
            action,
            0,
            0,
            "",
            "",
            0,
            0,
            null,
            null,
            null,
            false,
            false,
            false,
            List.of("Transfer " + action + ".")
        );
    }

    private static Map<String, Object> generatePresignedUrl(JsonNode params) {
        Profile profile = parseProfile(params.path("profile"));
        String bucketName = requiredText(params, "bucketName", "Bucket name and object key are required to generate a presigned URL.");
        String key = requiredText(params, "key", "Bucket name and object key are required to generate a presigned URL.");
        int expirationSeconds = Math.max(params.path("expirationSeconds").asInt(3600), 1);
        AwsCredentialsProvider credentialsProvider = credentialsProvider(profile);
        S3Configuration serviceConfiguration = S3Configuration.builder().pathStyleAccessEnabled(profile.pathStyle).build();
        var builder = S3Presigner.builder()
            .region(Region.of(profile.region))
            .credentialsProvider(credentialsProvider)
            .endpointOverride(URI.create(profile.endpointUrl))
            .serviceConfiguration(serviceConfiguration);
        try (S3Presigner presigner = builder.build()) {
            var request = GetObjectPresignRequest.builder()
                .signatureDuration(Duration.ofSeconds(expirationSeconds))
                .getObjectRequest(requestBuilder -> requestBuilder.bucket(bucketName).key(key))
                .build();
            return orderedMap("url", presigner.presignGetObject(request).url().toString());
        }
    }

    private static Map<String, Object> runPutTestData(JsonNode params) {
        Profile profile = parseProfile(params.path("profile"));
        JsonNode config = params.path("config");
        String bucketName = requiredText(config, "bucketName", "Bucket name is required for put-testdata.");
        String rawPrefix = text(config, "prefix").trim();
        String prefix = rawPrefix.isBlank() || rawPrefix.endsWith("/") ? rawPrefix : rawPrefix + "/";
        int objectCount = Math.max(config.path("objectCount").asInt(1), 0);
        int objectSizeBytes = Math.max(config.path("objectSizeBytes").asInt(1024), 0);
        int versions = Math.max(config.path("versions").asInt(1), 1);
        int threads = Math.min(Math.max(config.path("threads").asInt(4), 1), 16);
        long started = System.nanoTime();
        AtomicInteger putsCompleted = new AtomicInteger();
        AtomicInteger objectsCompleted = new AtomicInteger();
        AtomicInteger failedObjects = new AtomicInteger();
        List<String> failures = Collections.synchronizedList(new ArrayList<>());
        byte[] payload = new byte[objectSizeBytes];
        for (int index = 0; index < payload.length; index += 1) {
            payload[index] = (byte) ('A' + (index % 26));
        }
        ExecutorService executor = Executors.newFixedThreadPool(threads);
        try (S3Client client = buildClient(profile)) {
            List<Future<?>> futures = new ArrayList<>(objectCount);
            for (int index = 0; index < objectCount; index += 1) {
                final String key = prefix + "testdata-" + String.format("%06d", index) + ".bin";
                futures.add(executor.submit(() -> {
                    try {
                        for (int version = 0; version < versions; version += 1) {
                            client.putObject(
                                PutObjectRequest.builder().bucket(bucketName).key(key).build(),
                                RequestBody.fromContentProvider(
                                    () -> new ByteArrayInputStream(payload),
                                    payload.length,
                                    "application/octet-stream"
                                )
                            );
                            putsCompleted.incrementAndGet();
                        }
                        objectsCompleted.incrementAndGet();
                    } catch (Exception error) {
                        failedObjects.incrementAndGet();
                        if (failures.size() < 10) {
                            failures.add("Failed " + key + ": " + mapException(error).message);
                        }
                    }
                }));
            }
            for (Future<?> future : futures) {
                future.get();
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            failedObjects.incrementAndGet();
            failures.add("Interrupted while writing test data.");
        } catch (ExecutionException error) {
            failedObjects.incrementAndGet();
            failures.add("Worker failed: " + (error.getCause() instanceof Exception cause
                ? mapException(cause).message
                : String.valueOf(error.getCause())));
        } finally {
            executor.shutdownNow();
        }
        double durationSeconds = (System.nanoTime() - started) / 1_000_000_000.0;
        boolean failed = failedObjects.get() > 0;
        List<String> outputLines = new ArrayList<>(List.of(
            "Bucket: " + bucketName,
            "Prefix: " + prefix,
            "Threads: " + threads,
            "Object size: " + objectSizeBytes + " byte(s), versions per object: " + versions + ".",
            "Created " + objectsCompleted.get() + "/" + objectCount + " object(s) with "
                + putsCompleted.get() + " put(s) total.",
            String.format(java.util.Locale.US, "Duration: %.2fs.", durationSeconds)
        ));
        synchronized (failures) {
            outputLines.addAll(failures);
        }
        if (failed && failedObjects.get() > failures.size()) {
            outputLines.add("... plus " + (failedObjects.get() - failures.size()) + " more failed object(s).");
        }
        return orderedMap(
            "label", "put-testdata",
            "running", false,
            "lastStatus", failed
                ? "put-testdata completed with " + failedObjects.get() + " failed object(s)."
                : "Created " + objectsCompleted.get() + " object(s) with " + versions
                    + " version(s) each in " + bucketName + ".",
            "jobId", "tool-" + UUID.randomUUID().toString().substring(0, 8),
            "cancellable", false,
            "outputLines", outputLines,
            "exitCode", failed ? 1 : 0
        );
    }

    private static Map<String, Object> runDeleteAll(JsonNode params) {
        Profile profile = parseProfile(params.path("profile"));
        JsonNode config = params.path("config");
        String bucketName = requiredText(config, "bucketName", "Bucket name is required for delete-all.");
        String prefix = text(config, "prefix").trim();
        int listMaxKeys = Math.min(Math.max(config.path("listMaxKeys").asInt(1000), 1), 1000);
        int batchSize = Math.min(Math.max(config.path("batchSize").asInt(1000), 1), 1000);
        int maxWorkers = Math.min(Math.max(config.path("maxWorkers").asInt(4), 1), 16);
        long deletionDelayMs = Math.max(config.path("deletionDelayMs").asLong(0), 0L);
        long started = System.nanoTime();
        AtomicLong deletedCount = new AtomicLong();
        AtomicLong errorCount = new AtomicLong();
        List<String> failures = Collections.synchronizedList(new ArrayList<>());
        boolean versionListingSupported = true;
        boolean versionListingSucceeded = false;
        long listedTotal = 0;
        int pageCount = 0;
        ExecutorService executor = Executors.newFixedThreadPool(maxWorkers);
        try (S3Client client = buildClient(profile)) {
            while (true) {
                List<ObjectIdentifier> identifiers = new ArrayList<>();
                if (versionListingSupported) {
                    try {
                        var output = client.listObjectVersions(ListObjectVersionsRequest.builder()
                            .bucket(bucketName)
                            .prefix(prefix)
                            .maxKeys(listMaxKeys)
                            .build());
                        output.versions().forEach(version -> identifiers.add(ObjectIdentifier.builder()
                            .key(version.key())
                            .versionId(version.versionId())
                            .build()));
                        output.deleteMarkers().forEach(marker -> identifiers.add(ObjectIdentifier.builder()
                            .key(marker.key())
                            .versionId(marker.versionId())
                            .build()));
                        versionListingSucceeded = true;
                    } catch (S3Exception | SdkClientException error) {
                        if (versionListingSucceeded) {
                            // Version listing worked before, so this is a transient failure rather than a
                            // capability gap. Falling back to listObjectsV2 here would delete without
                            // VersionId and report success while versions remain; fail the run instead.
                            errorCount.incrementAndGet();
                            failures.add("Version listing failed mid-run: " + mapException(error).message);
                            break;
                        }
                        versionListingSupported = false;
                    }
                }
                if (!versionListingSupported) {
                    var output = client.listObjectsV2(ListObjectsV2Request.builder()
                        .bucket(bucketName)
                        .prefix(prefix)
                        .maxKeys(listMaxKeys)
                        .build());
                    output.contents().forEach(object -> identifiers.add(ObjectIdentifier.builder()
                        .key(object.key())
                        .build()));
                }
                if (identifiers.isEmpty()) {
                    break;
                }
                listedTotal += identifiers.size();
                pageCount += 1;
                long deletedBefore = deletedCount.get();
                List<Future<?>> futures = new ArrayList<>();
                for (int offset = 0; offset < identifiers.size(); offset += batchSize) {
                    if (offset > 0 && deletionDelayMs > 0) {
                        Thread.sleep(deletionDelayMs);
                    }
                    final List<ObjectIdentifier> batch = List.copyOf(
                        identifiers.subList(offset, Math.min(offset + batchSize, identifiers.size()))
                    );
                    futures.add(executor.submit(() -> {
                        try {
                            var response = client.deleteObjects(DeleteObjectsRequest.builder()
                                .bucket(bucketName)
                                .delete(Delete.builder().objects(batch).quiet(true).build())
                                .build());
                            int errors = response.errors().size();
                            deletedCount.addAndGet(batch.size() - errors);
                            if (errors > 0) {
                                errorCount.addAndGet(errors);
                                response.errors().stream().limit(3).forEach(deleteError -> {
                                    if (failures.size() < 10) {
                                        failures.add("Failed " + deleteError.key() + ": "
                                            + blankToDefault(deleteError.message(),
                                                blankToDefault(deleteError.code(), "delete error")));
                                    }
                                });
                            }
                        } catch (Exception error) {
                            errorCount.addAndGet(batch.size());
                            if (failures.size() < 10) {
                                failures.add("Batch delete failed: " + mapException(error).message);
                            }
                        }
                    }));
                }
                for (Future<?> future : futures) {
                    future.get();
                }
                if (deletedCount.get() == deletedBefore) {
                    failures.add("No progress on the last pass; aborting to avoid an endless loop.");
                    break;
                }
                if (deletionDelayMs > 0) {
                    Thread.sleep(deletionDelayMs);
                }
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            errorCount.incrementAndGet();
            failures.add("Interrupted while deleting objects.");
        } catch (ExecutionException error) {
            errorCount.incrementAndGet();
            failures.add("Worker failed: " + (error.getCause() instanceof Exception cause
                ? mapException(cause).message
                : String.valueOf(error.getCause())));
        } finally {
            executor.shutdownNow();
        }
        double durationSeconds = (System.nanoTime() - started) / 1_000_000_000.0;
        boolean failed = errorCount.get() > 0 || !failures.isEmpty();
        List<String> outputLines = new ArrayList<>(List.of(
            "Bucket: " + bucketName,
            "Prefix: " + (prefix.isBlank() ? "(entire bucket)" : prefix),
            "Listing mode: " + (versionListingSupported ? "object versions" : "objects (versions unsupported)"),
            "Page size: " + listMaxKeys + ", batch size: " + batchSize + ", workers: " + maxWorkers
                + ", delay: " + deletionDelayMs + "ms.",
            "Deleted " + deletedCount.get() + " of " + listedTotal + " listed entrie(s) across "
                + pageCount + " page(s).",
            String.format(java.util.Locale.US, "Duration: %.2fs.", durationSeconds)
        ));
        synchronized (failures) {
            outputLines.addAll(failures);
        }
        return orderedMap(
            "label", "delete-all",
            "running", false,
            "lastStatus", failed
                ? "delete-all completed with " + errorCount.get() + " failure(s)."
                : "Deleted " + deletedCount.get() + " entrie(s) from " + bucketName + ".",
            "jobId", "tool-" + UUID.randomUUID().toString().substring(0, 8),
            "cancellable", false,
            "outputLines", outputLines,
            "exitCode", failed ? 1 : 0
        );
    }

    private static Map<String, Object> cancelToolExecution(JsonNode params) {
        String jobId = text(params, "jobId");
        return orderedMap(
            "label", blankToDefault(jobId, "tool"),
            "running", false,
            "lastStatus", "Cancelled tool execution " + jobId + ".",
            "jobId", jobId,
            "cancellable", false,
            "outputLines", List.of("Tool execution " + jobId + " cancelled."),
            "exitCode", 130
        );
    }

    private static Map<String, Object> startBenchmark(JsonNode params) throws IOException {
        if (!params.hasNonNull("profile")) {
            throw new SidecarException("invalid_config", "Profile configuration is required for benchmark runs.");
        }
        JsonNode config = params.path("config");
        String runId = "bench-" + UUID.randomUUID().toString().substring(0, 8);
        Map<String, Object> state = orderedMap(
            "id", runId,
            "profile", MAPPER.convertValue(params.path("profile"), new TypeReference<Map<String, Object>>() {}),
            "config", MAPPER.convertValue(config, new TypeReference<Map<String, Object>>() {}),
            "status", "running",
            "processedCount", 0,
            "startedAt", nowIso(),
            "lastUpdatedAt", nowIso(),
            "activeElapsedSeconds", 0.0,
            "completedAt", null,
            "averageLatencyMs", 0,
            "throughputOpsPerSecond", 0,
            "liveLog", List.of("Benchmark scheduled."),
            "resultSummary", null,
            "history", List.of(),
            "activeObjects", List.of(),
            "nextObjectIndex", 0,
            "nextActiveIndex", 0,
            "nextSizeIndex", 0,
            "benchmarkPrefix", benchmarkBasePrefix(
                MAPPER.convertValue(config, new TypeReference<Map<String, Object>>() {}),
                runId
            )
        );
        @SuppressWarnings("unchecked")
        Map<String, Object> configMap = (Map<String, Object>) state.get("config");
        @SuppressWarnings("unchecked")
        Map<String, Object> profileMap = (Map<String, Object>) state.get("profile");
        appendBenchmarkLog(
            state,
            "Benchmark target bucket: "
                + String.valueOf(configMap.getOrDefault("bucketName", ""))
                + " via "
                + String.valueOf(profileMap.getOrDefault("endpointUrl", ""))
                + "."
        );
        writeBenchmarkState(state);
        return materializeBenchmarkState(state);
    }

    private static Map<String, Object> getBenchmarkStatus(JsonNode params) throws IOException {
        return materializeBenchmarkState(readBenchmarkState(requiredText(params, "runId", "Benchmark run ID is required.")));
    }

    private static Map<String, Object> pauseBenchmark(JsonNode params) throws IOException {
        Map<String, Object> state = readBenchmarkState(requiredText(params, "runId", "Benchmark run ID is required."));
        refreshBenchmarkSnapshot(state);
        state.put("status", "paused");
        appendBenchmarkLog(state, "Benchmark paused by user.");
        writeBenchmarkState(state);
        persistBenchmarkOutputs(state);
        return state;
    }

    private static Map<String, Object> resumeBenchmark(JsonNode params) throws IOException {
        Map<String, Object> state = readBenchmarkState(requiredText(params, "runId", "Benchmark run ID is required."));
        state.put("status", "running");
        state.put("lastUpdatedAt", nowIso());
        appendBenchmarkLog(state, "Benchmark resumed by user.");
        writeBenchmarkState(state);
        return materializeBenchmarkState(state);
    }

    private static Map<String, Object> stopBenchmark(JsonNode params) throws IOException {
        Map<String, Object> state = readBenchmarkState(requiredText(params, "runId", "Benchmark run ID is required."));
        refreshBenchmarkSnapshot(state);
        state.put("status", "stopped");
        state.put("completedAt", nowIso());
        state.put("resultSummary", benchmarkSummaryFromState(state));
        appendBenchmarkLog(state, "Benchmark stopped by user.");
        writeBenchmarkState(state);
        persistBenchmarkOutputs(state);
        return state;
    }

    private static Map<String, Object> exportBenchmarkResults(JsonNode params) throws IOException {
        Map<String, Object> state = getBenchmarkStatus(params);
        @SuppressWarnings("unchecked")
        Map<String, Object> config = (Map<String, Object>) state.get("config");
        String format = params.path("format").asText("csv").toLowerCase();
        String path = "json".equals(format)
            ? String.valueOf(config.get("jsonOutputPath"))
            : String.valueOf(config.get("csvOutputPath"));
        return orderedMap(
            "format", format,
            "path", path,
            "summary", state.get("resultSummary")
        );
    }

    private static Profile parseProfile(JsonNode payload) {
        if ("azureBlob".equals(payload.path("endpointType").asText("").trim())) {
            throw new SidecarException(
                "unsupported_feature",
                "Azure Blob profiles are not supported by the java engine yet. Switch the engine to Go or Python in Settings."
            );
        }
        String endpointUrl = payload.path("endpointUrl").asText("").trim();
        String accessKey = payload.path("accessKey").asText("").trim();
        String secretKey = payload.path("secretKey").asText("").trim();
        String region = payload.path("region").asText("us-east-1").trim();
        if (endpointUrl.isBlank()) {
            throw new SidecarException("invalid_config", "Endpoint URL is required.");
        }
        if (accessKey.isBlank() || secretKey.isBlank()) {
            throw new SidecarException("invalid_config", "Access key and secret key are required.");
        }
        return new Profile(
            endpointUrl,
            region.isBlank() ? "us-east-1" : region,
            accessKey,
            secretKey,
            payload.path("sessionToken").asText("").trim(),
            payload.path("pathStyle").asBoolean(false),
            !payload.has("verifyTls") || payload.path("verifyTls").asBoolean(true),
            Math.max(payload.path("connectTimeoutSeconds").asInt(5), 1),
            Math.max(payload.path("readTimeoutSeconds").asInt(60), 1),
            Math.max(payload.path("maxAttempts").asInt(5), 1),
            Math.max(payload.path("maxConcurrentRequests").asInt(10), 1),
            payload.path("diagnostics").path("enableApiLogging").asBoolean(false),
            payload.path("diagnostics").path("enableDebugLogging").asBoolean(false)
        );
    }

    private static S3Client buildClient(Profile profile) {
        ApacheHttpClient.Builder httpClient = ApacheHttpClient.builder()
            .connectionTimeout(Duration.ofSeconds(profile.connectTimeoutSeconds))
            .socketTimeout(Duration.ofSeconds(profile.readTimeoutSeconds))
            .maxConnections(profile.maxPoolConnections);
        if (!profile.verifyTls) {
            httpClient.tlsTrustManagersProvider(() -> TRUST_ALL_MANAGERS);
        }
        ClientOverrideConfiguration overrides = ClientOverrideConfiguration.builder()
            .retryPolicy(RetryPolicy.builder().numRetries(Math.max(profile.maxAttempts - 1, 0)).build())
            .apiCallAttemptTimeout(Duration.ofSeconds(profile.readTimeoutSeconds))
            .build();
        return S3Client.builder()
            .endpointOverride(URI.create(profile.endpointUrl))
            .region(Region.of(profile.region))
            .credentialsProvider(credentialsProvider(profile))
            .serviceConfiguration(S3Configuration.builder().pathStyleAccessEnabled(profile.pathStyle).build())
            .httpClientBuilder(httpClient)
            .overrideConfiguration(overrides)
            .build();
    }

    private static AwsCredentialsProvider credentialsProvider(Profile profile) {
        if (!profile.sessionToken.isBlank()) {
            return StaticCredentialsProvider.create(AwsSessionCredentials.create(
                profile.accessKey,
                profile.secretKey,
                profile.sessionToken
            ));
        }
        return StaticCredentialsProvider.create(AwsBasicCredentials.create(profile.accessKey, profile.secretKey));
    }

    private static BucketContext bucketContext(JsonNode params) {
        Profile profile = parseProfile(params.path("profile"));
        String bucketName = requiredText(params, "bucketName", "Bucket name is required.");
        return new BucketContext(profile, bucketName, buildClient(profile));
    }

    private static <T> T recordApi(List<Map<String, Object>> apiCalls, String operation, ThrowingSupplier<T> fn) {
        long started = System.nanoTime();
        try {
            T result = fn.get();
            apiCalls.add(orderedMap(
                "timestamp", nowIso(),
                "operation", operation,
                "status", "200",
                "latencyMs", Duration.ofNanos(System.nanoTime() - started).toMillis()
            ));
            return result;
        } catch (RuntimeException error) {
            apiCalls.add(orderedMap(
                "timestamp", nowIso(),
                "operation", operation,
                "status", "ERROR",
                "latencyMs", Duration.ofNanos(System.nanoTime() - started).toMillis()
            ));
            throw error;
        } catch (Exception error) {
            apiCalls.add(orderedMap(
                "timestamp", nowIso(),
                "operation", operation,
                "status", "ERROR",
                "latencyMs", Duration.ofNanos(System.nanoTime() - started).toMillis()
            ));
            throw new RuntimeException(error);
        }
    }

    private static <T> T optionalBucketApi(List<Map<String, Object>> apiCalls, String operation, ThrowingSupplier<T> fn) {
        try {
            return recordApi(apiCalls, operation, fn);
        } catch (RuntimeException error) {
            Throwable cause = error.getCause() != null ? error.getCause() : error;
            if (cause instanceof S3Exception s3 && MISSING_BUCKET_CONFIGURATION_CODES.contains(s3.awsErrorDetails().errorCode())) {
                return null;
            }
            throw error;
        }
    }

    private static final List<String> MISSING_BUCKET_CONFIGURATION_CODES = List.of(
        "NoSuchLifecycleConfiguration",
        "NoSuchBucketPolicy",
        "NoSuchCORSConfiguration",
        "NoSuchBucket",
        "NoSuchTagSet",
        "ObjectLockConfigurationNotFoundError",
        "NoSuchObjectLockConfiguration",
        "ServerSideEncryptionConfigurationNotFoundError",
        "MethodNotAllowed",
        "NotImplemented",
        "XNotImplemented"
    );

    private static List<LifecycleRule> parseLifecycleRules(JsonNode rulesNode) {
        List<LifecycleRule> rules = new ArrayList<>();
        if (!rulesNode.isArray()) {
            return rules;
        }
        for (JsonNode rule : rulesNode) {
            LifecycleRule.Builder builder = LifecycleRule.builder();
            putIfNotBlank(builder::id, textEither(rule, "ID", "id"));
            builder.status("Enabled".equalsIgnoreCase(text(rule, "Status"))
                ? ExpirationStatus.ENABLED
                : ExpirationStatus.DISABLED);
            String prefix = text(rule.path("Filter"), "Prefix");
            if (prefix.isBlank()) {
                prefix = textEither(rule, "Prefix", "prefix");
            }
            if (!prefix.isBlank()) {
                builder.filter(LifecycleRuleFilter.builder().prefix(prefix).build());
            }

            JsonNode expirationNode = rule.path("Expiration");
            if (!expirationNode.isMissingNode() && !expirationNode.isNull()) {
                LifecycleExpiration.Builder expiration = LifecycleExpiration.builder();
                if (expirationNode.has("Days")) {
                    expiration.days(expirationNode.path("Days").asInt());
                }
                if (expirationNode.has("ExpiredObjectDeleteMarker")) {
                    expiration.expiredObjectDeleteMarker(expirationNode.path("ExpiredObjectDeleteMarker").asBoolean(false));
                }
                builder.expiration(expiration.build());
            }

            if (rule.path("Transitions").isArray()) {
                List<Transition> transitions = new ArrayList<>();
                for (JsonNode transitionNode : rule.path("Transitions")) {
                    Transition.Builder transition = Transition.builder();
                    if (transitionNode.has("Days")) {
                        transition.days(transitionNode.path("Days").asInt());
                    }
                    putIfNotBlank(value ->
                        transition.storageClass(software.amazon.awssdk.services.s3.model.TransitionStorageClass.fromValue(value))
                    , text(transitionNode, "StorageClass"));
                    transitions.add(transition.build());
                }
                builder.transitions(transitions);
            }

            JsonNode nonCurrentExpiration = rule.path("NoncurrentVersionExpiration");
            if (!nonCurrentExpiration.isMissingNode() && !nonCurrentExpiration.isNull()) {
                builder.noncurrentVersionExpiration(NoncurrentVersionExpiration.builder()
                    .noncurrentDays(nonCurrentExpiration.path("NoncurrentDays").asInt())
                    .build());
            }

            if (rule.path("NoncurrentVersionTransitions").isArray()) {
                List<NoncurrentVersionTransition> transitions = new ArrayList<>();
                for (JsonNode transitionNode : rule.path("NoncurrentVersionTransitions")) {
                    NoncurrentVersionTransition.Builder transition = NoncurrentVersionTransition.builder();
                    if (transitionNode.has("NoncurrentDays")) {
                        transition.noncurrentDays(transitionNode.path("NoncurrentDays").asInt());
                    }
                    putIfNotBlank(value ->
                        transition.storageClass(software.amazon.awssdk.services.s3.model.TransitionStorageClass.fromValue(value))
                    , text(transitionNode, "StorageClass"));
                    transitions.add(transition.build());
                }
                builder.noncurrentVersionTransitions(transitions);
            }

            JsonNode abortNode = rule.path("AbortIncompleteMultipartUpload");
            if (!abortNode.isMissingNode() && !abortNode.isNull() && abortNode.has("DaysAfterInitiation")) {
                builder.abortIncompleteMultipartUpload(AbortIncompleteMultipartUpload.builder()
                    .daysAfterInitiation(abortNode.path("DaysAfterInitiation").asInt())
                    .build());
            }
            rules.add(builder.build());
        }
        return rules;
    }

    private static List<CORSRule> parseCorsRules(JsonNode rulesNode) {
        List<CORSRule> rules = new ArrayList<>();
        if (!rulesNode.isArray()) {
            return rules;
        }
        for (JsonNode rule : rulesNode) {
            CORSRule.Builder builder = CORSRule.builder();
            builder.allowedHeaders(stringArray(rule.path("AllowedHeaders")));
            builder.allowedMethods(stringArray(rule.path("AllowedMethods")));
            builder.allowedOrigins(stringArray(rule.path("AllowedOrigins")));
            builder.exposeHeaders(stringArray(rule.path("ExposeHeaders")));
            putIfNotBlank(builder::id, text(rule, "ID"));
            if (rule.has("MaxAgeSeconds")) {
                builder.maxAgeSeconds(rule.path("MaxAgeSeconds").asInt());
            }
            rules.add(builder.build());
        }
        return rules;
    }

    private static ServerSideEncryptionConfiguration parseEncryptionConfiguration(JsonNode node) {
        List<ServerSideEncryptionRule> rules = new ArrayList<>();
        JsonNode rulesNode = node.path("Rules");
        if (rulesNode.isArray()) {
            for (JsonNode ruleNode : rulesNode) {
                ServerSideEncryptionRule.Builder rule = ServerSideEncryptionRule.builder();
                JsonNode applyDefault = ruleNode.path("ApplyServerSideEncryptionByDefault");
                if (!applyDefault.isMissingNode() && !applyDefault.isNull()) {
                    ServerSideEncryptionByDefault.Builder defaults = ServerSideEncryptionByDefault.builder();
                    putIfNotBlank(value ->
                        defaults.sseAlgorithm(software.amazon.awssdk.services.s3.model.ServerSideEncryption.fromValue(value))
                    , text(applyDefault, "SSEAlgorithm"));
                    putIfNotBlank(defaults::kmsMasterKeyID, text(applyDefault, "KMSMasterKeyID"));
                    rule.applyServerSideEncryptionByDefault(defaults.build());
                }
                if (ruleNode.has("BucketKeyEnabled")) {
                    rule.bucketKeyEnabled(ruleNode.path("BucketKeyEnabled").asBoolean(false));
                }
                rules.add(rule.build());
            }
        }
        return ServerSideEncryptionConfiguration.builder().rules(rules).build();
    }

    private static Map<String, Object> lifecycleRuleSummary(LifecycleRule rule) {
        Transition transition = rule.transitions().isEmpty() ? null : rule.transitions().getFirst();
        NoncurrentVersionTransition noncurrent = rule.noncurrentVersionTransitions().isEmpty()
            ? null
            : rule.noncurrentVersionTransitions().getFirst();
        return orderedMap(
            "id", blankToDefault(rule.id(), "rule"),
            "enabled", rule.status() == ExpirationStatus.ENABLED,
            "prefix", rule.filter() != null ? blankToDefault(rule.filter().prefix(), "") : "",
            "expirationDays", rule.expiration() != null ? rule.expiration().days() : null,
            "deleteExpiredObjectDeleteMarkers", rule.expiration() != null && Boolean.TRUE.equals(rule.expiration().expiredObjectDeleteMarker()),
            "transitionStorageClass", transition == null ? null : transition.storageClassAsString(),
            "transitionDays", transition == null ? null : transition.days(),
            "nonCurrentExpirationDays", rule.noncurrentVersionExpiration() == null ? null : rule.noncurrentVersionExpiration().noncurrentDays(),
            "nonCurrentTransitionStorageClass", noncurrent == null ? null : noncurrent.storageClassAsString(),
            "nonCurrentTransitionDays", noncurrent == null ? null : noncurrent.noncurrentDays(),
            "abortIncompleteMultipartUploadDays",
            rule.abortIncompleteMultipartUpload() == null ? null : rule.abortIncompleteMultipartUpload().daysAfterInitiation()
        );
    }

    private static Map<String, Object> lifecycleRuleRaw(LifecycleRule rule) {
        List<Map<String, Object>> transitions = rule.transitions().stream().map(transition -> orderedMap(
            "Days", transition.days(),
            "StorageClass", transition.storageClassAsString()
        )).toList();
        List<Map<String, Object>> nonCurrentTransitions = rule.noncurrentVersionTransitions().stream().map(transition -> orderedMap(
            "NoncurrentDays", transition.noncurrentDays(),
            "StorageClass", transition.storageClassAsString()
        )).toList();
        return orderedMap(
            "ID", blankToNull(rule.id()),
            "Status", rule.statusAsString(),
            "Filter", orderedMap("Prefix", rule.filter() == null ? "" : blankToDefault(rule.filter().prefix(), "")),
            "Expiration", rule.expiration() == null ? null : orderedMap(
                "Days", rule.expiration().days(),
                "ExpiredObjectDeleteMarker", rule.expiration().expiredObjectDeleteMarker()
            ),
            "Transitions", transitions,
            "NoncurrentVersionExpiration", rule.noncurrentVersionExpiration() == null ? null : orderedMap(
                "NoncurrentDays", rule.noncurrentVersionExpiration().noncurrentDays()
            ),
            "NoncurrentVersionTransitions", nonCurrentTransitions,
            "AbortIncompleteMultipartUpload", rule.abortIncompleteMultipartUpload() == null ? null : orderedMap(
                "DaysAfterInitiation", rule.abortIncompleteMultipartUpload().daysAfterInitiation()
            )
        );
    }

    private static Map<String, Object> corsRuleRaw(CORSRule rule) {
        return orderedMap(
            "AllowedHeaders", rule.allowedHeaders(),
            "AllowedMethods", rule.allowedMethods(),
            "AllowedOrigins", rule.allowedOrigins(),
            "ExposeHeaders", rule.exposeHeaders(),
            "ID", rule.id(),
            "MaxAgeSeconds", rule.maxAgeSeconds()
        );
    }

    private static Map<String, Object> encryptionRaw(ServerSideEncryptionConfiguration configuration) {
        return orderedMap(
            "Rules", configuration.rules().stream().map(rule -> orderedMap(
                "ApplyServerSideEncryptionByDefault",
                rule.applyServerSideEncryptionByDefault() == null
                    ? null
                    : orderedMap(
                        "SSEAlgorithm", rule.applyServerSideEncryptionByDefault().sseAlgorithmAsString(),
                        "KMSMasterKeyID", rule.applyServerSideEncryptionByDefault().kmsMasterKeyID()
                    ),
                "BucketKeyEnabled", rule.bucketKeyEnabled()
            )).toList()
        );
    }

    private static Map<String, Object> transferJob(
        String jobId,
        String label,
        String direction,
        double progress,
        String status,
        long bytesTransferred,
        long totalBytes,
        String strategyLabel,
        String currentItemLabel,
        int itemCount,
        int itemsCompleted,
        Integer partSizeBytes,
        Integer partsCompleted,
        Integer partsTotal,
        boolean canPause,
        boolean canResume,
        boolean canCancel,
        List<String> outputLines
    ) {
        return orderedMap(
            "id", jobId,
            "label", label,
            "direction", direction,
            "progress", progress,
            "status", status,
            "bytesTransferred", bytesTransferred,
            "totalBytes", totalBytes,
            "strategyLabel", blankToNull(strategyLabel),
            "currentItemLabel", blankToNull(currentItemLabel),
            "itemCount", itemCount,
            "itemsCompleted", itemsCompleted,
            "partSizeBytes", partSizeBytes,
            "partsCompleted", partsCompleted,
            "partsTotal", partsTotal,
            "canPause", canPause,
            "canResume", canResume,
            "canCancel", canCancel,
            "outputLines", outputLines
        );
    }

    private static void emitTransferEvent(Map<String, Object> job) {
        try {
            System.out.println(MAPPER.writeValueAsString(orderedMap(
                "event", "transferProgress",
                "job", job
            )));
            System.out.flush();
        } catch (IOException ignored) {
        }
    }

    private static String transferStrategyLabel(String direction, boolean usesMultipart) {
        return (usesMultipart ? "Multipart " : "Single-part ") + direction;
    }

    private static double progressFraction(long bytesTransferred, long totalBytes) {
        if (totalBytes <= 0) {
            return 1.0;
        }
        return (double) bytesTransferred / (double) totalBytes;
    }

    private static Path runtimeDir() throws IOException {
        Path path = Path.of(System.getProperty("java.io.tmpdir"), "object-data-browser-java-engine");
        Files.createDirectories(path);
        return path;
    }

    private static Path benchmarkStatePath(String runId) throws IOException {
        return runtimeDir().resolve("benchmark-" + runId + ".json");
    }

    private static Map<String, Object> readBenchmarkState(String runId) throws IOException {
        Path path = benchmarkStatePath(runId);
        if (!Files.exists(path)) {
            throw new SidecarException("invalid_config", "Benchmark run " + runId + " was not found.");
        }
        return MAPPER.readValue(Files.readString(path), new TypeReference<>() {});
    }

    private static void writeBenchmarkState(Map<String, Object> state) throws IOException {
        Files.writeString(benchmarkStatePath(String.valueOf(state.get("id"))), MAPPER.writeValueAsString(state));
    }

    private static Map<String, Object> materializeBenchmarkState(Map<String, Object> state) throws IOException {
        String status = String.valueOf(state.get("status"));
        if (List.of("paused", "completed", "stopped", "failed").contains(status)) {
            return state;
        }
        @SuppressWarnings("unchecked")
        Map<String, Object> config = (Map<String, Object>) state.get("config");
        Instant lastUpdated = Instant.parse(String.valueOf(state.getOrDefault("lastUpdatedAt", state.get("startedAt"))));
        Instant now = Instant.now();
        double activeElapsed = asDouble(state.get("activeElapsedSeconds"))
            + (double) Duration.between(lastUpdated, now).toMillis() / 1000.0;
        state.put("activeElapsedSeconds", activeElapsed);
        state.put("lastUpdatedAt", nowIso());
        int durationSeconds = Math.max(asInt(config.get("durationSeconds")), 1);
        int operationCount = Math.max(asInt(config.get("operationCount")), 1);
        int concurrentThreads = Math.max(asInt(config.get("concurrentThreads")), 1);
        int processed = asInt(state.get("processedCount"));
        boolean durationComplete = !"operation-count".equals(String.valueOf(config.get("testMode")))
            && activeElapsed >= durationSeconds;
        boolean operationComplete = "operation-count".equals(String.valueOf(config.get("testMode")))
            && processed >= operationCount;
        double effectiveElapsed = durationComplete ? durationSeconds : activeElapsed;
        if (durationComplete) {
            state.put("activeElapsedSeconds", effectiveElapsed);
        }
        int targetProcessed = (int) (effectiveElapsed * concurrentThreads * 8);
        if (processed == 0 && targetProcessed == 0 && !durationComplete && !operationComplete) {
            targetProcessed = 1;
        }
        if ("operation-count".equals(String.valueOf(config.get("testMode")))) {
            targetProcessed = Math.min(targetProcessed, operationCount);
        }
        int batchSize = Math.max(targetProcessed - processed, 0);
        if (durationComplete || operationComplete) {
            batchSize = 0;
        }
        batchSize = Math.min(batchSize, Math.max(concurrentThreads * 8, 32));
        if (batchSize == 0 && processed == 0 && !durationComplete && !operationComplete) {
            batchSize = 1;
        }
        if (batchSize > 0) {
            Profile profile = benchmarkProfile(state);
            try (S3Client client = buildClient(profile)) {
                for (int index = 0; index < batchSize; index += 1) {
                    if ("operation-count".equals(String.valueOf(config.get("testMode")))
                        && asInt(state.get("processedCount")) >= operationCount) {
                        break;
                    }
                    runBenchmarkOperation(state, client);
                }
            } catch (Exception error) {
                SidecarException mapped = mapException(error);
                state.put("status", "failed");
                state.put("completedAt", nowIso());
                appendBenchmarkLog(state, "Benchmark failed: " + mapped.message);
            }
        }
        if (Boolean.TRUE.equals(config.get("debugMode"))) {
            emitStructuredLog(
                "DEBUG",
                "BenchmarkTrace",
                "Benchmark status=" + state.get("status")
                    + " processed=" + state.get("processedCount")
                    + " elapsedSeconds=" + String.format("%.2f", asDouble(state.get("activeElapsedSeconds"))),
                "benchmark"
            );
        }
        state.put("resultSummary", benchmarkSummaryFromState(state));
        state.put("averageLatencyMs", averageBenchmarkLatency(state));
        @SuppressWarnings("unchecked")
        List<Map<String, Object>> throughputSeries = (List<Map<String, Object>>) ((Map<String, Object>) state.get("resultSummary"))
            .getOrDefault("throughputSeries", List.of());
        state.put(
            "throughputOpsPerSecond",
            throughputSeries.isEmpty() ? 0 : asInt(throughputSeries.get(throughputSeries.size() - 1).get("opsPerSecond"))
        );
        if ("running".equals(String.valueOf(state.get("status")))) {
            boolean completed = "operation-count".equals(String.valueOf(config.get("testMode")))
                ? asInt(state.get("processedCount")) >= operationCount
                : asDouble(state.get("activeElapsedSeconds")) >= durationSeconds;
            if (completed) {
                state.put("status", "completed");
                state.put("completedAt", nowIso());
                appendBenchmarkLog(state, "Benchmark completed after " + state.get("processedCount") + " request(s).");
            }
        }
        persistBenchmarkOutputs(state);
        writeBenchmarkState(state);
        return state;
    }

    private static void refreshBenchmarkSnapshot(Map<String, Object> state) {
        String status = String.valueOf(state.get("status"));
        if (!List.of("completed", "stopped", "failed").contains(status)) {
            Instant lastUpdated = Instant.parse(String.valueOf(state.getOrDefault("lastUpdatedAt", state.get("startedAt"))));
            Instant now = Instant.now();
            double activeElapsed = asDouble(state.get("activeElapsedSeconds"))
                + (double) Duration.between(lastUpdated, now).toMillis() / 1000.0;
            state.put("activeElapsedSeconds", activeElapsed);
            state.put("lastUpdatedAt", nowIso());
        }
        state.put("resultSummary", benchmarkSummaryFromState(state));
        state.put("averageLatencyMs", averageBenchmarkLatency(state));
        @SuppressWarnings("unchecked")
        List<Map<String, Object>> throughputSeries = (List<Map<String, Object>>) ((Map<String, Object>) state.get("resultSummary"))
            .getOrDefault("throughputSeries", List.of());
        state.put(
            "throughputOpsPerSecond",
            throughputSeries.isEmpty() ? 0 : asInt(throughputSeries.get(throughputSeries.size() - 1).get("opsPerSecond"))
        );
    }

    private static void appendBenchmarkLog(Map<String, Object> state, String line) {
        List<String> log = new ArrayList<>(stringList(state.get("liveLog")));
        log.add(line);
        if (log.size() > 60) {
            log = log.subList(log.size() - 60, log.size());
        }
        state.put("liveLog", log);
    }

    private static Profile benchmarkProfile(Map<String, Object> state) {
        @SuppressWarnings("unchecked")
        Map<String, Object> merged = new LinkedHashMap<>((Map<String, Object>) state.get("profile"));
        @SuppressWarnings("unchecked")
        Map<String, Object> config = (Map<String, Object>) state.get("config");
        merged.put("connectTimeoutSeconds", asInt(config.get("connectTimeoutSeconds")));
        merged.put("readTimeoutSeconds", asInt(config.get("readTimeoutSeconds")));
        merged.put("maxAttempts", asInt(config.get("maxAttempts")));
        merged.put("maxConcurrentRequests", asInt(config.get("maxPoolConnections")));
        return parseProfile(MAPPER.valueToTree(merged));
    }

    private static String benchmarkBasePrefix(Map<String, Object> config, String runId) {
        String prefix = String.valueOf(config.getOrDefault("prefix", "")).trim();
        if (!prefix.isBlank() && !prefix.endsWith("/")) {
            prefix += "/";
        }
        return prefix + runId + "/";
    }

    private static byte[] benchmarkPayload(String runId, String key, int sizeBytes, boolean randomData) {
        if (sizeBytes <= 0) {
            return new byte[0];
        }
        if (!randomData) {
            return "A".repeat(sizeBytes).getBytes(StandardCharsets.UTF_8);
        }
        byte[] seed = (runId + ":" + key + ":" + sizeBytes).getBytes(StandardCharsets.UTF_8);
        if (seed.length == 0) {
            seed = "s3-benchmark".getBytes(StandardCharsets.UTF_8);
        }
        int patternLength = Math.max(64, Math.min(seed.length * 8, 4096));
        byte[] pattern = new byte[patternLength];
        for (int index = 0; index < patternLength; index += 1) {
            pattern[index] = (byte) ((seed[index % seed.length] + (index * 17)) & 0xFF);
        }
        byte[] payload = new byte[sizeBytes];
        for (int index = 0; index < sizeBytes; index += 1) {
            payload[index] = pattern[index % pattern.length];
        }
        return payload;
    }

    private static List<Map.Entry<String, Integer>> benchmarkRatios(String workloadType) {
        if ("write-heavy".equals(workloadType)) {
            return List.of(Map.entry("PUT", 60), Map.entry("GET", 30), Map.entry("DELETE", 10));
        }
        if ("read-heavy".equals(workloadType)) {
            return List.of(Map.entry("PUT", 25), Map.entry("GET", 65), Map.entry("DELETE", 10));
        }
        if ("delete".equals(workloadType)) {
            return List.of(Map.entry("PUT", 0), Map.entry("GET", 0), Map.entry("DELETE", 100));
        }
        return List.of(Map.entry("PUT", 34), Map.entry("GET", 33), Map.entry("DELETE", 33));
    }

    private static List<Map<String, Object>> mapList(Object value) {
        if (!(value instanceof List<?> list)) {
            return new ArrayList<>();
        }
        List<Map<String, Object>> result = new ArrayList<>();
        for (Object item : list) {
            if (item instanceof Map<?, ?> map) {
                result.add(new LinkedHashMap<>(MAPPER.convertValue(map, new TypeReference<Map<String, Object>>() {})));
            }
        }
        return result;
    }

    private static List<Integer> benchmarkSizes(Map<String, Object> config) {
        if (!(config.get("objectSizes") instanceof List<?> sizes)) {
            return List.of(4096);
        }
        List<Integer> result = new ArrayList<>();
        for (Object item : sizes) {
            int size = asInt(item);
            if (size > 0) {
                result.add(size);
            }
        }
        return result.isEmpty() ? List.of(4096) : result;
    }

    private static boolean isMissingBenchmarkKey(Exception error) {
        if (error instanceof S3Exception s3) {
            String code = s3.awsErrorDetails() == null ? "" : blankToDefault(s3.awsErrorDetails().errorCode(), "");
            if (List.of("NoSuchKey", "NotFound", "404").contains(code)) {
                return true;
            }
        }
        return (error.getMessage() == null ? "" : error.getMessage()).toLowerCase().contains("does not exist");
    }

    private static int benchmarkOperationCount(Map<String, Object> record) {
        return Math.max(asInt(record.get("operationCount")), 1);
    }

    private static String benchmarkTimelineLabel(double elapsedSeconds) {
        if (elapsedSeconds >= 100) {
            return String.format(java.util.Locale.US, "%.0fs", elapsedSeconds);
        }
        if (elapsedSeconds >= 10) {
            return String.format(java.util.Locale.US, "%.1fs", elapsedSeconds);
        }
        return String.format(java.util.Locale.US, "%.2fs", elapsedSeconds);
    }

    private static String benchmarkDeleteMode(Map<String, Object> config) {
        return "multi-object-post".equals(String.valueOf(config.getOrDefault("deleteMode", "single")))
            ? "multi-object-post"
            : "single";
    }

    private static int benchmarkDeleteBatchSize(Map<String, Object> config, int activeCount) {
        if (!Objects.equals(benchmarkDeleteMode(config), "multi-object-post")) {
            return 1;
        }
        return Math.max(1, Math.min(Math.min(Math.max(asInt(config.get("concurrentThreads")), 2), 1000), activeCount));
    }

    private static void runBenchmarkOperation(Map<String, Object> state, S3Client client) throws IOException {
        @SuppressWarnings("unchecked")
        Map<String, Object> config = (Map<String, Object>) state.get("config");
        List<Map<String, Object>> activeObjects = mapList(state.get("activeObjects"));
        List<Map<String, Object>> history = mapList(state.get("history"));
        int slot = asInt(state.get("processedCount")) % 100;
        String operation = "PUT";
        int cumulative = 0;
        for (Map.Entry<String, Integer> ratio : benchmarkRatios(String.valueOf(config.getOrDefault("workloadType", "mixed")))) {
            cumulative += ratio.getValue();
            if (slot < cumulative) {
                operation = ratio.getKey();
                break;
            }
        }
        if ((Objects.equals(operation, "GET") || Objects.equals(operation, "DELETE")) && activeObjects.isEmpty()) {
            operation = "PUT";
        }
        List<Integer> sizes = benchmarkSizes(config);
        int nextSizeIndex = asInt(state.get("nextSizeIndex"));
        int sizeBytes = sizes.get(nextSizeIndex % sizes.size());
        state.put("nextSizeIndex", nextSizeIndex + 1);
        int objectLimit = Math.max(asInt(config.get("objectCount")), 1);
        String key;
        int bytesTransferred;
        String checksumState;
        double latencyMs;
        int operationCount;
        while (true) {
            int nextActiveIndex = asInt(state.get("nextActiveIndex"));
            long started = System.nanoTime();
            if (Objects.equals(operation, "PUT")) {
                if (activeObjects.size() >= objectLimit && !activeObjects.isEmpty()) {
                    key = String.valueOf(activeObjects.get(nextActiveIndex % activeObjects.size()).get("key"));
                    state.put("nextActiveIndex", nextActiveIndex + 1);
                } else {
                    int nextObjectIndex = asInt(state.get("nextObjectIndex"));
                    key = String.valueOf(state.get("benchmarkPrefix")) + "obj-"
                        + String.format("%06d", nextObjectIndex) + "-" + sizeBytes + ".bin";
                    state.put("nextObjectIndex", nextObjectIndex + 1);
                }
                byte[] payload = benchmarkPayload(
                    String.valueOf(state.get("id")),
                    key,
                    sizeBytes,
                    Boolean.TRUE.equals(config.getOrDefault("randomData", Boolean.TRUE))
                );
                client.putObject(
                    PutObjectRequest.builder().bucket(String.valueOf(config.get("bucketName"))).key(key).build(),
                    software.amazon.awssdk.core.sync.RequestBody.fromBytes(payload)
                );
                boolean updated = false;
                for (Map<String, Object> entry : activeObjects) {
                    if (Objects.equals(String.valueOf(entry.get("key")), key)) {
                        entry.put("sizeBytes", sizeBytes);
                        updated = true;
                    }
                }
                if (!updated) {
                    activeObjects.add(orderedMap("key", key, "sizeBytes", sizeBytes));
                }
                bytesTransferred = payload.length;
                checksumState = "not_used";
                latencyMs = (System.nanoTime() - started) / 1_000_000.0;
                operationCount = 1;
                break;
            }
            if (Objects.equals(operation, "GET")) {
                Map<String, Object> target = activeObjects.get(nextActiveIndex % activeObjects.size());
                key = String.valueOf(target.get("key"));
                sizeBytes = asInt(target.get("sizeBytes"));
                state.put("nextActiveIndex", nextActiveIndex + 1);
                try (ResponseInputStream<?> stream = client.getObject(GetObjectRequest.builder()
                    .bucket(String.valueOf(config.get("bucketName")))
                    .key(key)
                    .build())) {
                    byte[] bytes = stream.readAllBytes();
                    bytesTransferred = bytes.length;
                    if (Boolean.TRUE.equals(config.getOrDefault("validateChecksum", Boolean.TRUE))) {
                        byte[] expected = benchmarkPayload(
                            String.valueOf(state.get("id")),
                            key,
                            sizeBytes,
                            Boolean.TRUE.equals(config.getOrDefault("randomData", Boolean.TRUE))
                        );
                        checksumState = java.util.Arrays.equals(bytes, expected) ? "validated_success" : "validated_failure";
                    } else {
                        checksumState = "not_used";
                    }
                    latencyMs = (System.nanoTime() - started) / 1_000_000.0;
                    operationCount = 1;
                    break;
                } catch (Exception error) {
                    if (isMissingBenchmarkKey(error)) {
                        final String missingKey = key;
                        activeObjects.removeIf(entry -> Objects.equals(String.valueOf(entry.get("key")), missingKey));
                        state.put("activeObjects", activeObjects);
                        appendBenchmarkLog(state, "Skipped missing benchmark object " + key + "; rotating to the next object.");
                        if (activeObjects.isEmpty()) {
                            operation = "PUT";
                        }
                        continue;
                    }
                    throw error;
                }
            }
            int deleteBatchSize = benchmarkDeleteBatchSize(config, activeObjects.size());
            List<Map<String, Object>> selectedBatch = new ArrayList<>();
            List<String> selectedKeys = new ArrayList<>();
            for (int offset = 0; offset < deleteBatchSize; offset += 1) {
                Map<String, Object> selected = activeObjects.get((nextActiveIndex + offset) % activeObjects.size());
                selectedBatch.add(selected);
                selectedKeys.add(String.valueOf(selected.get("key")));
            }
            state.put("nextActiveIndex", nextActiveIndex + deleteBatchSize);
            if (Objects.equals(benchmarkDeleteMode(config), "multi-object-post") && selectedKeys.size() > 1) {
                var output = client.deleteObjects(DeleteObjectsRequest.builder()
                    .bucket(String.valueOf(config.get("bucketName")))
                    .delete(Delete.builder()
                        .objects(selectedKeys.stream().map(item -> ObjectIdentifier.builder().key(item).build()).toList())
                        .quiet(false)
                        .build())
                    .build());
                LinkedHashSet<String> deletedKeys = new LinkedHashSet<>();
                output.deleted().forEach(item -> {
                    String target = blankToDefault(item.key(), "");
                    if (!target.isEmpty()) {
                        deletedKeys.add(target);
                    }
                });
                LinkedHashSet<String> missingKeys = new LinkedHashSet<>();
                List<String> fatalErrors = new ArrayList<>();
                output.errors().forEach(item -> {
                    String target = blankToDefault(item.key(), "");
                    String code = blankToDefault(item.code(), "").toLowerCase();
                    String message = blankToDefault(item.message(), "");
                    if (List.of("nosuchkey", "notfound", "404").contains(code)
                        || message.toLowerCase().contains("does not exist")) {
                        if (!target.isEmpty()) {
                            missingKeys.add(target);
                        }
                        return;
                    }
                    fatalErrors.add((target.isEmpty() ? "(unknown)" : target) + ": "
                        + (message.isEmpty() ? blankToDefault(item.code(), "delete error") : message));
                });
                if (!fatalErrors.isEmpty()) {
                    throw new SidecarException("delete_failed", String.join("; ", fatalErrors));
                }
                if (!missingKeys.isEmpty()) {
                    appendBenchmarkLog(
                        state,
                        "Skipped " + missingKeys.size() + " missing benchmark object(s) during multi-delete POST."
                    );
                }
                activeObjects.removeIf(entry ->
                    deletedKeys.contains(String.valueOf(entry.get("key")))
                        || missingKeys.contains(String.valueOf(entry.get("key")))
                );
                operationCount = deletedKeys.size();
                if (operationCount == 0) {
                    state.put("activeObjects", activeObjects);
                    if (activeObjects.isEmpty()) {
                        operation = "PUT";
                    }
                    continue;
                }
                key = selectedKeys.stream()
                    .filter(deletedKeys::contains)
                    .findFirst()
                    .orElseGet(() -> deletedKeys.iterator().next());
                if (operationCount > 1) {
                    key = key + " (+" + (operationCount - 1) + " more)";
                }
                sizeBytes = 0;
                bytesTransferred = 0;
                checksumState = "not_used";
                latencyMs = (System.nanoTime() - started) / 1_000_000.0;
                break;
            }
            Map<String, Object> target = selectedBatch.get(0);
            key = String.valueOf(target.get("key"));
            sizeBytes = asInt(target.get("sizeBytes"));
            try {
                client.deleteObject(DeleteObjectRequest.builder()
                    .bucket(String.valueOf(config.get("bucketName")))
                    .key(key)
                    .build());
                final String deletedKey = key;
                activeObjects.removeIf(entry -> Objects.equals(String.valueOf(entry.get("key")), deletedKey));
                bytesTransferred = 0;
                checksumState = "not_used";
                latencyMs = (System.nanoTime() - started) / 1_000_000.0;
                operationCount = 1;
                break;
            } catch (Exception error) {
                if (isMissingBenchmarkKey(error)) {
                    final String missingKey = key;
                    activeObjects.removeIf(entry -> Objects.equals(String.valueOf(entry.get("key")), missingKey));
                    state.put("activeObjects", activeObjects);
                    appendBenchmarkLog(state, "Skipped missing benchmark object " + key + "; rotating to the next object.");
                    if (activeObjects.isEmpty()) {
                        operation = "PUT";
                    }
                    continue;
                }
                throw error;
            }
        }
        history.add(orderedMap(
            "timestamp", nowIso(),
            "second", ((int) asDouble(state.get("activeElapsedSeconds"))) + 1,
            "operation", operation,
            "key", key,
            "sizeBytes", sizeBytes,
            "latencyMs", round1(latencyMs),
            "bytesTransferred", bytesTransferred,
            "success", true,
            "checksumState", checksumState,
            "operationCount", operationCount
        ));
        state.put("history", history);
        state.put("activeObjects", activeObjects);
        state.put("processedCount", history.stream().mapToInt(Main::benchmarkOperationCount).sum());
        if (Objects.equals(operation, "DELETE") && operationCount > 1) {
            appendBenchmarkLog(state, "DELETE POST removed " + operationCount + " object(s) in " + round1(latencyMs) + " ms.");
        } else {
            appendBenchmarkLog(state, operation + " " + key + " completed in " + round1(latencyMs) + " ms.");
        }
    }

    private static Map<String, Object> benchmarkSummaryFromState(Map<String, Object> state) {
        List<Map<String, Object>> history = mapList(state.get("history"));
        Map<String, Object> operationsByType = new LinkedHashMap<>();
        Map<String, Object> checksumStats = orderedMap("validated_success", 0, "validated_failure", 0, "not_used", 0);
        Map<Integer, List<Map<String, Object>>> windows = new java.util.TreeMap<>();
        Map<Integer, List<Double>> sizeLatency = new java.util.TreeMap<>();
        List<Double> latencies = new ArrayList<>();
        for (Map<String, Object> record : history) {
            String operation = String.valueOf(record.getOrDefault("operation", ""));
            int operationCount = benchmarkOperationCount(record);
            operationsByType.put(operation, asInt(operationsByType.get(operation)) + operationCount);
            String checksumState = String.valueOf(record.getOrDefault("checksumState", "not_used"));
            checksumStats.put(checksumState, asInt(checksumStats.get(checksumState)) + operationCount);
            double latency = asDouble(record.get("latencyMs"));
            latencies.add(latency);
            int second = Math.max(asInt(record.get("second")), 1);
            windows.computeIfAbsent(second, ignored -> new ArrayList<>()).add(record);
            int sizeBytes = asInt(record.get("sizeBytes"));
            if (sizeBytes > 0) {
                sizeLatency.computeIfAbsent(sizeBytes, ignored -> new ArrayList<>()).add(latency);
            }
        }
        List<Map<String, Object>> throughputSeries = new ArrayList<>();
        double averageOps = 0;
        double averageBytes = 0;
        int peakOps = 0;
        int peakBytes = 0;
        for (Map.Entry<Integer, List<Map<String, Object>>> entry : windows.entrySet()) {
            Map<String, Object> windowOperations = new LinkedHashMap<>();
            List<Double> windowLatencies = new ArrayList<>();
            int bytesPerSecond = 0;
            int opsPerSecond = 0;
            for (Map<String, Object> record : entry.getValue()) {
                String operation = String.valueOf(record.getOrDefault("operation", ""));
                int operationCount = benchmarkOperationCount(record);
                windowOperations.put(operation, asInt(windowOperations.get(operation)) + operationCount);
                windowLatencies.add(asDouble(record.get("latencyMs")));
                bytesPerSecond += asInt(record.get("bytesTransferred"));
                opsPerSecond += operationCount;
            }
            averageOps += opsPerSecond;
            averageBytes += bytesPerSecond;
            peakOps = Math.max(peakOps, opsPerSecond);
            peakBytes = Math.max(peakBytes, bytesPerSecond);
            throughputSeries.add(orderedMap(
                "second", entry.getKey(),
                "label", entry.getKey() + "s",
                "opsPerSecond", opsPerSecond,
                "bytesPerSecond", bytesPerSecond,
                "averageLatencyMs", round1(mean(windowLatencies)),
                "p95LatencyMs", round1(percentile(windowLatencies, 95)),
                "operations", windowOperations
            ));
        }
        Map<Integer, Integer> secondPositions = new LinkedHashMap<>();
        List<Map<String, Object>> latencyTimeline = new ArrayList<>();
        for (int index = 0; index < history.size(); index += 1) {
            Map<String, Object> record = history.get(index);
            int second = Math.max(asInt(record.get("second")), 1);
            int position = secondPositions.getOrDefault(second, 0) + 1;
            secondPositions.put(second, position);
            double elapsedMs = asDouble(record.get("elapsedMs"));
            if (elapsedMs <= 0) {
                elapsedMs = ((second - 1) + ((double) position / (windows.get(second).size() + 1))) * 1000.0;
            }
            latencyTimeline.add(orderedMap(
                "sequence", index + 1,
                "operation", String.valueOf(record.getOrDefault("operation", "")).toUpperCase(),
                "second", second,
                "elapsedMs", round1(elapsedMs),
                "label", benchmarkTimelineLabel(elapsedMs / 1000.0),
                "latencyMs", round1(asDouble(record.get("latencyMs"))),
                "sizeBytes", asInt(record.get("sizeBytes")),
                "bytesTransferred", asInt(record.get("bytesTransferred")),
                "operationCount", benchmarkOperationCount(record),
                "success", !record.containsKey("success") || Boolean.TRUE.equals(record.get("success")),
                "key", String.valueOf(record.getOrDefault("key", ""))
            ));
        }
        List<Map<String, Object>> sizeLatencyBuckets = new ArrayList<>();
        for (Map.Entry<Integer, List<Double>> entry : sizeLatency.entrySet()) {
            sizeLatencyBuckets.add(orderedMap(
                "sizeBytes", entry.getKey(),
                "count", entry.getValue().size(),
                "avgLatencyMs", round1(mean(entry.getValue())),
                "p50LatencyMs", round1(percentile(entry.getValue(), 50)),
                "p95LatencyMs", round1(percentile(entry.getValue(), 95)),
                "p99LatencyMs", round1(percentile(entry.getValue(), 99))
            ));
        }
        int sampleCount = Math.max(throughputSeries.size(), 1);
        int averageObjectSize = benchmarkSizes((Map<String, Object>) state.get("config"))
            .stream()
            .mapToInt(Integer::intValue)
            .sum();
        List<Integer> sizes = benchmarkSizes((Map<String, Object>) state.get("config"));
        if (!sizes.isEmpty()) {
            averageObjectSize /= sizes.size();
        }
        return orderedMap(
            "totalOperations", history.stream().mapToInt(Main::benchmarkOperationCount).sum(),
            "operationsByType", operationsByType,
            "latencyPercentilesMs", orderedMap(
                "p50", round1(percentile(latencies, 50)),
                "p75", round1(percentile(latencies, 75)),
                "p90", round1(percentile(latencies, 90)),
                "p95", round1(percentile(latencies, 95)),
                "p99", round1(percentile(latencies, 99)),
                "p999", round1(percentile(latencies, 99.9))
            ),
            "throughputSeries", throughputSeries,
            "latencyTimeline", latencyTimeline,
            "sizeLatencyBuckets", sizeLatencyBuckets,
            "checksumStats", checksumStats,
            "detailMetrics", orderedMap(
                "sampleCount", sampleCount,
                "sampleWindowSeconds", 1,
                "averageOpsPerSecond", round1(averageOps / sampleCount),
                "peakOpsPerSecond", peakOps,
                "averageBytesPerSecond", round1(averageBytes / sampleCount),
                "peakBytesPerSecond", peakBytes,
                "averageObjectSizeBytes", averageObjectSize,
                "checksumValidated", asInt(checksumStats.get("validated_success")),
                "errorCount", 0,
                "retryCount", 0
            )
        );
    }

    private static void persistBenchmarkOutputs(Map<String, Object> state) throws IOException {
        @SuppressWarnings("unchecked")
        Map<String, Object> config = (Map<String, Object>) state.get("config");
        Path csvPath = Path.of(String.valueOf(config.get("csvOutputPath")));
        Path jsonPath = Path.of(String.valueOf(config.get("jsonOutputPath")));
        Path logPath = Path.of(String.valueOf(config.get("logFilePath")));
        Files.createDirectories(csvPath.getParent());
        Files.createDirectories(jsonPath.getParent());
        Files.createDirectories(logPath.getParent());
        List<String> csvLines = new ArrayList<>(
            List.of("second,operation,operationCount,latencyMs,sizeBytes,bytesTransferred,success,checksumState,key")
        );
        for (Map<String, Object> record : mapList(state.get("history"))) {
            csvLines.add(
                asInt(record.get("second")) + ","
                    + record.getOrDefault("operation", "") + ","
                    + benchmarkOperationCount(record) + ","
                    + round1(asDouble(record.get("latencyMs"))) + ","
                    + asInt(record.get("sizeBytes")) + ","
                    + asInt(record.get("bytesTransferred")) + ",true,"
                    + record.getOrDefault("checksumState", "not_used") + ","
                    + record.getOrDefault("key", "")
            );
        }
        Files.writeString(csvPath, String.join("\n", csvLines) + "\n");
        Files.writeString(jsonPath, writeJson(state.get("resultSummary")));
        Files.writeString(logPath, String.join("\n", stringList(state.get("liveLog"))));
    }

    private static double averageBenchmarkLatency(Map<String, Object> state) {
        List<Double> latencies = mapList(state.get("history")).stream()
            .map(item -> asDouble(item.get("latencyMs")))
            .toList();
        return round1(mean(latencies));
    }

    private static double percentile(List<Double> values, double percentile) {
        if (values.isEmpty()) {
            return 0;
        }
        List<Double> sorted = new ArrayList<>(values);
        sorted.sort(Double::compareTo);
        if (sorted.size() == 1) {
            return sorted.get(0);
        }
        double rank = ((sorted.size() - 1) * percentile) / 100.0;
        int lower = (int) Math.floor(rank);
        int upper = Math.min(lower + 1, sorted.size() - 1);
        double weight = rank - lower;
        return sorted.get(lower) + ((sorted.get(upper) - sorted.get(lower)) * weight);
    }

    private static double mean(List<Double> values) {
        if (values.isEmpty()) {
            return 0;
        }
        return values.stream().mapToDouble(Double::doubleValue).sum() / values.size();
    }

    private static double round1(double value) {
        return Math.round(value * 10.0) / 10.0;
    }

    private static SidecarException mapException(Exception error) {
        if (error instanceof SidecarException sidecar) {
            return sidecar;
        }
        Throwable cause = error instanceof RuntimeException runtime && runtime.getCause() != null
            ? runtime.getCause()
            : error;
        if (cause instanceof S3Exception s3) {
            String code = s3.awsErrorDetails() == null ? "Unknown" : s3.awsErrorDetails().errorCode();
            String message = s3.awsErrorDetails() == null ? s3.getMessage() : s3.awsErrorDetails().errorMessage();
            if (List.of("AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch").contains(code)) {
                return new SidecarException("auth_failed", message, orderedMap("awsCode", code));
            }
            if ("RequestTimeout".equals(code)) {
                return new SidecarException("timeout", message, orderedMap("awsCode", code));
            }
            if ("SlowDown".equals(code)) {
                return new SidecarException("throttled", message, orderedMap("awsCode", code));
            }
            return new SidecarException("unknown", message, orderedMap("awsCode", code));
        }
        if (cause instanceof SdkClientException client) {
            String message = client.getMessage() == null ? client.toString() : client.getMessage();
            String lowered = message.toLowerCase();
            if (lowered.contains("timed out") || lowered.contains("timeout")) {
                return new SidecarException("timeout", message);
            }
            if (lowered.contains("certificate") || lowered.contains("ssl") || lowered.contains("tls")) {
                return new SidecarException("tls_error", message);
            }
            return new SidecarException("engine_unavailable", message);
        }
        return new SidecarException("unknown", error.getMessage() == null ? error.toString() : error.getMessage());
    }

    private static Map<String, Object> capability(String key, String label, String state, String reason) {
        return orderedMap(
            "key", key,
            "label", label,
            "state", state,
            "reason", reason
        );
    }

    private static Map<String, Object> orderedMap(Object... values) {
        Map<String, Object> result = new LinkedHashMap<>();
        for (int index = 0; index < values.length; index += 2) {
            result.put(String.valueOf(values[index]), values[index + 1]);
        }
        return result;
    }

    private static String text(JsonNode node, String field) {
        if (node == null || node.isMissingNode() || node.isNull()) {
            return "";
        }
        JsonNode child = node.path(field);
        return child.isMissingNode() || child.isNull() ? "" : child.asText("");
    }

    private static String textEither(JsonNode node, String first, String second) {
        String value = text(node, first);
        return value.isBlank() ? text(node, second) : value;
    }

    private static String requiredText(JsonNode node, String field, String message) {
        String value = text(node, field).trim();
        if (value.isBlank()) {
            throw new SidecarException("invalid_config", message);
        }
        return value;
    }

    private static void putIfNotBlank(Map<String, String> target, String key, String value) {
        if (value != null && !value.isBlank()) {
            target.put(key, value);
        }
    }

    private static void putIfNotBlank(ThrowingConsumer<String> consumer, String value) {
        if (value != null && !value.isBlank()) {
            try {
                consumer.accept(value);
            } catch (Exception error) {
                throw new RuntimeException(error);
            }
        }
    }

    private static List<String> stringArray(JsonNode node) {
        List<String> values = new ArrayList<>();
        if (node == null || !node.isArray()) {
            return values;
        }
        node.forEach(item -> {
            String value = item.asText("").trim();
            if (!value.isBlank()) {
                values.add(value);
            }
        });
        return values;
    }

    private static Map<String, String> stringMap(JsonNode node) {
        Map<String, String> values = new LinkedHashMap<>();
        if (node == null || !node.isObject()) {
            return values;
        }
        node.fields().forEachRemaining(entry -> {
            String value = entry.getValue().asText("").trim();
            if (!value.isBlank()) {
                values.put(entry.getKey(), value);
            }
        });
        return values;
    }

    private static List<String> stringList(Object value) {
        if (value instanceof List<?> list) {
            return list.stream().map(String::valueOf).toList();
        }
        return List.of();
    }

    private static int asInt(Object value) {
        if (value instanceof Number number) {
            return number.intValue();
        }
        try {
            return Integer.parseInt(String.valueOf(value));
        } catch (Exception ignored) {
            return 0;
        }
    }

    private static double asDouble(Object value) {
        if (value instanceof Number number) {
            return number.doubleValue();
        }
        try {
            return Double.parseDouble(String.valueOf(value));
        } catch (Exception ignored) {
            return 0;
        }
    }

    private static String serializeTime(Instant value) {
        return value == null ? ISO.format(Instant.EPOCH) : ISO.format(value);
    }

    private static String nowIso() {
        return ISO.format(Instant.now());
    }

    private static String writeJson(Object value) {
        try {
            return MAPPER.writerWithDefaultPrettyPrinter().writeValueAsString(value);
        } catch (Exception error) {
            return "{}";
        }
    }

    private static String trimQuotes(String value) {
        return value == null ? "" : value.replace("\"", "").trim();
    }

    private static String trimQuotesOrNull(String value) {
        String trimmed = trimQuotes(value);
        return trimmed.isBlank() ? null : trimmed;
    }

    private static String blankToDefault(String value, String fallback) {
        return value == null || value.isBlank() ? fallback : value;
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value;
    }

    private static String urlEncode(String value) {
        return java.net.URLEncoder.encode(value, StandardCharsets.UTF_8).replace("+", "%20");
    }

    @FunctionalInterface
    private interface ThrowingSupplier<T> {
        T get() throws Exception;
    }

    @FunctionalInterface
    private interface ThrowingConsumer<T> {
        void accept(T value) throws Exception;
    }

    private record Profile(
        String endpointUrl,
        String region,
        String accessKey,
        String secretKey,
        String sessionToken,
        boolean pathStyle,
        boolean verifyTls,
        int connectTimeoutSeconds,
        int readTimeoutSeconds,
        int maxAttempts,
        int maxPoolConnections,
        boolean enableApiLogging,
        boolean enableDebugLogging
    ) {
    }

    private record BucketContext(Profile profile, String bucketName, S3Client client) {
    }

    private static final class SidecarException extends RuntimeException {
        private final String code;
        private final String message;
        private final Map<String, Object> details;

        private SidecarException(String code, String message) {
            this(code, message, Map.of());
        }

        private SidecarException(String code, String message, Map<String, Object> details) {
            super(message);
            this.code = code;
            this.message = message;
            this.details = details == null ? Map.of() : details;
        }
    }
}
