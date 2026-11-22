package com.example.s3browser;

import com.fasterxml.jackson.databind.JsonNode;
import software.amazon.awssdk.core.ResponseInputStream;
import software.amazon.awssdk.core.SdkBytes;
import software.amazon.awssdk.core.SdkField;
import software.amazon.awssdk.core.SdkPojo;
import software.amazon.awssdk.core.checksums.RequestChecksumCalculation;
import software.amazon.awssdk.core.checksums.ResponseChecksumValidation;
import software.amazon.awssdk.core.client.config.ClientOverrideConfiguration;
import software.amazon.awssdk.core.exception.ApiCallAttemptTimeoutException;
import software.amazon.awssdk.core.exception.ApiCallTimeoutException;
import software.amazon.awssdk.core.exception.SdkClientException;
import software.amazon.awssdk.core.interceptor.Context;
import software.amazon.awssdk.core.interceptor.ExecutionAttributes;
import software.amazon.awssdk.core.interceptor.ExecutionInterceptor;
import software.amazon.awssdk.core.protocol.MarshallingType;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.core.traits.ListTrait;
import software.amazon.awssdk.core.traits.MapTrait;
import software.amazon.awssdk.core.util.SdkAutoConstructList;
import software.amazon.awssdk.core.util.SdkAutoConstructMap;
import software.amazon.awssdk.http.SdkHttpResponse;
import software.amazon.awssdk.http.apache.ApacheHttpClient;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.retries.DefaultRetryStrategy;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.S3Configuration;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.GetObjectResponse;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import software.amazon.awssdk.services.s3.model.S3Exception;
import software.amazon.awssdk.services.s3.model.S3Request;
import software.amazon.awssdk.services.s3.model.S3Response;
import software.amazon.awssdk.services.s3.model.UploadPartRequest;
import software.amazon.awssdk.services.s3.presigner.S3Presigner;
import software.amazon.awssdk.services.s3.presigner.model.GetObjectPresignRequest;
import software.amazon.awssdk.services.s3.presigner.model.PresignedGetObjectRequest;
import software.amazon.awssdk.services.s3.presigner.model.PresignedPutObjectRequest;
import software.amazon.awssdk.services.s3.presigner.model.PutObjectPresignRequest;
import software.amazon.awssdk.utils.builder.Buildable;

import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLEngine;
import javax.net.ssl.SSLException;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509ExtendedTrustManager;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.net.ConnectException;
import java.net.Socket;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.net.URL;
import java.net.UnknownHostException;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collection;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeoutException;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * S3 API conformance primitive (`s3ConformanceOp`) for the Java engine.
 *
 * <p>Implements contracts/transport_contract.md ("S3 API conformance"): executes one S3 API
 * operation through a dedicated AWS SDK for Java v2 client (single attempt, WHEN_REQUIRED
 * checksums, no redirect following) and returns the normalized observation.
 */
final class S3Conformance {
    static final int CONFORMANCE_VERSION = 1;
    static final String SDK_VERSION = "aws-sdk-java-v2 2.41.29";

    static final List<String> OPERATIONS = List.of(
        "CreateBucket", "HeadBucket", "DeleteBucket", "ListBuckets", "GetBucketLocation",
        "GetBucketVersioning", "PutBucketVersioning",
        "GetBucketTagging", "PutBucketTagging", "DeleteBucketTagging",
        "GetBucketCors", "PutBucketCors", "DeleteBucketCors",
        "GetBucketLifecycleConfiguration", "PutBucketLifecycleConfiguration", "DeleteBucketLifecycle",
        "GetBucketPolicy", "PutBucketPolicy", "DeleteBucketPolicy", "GetBucketPolicyStatus",
        "GetBucketEncryption", "PutBucketEncryption", "DeleteBucketEncryption",
        "GetPublicAccessBlock", "PutPublicAccessBlock", "DeletePublicAccessBlock",
        "GetBucketOwnershipControls", "PutBucketOwnershipControls", "DeleteBucketOwnershipControls",
        "GetBucketAcl", "PutBucketAcl",
        "GetBucketAccelerateConfiguration", "PutBucketAccelerateConfiguration",
        "GetBucketRequestPayment", "PutBucketRequestPayment",
        "GetBucketLogging",
        "GetBucketWebsite", "PutBucketWebsite", "DeleteBucketWebsite",
        "GetBucketNotificationConfiguration", "PutBucketNotificationConfiguration",
        "GetBucketReplication", "DeleteBucketReplication",
        "ListBucketAnalyticsConfigurations", "GetBucketAnalyticsConfiguration",
        "PutBucketAnalyticsConfiguration", "DeleteBucketAnalyticsConfiguration",
        "ListBucketMetricsConfigurations", "GetBucketMetricsConfiguration",
        "PutBucketMetricsConfiguration", "DeleteBucketMetricsConfiguration",
        "ListBucketInventoryConfigurations", "GetBucketInventoryConfiguration",
        "PutBucketInventoryConfiguration", "DeleteBucketInventoryConfiguration",
        "ListBucketIntelligentTieringConfigurations", "GetBucketIntelligentTieringConfiguration",
        "PutBucketIntelligentTieringConfiguration", "DeleteBucketIntelligentTieringConfiguration",
        "GetObjectLockConfiguration", "PutObjectLockConfiguration",
        "PutObject", "GetObject", "HeadObject", "DeleteObject", "DeleteObjects", "CopyObject",
        "GetObjectAttributes", "ListObjects", "ListObjectsV2", "ListObjectVersions",
        "GetObjectTagging", "PutObjectTagging", "DeleteObjectTagging",
        "GetObjectAcl", "PutObjectAcl",
        "CreateMultipartUpload", "UploadPart", "UploadPartCopy", "ListParts", "ListMultipartUploads",
        "CompleteMultipartUpload", "AbortMultipartUpload",
        "GetObjectRetention", "PutObjectRetention", "GetObjectLegalHold", "PutObjectLegalHold",
        "PresignedRequest"
    );

    private static final Set<String> OPERATION_SET = Set.copyOf(OPERATIONS);

    private static final Set<String> SSE_C_TARGET_OPS = Set.of(
        "PutObject", "GetObject", "HeadObject", "CopyObject", "CreateMultipartUpload",
        "UploadPart", "UploadPartCopy", "CompleteMultipartUpload", "GetObjectAttributes"
    );
    private static final Set<String> SSE_C_SOURCE_OPS = Set.of("CopyObject", "UploadPartCopy");
    private static final Set<String> BODY_OPS = Set.of("PutObject", "UploadPart");
    private static final Set<String> COPY_SOURCE_OPS = Set.of("CopyObject", "UploadPartCopy");

    static final Set<String> HEADER_ALLOWLIST = Set.of(
        "etag", "content-type", "content-length", "content-range", "content-encoding",
        "content-disposition", "content-language", "cache-control", "expires", "last-modified",
        "date", "accept-ranges", "location", "x-amz-request-id", "x-amz-version-id",
        "x-amz-delete-marker", "x-amz-tagging-count", "x-amz-mp-parts-count",
        "x-amz-storage-class", "x-amz-expiration", "x-amz-replication-status",
        "x-amz-copy-source-version-id", "x-amz-bucket-region", "x-amz-website-redirect-location",
        "x-amz-missing-meta", "x-amz-restore", "x-amz-abort-date", "x-amz-abort-rule-id",
        "x-amz-server-side-encryption", "x-amz-server-side-encryption-aws-kms-key-id",
        "x-amz-server-side-encryption-bucket-key-enabled",
        "x-amz-server-side-encryption-customer-algorithm",
        "x-amz-object-lock-mode", "x-amz-object-lock-retain-until-date",
        "x-amz-object-lock-legal-hold",
        "access-control-allow-origin", "access-control-allow-methods",
        "access-control-expose-headers"
    );

    private static final int MAX_HEADERS = 48;
    private static final int MAX_META_HEADERS = 16;
    private static final int MAX_HEADER_VALUE = 512;
    private static final int MAX_ERROR_MESSAGE = 256;
    private static final int MAX_GENERATED_BODY = 16 * 1024 * 1024;
    private static final int MAX_BASE64_BODY = 1024 * 1024;
    private static final int MAX_TEXT_BODY = 64 * 1024;
    private static final int MAX_BODY_READ = 32 * 1024 * 1024;
    private static final int MAX_PRESIGN_ERROR_BODY = 64 * 1024;

    private static final Pattern URL_WITH_QUERY =
        Pattern.compile("(https?://[^\\s?'\"<>]+)\\?[^\\s'\"<>]*");
    private static final Pattern XML_ERROR_CODE = Pattern.compile("<Code>([^<]{1,128})</Code>");
    private static final Pattern XML_ERROR_MESSAGE = Pattern.compile("<Message>([^<]{0,512})</Message>");

    private static final HexFormat HEX = HexFormat.of();
    private static final ThreadLocal<AttemptTracker> CURRENT_TRACKER = new ThreadLocal<>();
    private static final ExecutionInterceptor INTERCEPTOR = new ConformanceInterceptor();

    private static final Map<Main.Profile, S3Client> CLIENTS = new LinkedHashMap<>();
    private static final Map<String, OpBinding> BINDINGS = new ConcurrentHashMap<>();

    private static final TrustManager[] TRUST_ALL_EXTENDED = new TrustManager[] {
        new X509ExtendedTrustManager() {
            @Override public void checkClientTrusted(X509Certificate[] chain, String authType) {}
            @Override public void checkServerTrusted(X509Certificate[] chain, String authType) {}
            @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            @Override public void checkClientTrusted(X509Certificate[] chain, String authType, Socket socket) {}
            @Override public void checkServerTrusted(X509Certificate[] chain, String authType, Socket socket) {}
            @Override public void checkClientTrusted(X509Certificate[] chain, String authType, SSLEngine engine) {}
            @Override public void checkServerTrusted(X509Certificate[] chain, String authType, SSLEngine engine) {}
        }
    };

    private S3Conformance() {}

    static Map<String, Object> capability(JsonNode params) {
        JsonNode profileNode = params == null ? null : params.path("profile");
        String endpointType = profileNode != null && profileNode.isObject()
            ? profileNode.path("endpointType").asText("").trim()
            : "";
        if (endpointType.isEmpty()) endpointType = "s3Compatible";
        boolean supported = "s3Compatible".equals(endpointType) || "awsS3".equals(endpointType);
        Map<String, Object> item = new LinkedHashMap<>();
        item.put("key", "conformance.s3");
        item.put("label", "S3 API conformance");
        item.put("state", supported ? "supported" : "unsupported");
        item.put("reason", supported ? null : "S3 API conformance applies to S3 profiles only.");
        item.put("version", CONFORMANCE_VERSION);
        item.put("sdk", SDK_VERSION);
        Map<String, Object> clientSettings = new LinkedHashMap<>();
        clientSettings.put("maxAttempts", 1);
        clientSettings.put("requestChecksumCalculation", "when_required");
        clientSettings.put("responseChecksumValidation", "when_required");
        clientSettings.put("followRedirects", false);
        item.put("client", clientSettings);
        item.put("ops", supported ? OPERATIONS : List.of());
        return item;
    }

    static Map<String, Object> run(JsonNode params) {
        if (params == null || !params.isObject()) {
            throw new Main.SidecarException("invalid_request", "Parameters object is required.");
        }
        Main.Profile profile = Main.parseProfile(params.path("profile"));
        JsonNode opNode = params.path("op");
        if (!opNode.isTextual() || opNode.asText().isBlank()) {
            throw new Main.SidecarException("invalid_request", "Operation name is required.");
        }
        String op = opNode.asText();
        if (!OPERATION_SET.contains(op)) {
            throw new Main.SidecarException(
                "unsupported_feature",
                "Operation " + op + " is not part of the conformance allowlist."
            );
        }

        JsonNode inputNode = params.path("input");
        if (!inputNode.isMissingNode() && !inputNode.isNull() && !inputNode.isObject()) {
            throw new Main.SidecarException("invalid_request", "input must be a JSON object.");
        }
        if (inputNode.isObject()) {
            rejectCustomerKeysInInput(inputNode);
        }

        boolean hasEncryption = params.hasNonNull("encryption");
        boolean hasSourceEncryption = params.hasNonNull("sourceEncryption");
        if ("PresignedRequest".equals(op)) {
            if (hasEncryption || hasSourceEncryption) {
                throw new Main.SidecarException(
                    "unsupported_feature",
                    "Customer-key encrypted objects cannot use presigned URLs."
                );
            }
            return runPresignedRequest(profile, inputNode, params.path("body"));
        }

        ObjectEncryption encryption = ObjectEncryption.parse(params, "encryption");
        ObjectEncryption sourceEncryption = ObjectEncryption.parse(params, "sourceEncryption");
        validateConformanceEncryption(op, hasEncryption, encryption, hasSourceEncryption, sourceEncryption);

        byte[] bodyBytes = null;
        if (BODY_OPS.contains(op)) {
            bodyBytes = parseBody(params.path("body"));
        } else if (params.hasNonNull("body")) {
            throw new Main.SidecarException("invalid_request", op + " does not accept a body.");
        }

        S3Request.Builder requestBuilder = buildRequestBuilder(op, inputNode);
        if (encryption.customer()) {
            encryption.write(requestBuilder);
        }
        if (sourceEncryption.customer()) {
            sourceEncryption.source(requestBuilder);
        }

        S3Request request;
        try {
            request = requestBuilder.build();
        } catch (RuntimeException error) {
            return buildResult(
                op,
                "sdk_validation",
                0,
                error.getClass().getSimpleName(),
                sanitizeErrorMessage(error.getMessage(), null),
                Map.of(),
                Map.of(),
                0.0,
                0,
                null
            );
        }

        try (S3Client client = conformanceClient(profile)) {
            return invokeOperation(client, op, request, bodyBytes);
        }
    }

    private static void validateConformanceEncryption(
            String op,
            boolean hasEncryption,
            ObjectEncryption encryption,
            boolean hasSourceEncryption,
            ObjectEncryption sourceEncryption) {
        if (hasEncryption) {
            if (!encryption.customer()) {
                // bucketDefault is a no-op; any other provider mode belongs in ordinary input.
                boolean isDefault = "bucketDefault".equals(encryptionMode(encryption));
                if (!isDefault) {
                    throw new Main.SidecarException(
                        "invalid_request",
                        "Only sse-c is accepted in conformance encryption; other modes belong in input."
                    );
                }
            } else if (!SSE_C_TARGET_OPS.contains(op)) {
                throw new Main.SidecarException(
                    "invalid_request",
                    op + " does not accept SSE-C encryption."
                );
            }
        }
        if (hasSourceEncryption) {
            if (sourceEncryption.customer() && !SSE_C_SOURCE_OPS.contains(op)) {
                throw new Main.SidecarException(
                    "invalid_request",
                    op + " does not accept copy-source SSE-C encryption."
                );
            }
        }
    }

    private static String encryptionMode(ObjectEncryption encryption) {
        try {
            var field = ObjectEncryption.class.getDeclaredField("mode");
            field.setAccessible(true);
            return String.valueOf(field.get(encryption));
        } catch (ReflectiveOperationException ignored) {
            return encryption.customer() ? "sse-c" : "other";
        }
    }

    private static void rejectCustomerKeysInInput(JsonNode node) {
        if (node.isObject()) {
            var fields = node.fields();
            while (fields.hasNext()) {
                var entry = fields.next();
                String lower = entry.getKey().toLowerCase(Locale.ROOT);
                if (lower.startsWith("ssecustomer") || lower.startsWith("copysourcessecustomer")) {
                    throw new Main.SidecarException(
                        "invalid_request",
                        "SSE-C parameters must be supplied through encryption/sourceEncryption, not input."
                    );
                }
                rejectCustomerKeysInInput(entry.getValue());
            }
        } else if (node.isArray()) {
            for (JsonNode child : node) {
                rejectCustomerKeysInInput(child);
            }
        }
    }

    static byte[] generateBody(int size, int seed) {
        if (size < 0 || size > MAX_GENERATED_BODY) {
            throw new Main.SidecarException("invalid_request", "body.generate.size must be 0..16 MiB.");
        }
        if (seed < 0 || seed > 65535) {
            throw new Main.SidecarException("invalid_request", "body.generate.seed must be 0..65535.");
        }
        byte[] data = new byte[size];
        long base = (long) seed * 131L;
        for (int i = 0; i < size; i++) {
            long idx = i;
            data[i] = (byte) ((base + idx * 7L + (idx >> 10)) & 0xFFL);
        }
        return data;
    }

    static byte[] parseBody(JsonNode bodyNode) {
        if (bodyNode == null || bodyNode.isMissingNode() || bodyNode.isNull()) {
            return new byte[0];
        }
        if (!bodyNode.isObject() || bodyNode.size() != 1) {
            throw new Main.SidecarException(
                "invalid_request",
                "body must be an object with exactly one of generate, base64, or text."
            );
        }
        if (bodyNode.has("generate")) {
            JsonNode spec = bodyNode.get("generate");
            if (!spec.isObject()) {
                throw new Main.SidecarException("invalid_request", "body.generate must be an object.");
            }
            var names = spec.fieldNames();
            while (names.hasNext()) {
                String k = names.next();
                if (!"size".equals(k) && !"seed".equals(k)) {
                    throw new Main.SidecarException("invalid_request", "Unknown body.generate field: " + k);
                }
            }
            JsonNode sizeNode = spec.get("size");
            JsonNode seedNode = spec.get("seed");
            if (sizeNode == null || !sizeNode.isIntegralNumber() || !sizeNode.canConvertToInt()) {
                throw new Main.SidecarException("invalid_request", "body.generate.size must be an integer 0..16 MiB.");
            }
            if (seedNode == null || !seedNode.isIntegralNumber() || !seedNode.canConvertToInt()) {
                throw new Main.SidecarException("invalid_request", "body.generate.seed must be an integer 0..65535.");
            }
            return generateBody(sizeNode.intValue(), seedNode.intValue());
        }
        if (bodyNode.has("base64")) {
            JsonNode b64Node = bodyNode.get("base64");
            if (!b64Node.isTextual()) {
                throw new Main.SidecarException("invalid_request", "body.base64 must be a string.");
            }
            byte[] decoded;
            try {
                decoded = Base64.getDecoder().decode(b64Node.asText());
            } catch (IllegalArgumentException error) {
                throw new Main.SidecarException("invalid_request", "body.base64 is not valid base64.");
            }
            if (decoded.length > MAX_BASE64_BODY) {
                throw new Main.SidecarException("invalid_request", "body.base64 exceeds 1 MiB.");
            }
            return decoded;
        }
        if (bodyNode.has("text")) {
            JsonNode textNode = bodyNode.get("text");
            if (!textNode.isTextual()) {
                throw new Main.SidecarException("invalid_request", "body.text must be a string.");
            }
            byte[] encoded = textNode.asText().getBytes(StandardCharsets.UTF_8);
            if (encoded.length > MAX_TEXT_BODY) {
                throw new Main.SidecarException("invalid_request", "body.text exceeds 64 KiB.");
            }
            return encoded;
        }
        throw new Main.SidecarException(
            "invalid_request",
            "body must be an object with exactly one of generate, base64, or text."
        );
    }

    private static synchronized S3Client conformanceClient(Main.Profile profile) {
        S3Client existing = CLIENTS.get(profile);
        if (existing != null) return Main.clientLease(existing);
        S3Client built = createConformanceClient(profile);
        if (CLIENTS.size() >= 16) return built;
        CLIENTS.put(profile, built);
        return Main.clientLease(built);
    }

    private static S3Client createConformanceClient(Main.Profile profile) {
        SecretHygiene.disableWireLogging();
        ApacheHttpClient.Builder httpClient = ApacheHttpClient.builder()
            .connectionTimeout(Duration.ofSeconds(profile.connectTimeoutSeconds()))
            .socketTimeout(Duration.ofSeconds(profile.readTimeoutSeconds()))
            .maxConnections(profile.maxPoolConnections());
        if (!profile.caBundlePath().isBlank()) {
            httpClient.tlsTrustManagersProvider(() -> Main.customCa(profile.caBundlePath()));
        }
        if (!profile.verifyTls()) {
            httpClient.tlsTrustManagersProvider(() -> Main.TRUST_ALL_MANAGERS);
        }

        ClientOverrideConfiguration.Builder overrideBuilder = ClientOverrideConfiguration.builder()
            .addExecutionInterceptor(INTERCEPTOR)
            .addExecutionInterceptor(new RequestTimeouts(Duration.ofSeconds(profile.readTimeoutSeconds())))
            .retryStrategy(DefaultRetryStrategy.doNotRetry());
        if (profile.requesterPays()) {
            overrideBuilder.putHeader("x-amz-request-payer", "requester");
        }
        if (!profile.expectedBucketOwner().isBlank()) {
            overrideBuilder.putHeader("x-amz-expected-bucket-owner", profile.expectedBucketOwner());
        }

        return S3Client.builder()
            .endpointOverride(URI.create(profile.endpointUrl()))
            .region(Region.of(profile.region()))
            .credentialsProvider(Main.credentialsProvider(profile))
            .serviceConfiguration(S3Configuration.builder().pathStyleAccessEnabled(profile.pathStyle()).build())
            .requestChecksumCalculation(RequestChecksumCalculation.WHEN_REQUIRED)
            .responseChecksumValidation(ResponseChecksumValidation.WHEN_REQUIRED)
            .httpClientBuilder(httpClient)
            .overrideConfiguration(overrideBuilder.build())
            .build();
    }

    private static OpBinding bindingFor(String op) {
        return BINDINGS.computeIfAbsent(op, S3Conformance::resolveBinding);
    }

    private static OpBinding resolveBinding(String op) {
        try {
            Class<?> requestClass = Class.forName("software.amazon.awssdk.services.s3.model." + op + "Request");
            Method builderMethod = requestClass.getMethod("builder");
            String methodName = Character.toLowerCase(op.charAt(0)) + op.substring(1);
            Method clientMethod = BODY_OPS.contains(op)
                ? S3Client.class.getMethod(methodName, requestClass, RequestBody.class)
                : S3Client.class.getMethod(methodName, requestClass);
            SdkPojo sample = (SdkPojo) ((Buildable) builderMethod.invoke(null)).build();
            Map<String, SdkField<?>> fields = new LinkedHashMap<>();
            for (SdkField<?> field : sample.sdkFields()) {
                fields.put(field.memberName(), field);
            }
            return new OpBinding(builderMethod, clientMethod, fields);
        } catch (ReflectiveOperationException error) {
            throw new Main.SidecarException(
                "unsupported_feature",
                "Operation " + op + " could not be bound in the Java SDK: " + error.getMessage()
            );
        }
    }

    private static S3Request.Builder buildRequestBuilder(String op, JsonNode inputNode) {
        OpBinding binding = bindingFor(op);
        Object builderObj;
        try {
            builderObj = binding.builderMethod.invoke(null);
        } catch (ReflectiveOperationException error) {
            throw new Main.SidecarException("unknown", "Failed to construct request builder for " + op + ".");
        }
        if (inputNode != null && inputNode.isObject()) {
            populatePojo(op, builderObj, binding.fields, inputNode, COPY_SOURCE_OPS.contains(op));
        }
        return (S3Request.Builder) builderObj;
    }

    private static void populatePojo(
            String contextName,
            Object builderObj,
            Map<String, SdkField<?>> fields,
            JsonNode jsonObject,
            boolean isCopyRequest) {
        var entries = jsonObject.fields();
        while (entries.hasNext()) {
            var entry = entries.next();
            String key = entry.getKey();
            JsonNode valueNode = entry.getValue();
            if (valueNode == null || valueNode.isNull()) continue;

            if (isCopyRequest && "CopySource".equals(key)) {
                applyCopySource(builderObj, fields, valueNode);
                continue;
            }
            String targetMember = key;
            if (isCopyRequest) {
                if ("Bucket".equals(key)) targetMember = "DestinationBucket";
                else if ("Key".equals(key)) targetMember = "DestinationKey";
            }

            SdkField<?> field = fields.get(targetMember);
            if (field == null) {
                throw new Main.SidecarException(
                    "invalid_request",
                    "Unknown input member " + key + " for " + contextName + "."
                );
            }
            Object converted = convertValue(contextName + "." + key, field, valueNode);
            field.set(builderObj, converted);
        }
    }

    private static void applyCopySource(Object builderObj, Map<String, SdkField<?>> fields, JsonNode sourceNode) {
        if (!sourceNode.isObject()) {
            throw new Main.SidecarException(
                "invalid_request",
                "CopySource must be an object with Bucket, Key, and optional VersionId."
            );
        }
        var names = sourceNode.fieldNames();
        while (names.hasNext()) {
            String k = names.next();
            if (!"Bucket".equals(k) && !"Key".equals(k) && !"VersionId".equals(k)) {
                throw new Main.SidecarException("invalid_request", "Unknown CopySource field: " + k);
            }
        }
        JsonNode bucketNode = sourceNode.get("Bucket");
        JsonNode keyNode = sourceNode.get("Key");
        if (bucketNode == null || !bucketNode.isTextual() || bucketNode.asText().isEmpty()) {
            throw new Main.SidecarException("invalid_request", "CopySource.Bucket is required.");
        }
        if (keyNode == null || !keyNode.isTextual() || keyNode.asText().isEmpty()) {
            throw new Main.SidecarException("invalid_request", "CopySource.Key is required.");
        }
        fields.get("SourceBucket").set(builderObj, bucketNode.asText());
        fields.get("SourceKey").set(builderObj, keyNode.asText());
        JsonNode versionNode = sourceNode.get("VersionId");
        if (versionNode != null && !versionNode.isNull()) {
            if (!versionNode.isTextual()) {
                throw new Main.SidecarException("invalid_request", "CopySource.VersionId must be a string.");
            }
            fields.get("SourceVersionId").set(builderObj, versionNode.asText());
        }
    }

    private static Object convertValue(String path, SdkField<?> field, JsonNode node) {
        MarshallingType<?> type = field.marshallingType();
        if (type == MarshallingType.STRING) {
            if (!node.isTextual()) {
                throw new Main.SidecarException("invalid_request", path + " must be a string.");
            }
            return node.asText();
        }
        if (type == MarshallingType.INTEGER) {
            if (node.isIntegralNumber() && node.canConvertToInt()) return node.intValue();
            if (node.isTextual()) {
                try { return Integer.parseInt(node.asText()); }
                catch (NumberFormatException ignored) {}
            }
            throw new Main.SidecarException("invalid_request", path + " must be an integer.");
        }
        if (type == MarshallingType.LONG) {
            if (node.isIntegralNumber() && node.canConvertToLong()) return node.longValue();
            if (node.isTextual()) {
                try { return Long.parseLong(node.asText()); }
                catch (NumberFormatException ignored) {}
            }
            throw new Main.SidecarException("invalid_request", path + " must be a long integer.");
        }
        if (type == MarshallingType.BOOLEAN) {
            if (!node.isBoolean()) {
                throw new Main.SidecarException("invalid_request", path + " must be a boolean.");
            }
            return node.booleanValue();
        }
        if (type == MarshallingType.DOUBLE) {
            if (!node.isNumber()) {
                throw new Main.SidecarException("invalid_request", path + " must be a number.");
            }
            return node.doubleValue();
        }
        if (type == MarshallingType.FLOAT) {
            if (!node.isNumber()) {
                throw new Main.SidecarException("invalid_request", path + " must be a number.");
            }
            return node.floatValue();
        }
        if (type == MarshallingType.INSTANT) {
            if (!node.isTextual()) {
                throw new Main.SidecarException("invalid_request", path + " must be an ISO-8601 timestamp string.");
            }
            try {
                return OffsetDateTime.parse(node.asText()).toInstant();
            } catch (DateTimeParseException error) {
                try {
                    return Instant.parse(node.asText());
                } catch (DateTimeParseException second) {
                    throw new Main.SidecarException("invalid_request", path + " is not a valid ISO-8601 timestamp.");
                }
            }
        }
        if (type == MarshallingType.SDK_POJO) {
            if (!node.isObject()) {
                throw new Main.SidecarException("invalid_request", path + " must be an object.");
            }
            SdkPojo childBuilder = field.constructor().get();
            SdkPojo sample = (SdkPojo) ((Buildable) childBuilder).build();
            Map<String, SdkField<?>> childFields = new LinkedHashMap<>();
            for (SdkField<?> childField : sample.sdkFields()) {
                childFields.put(childField.memberName(), childField);
            }
            populatePojo(path, childBuilder, childFields, node, false);
            return ((Buildable) childBuilder).build();
        }
        if (type == MarshallingType.LIST) {
            if (!node.isArray()) {
                throw new Main.SidecarException("invalid_request", path + " must be an array.");
            }
            ListTrait listTrait = field.getTrait(ListTrait.class);
            SdkField<?> memberField = listTrait.memberFieldInfo();
            List<Object> list = new ArrayList<>(node.size());
            int index = 0;
            for (JsonNode element : node) {
                if (element != null && !element.isNull()) {
                    list.add(convertValue(path + "[" + index + "]", memberField, element));
                }
                index++;
            }
            return list;
        }
        if (type == MarshallingType.MAP) {
            if (!node.isObject()) {
                throw new Main.SidecarException("invalid_request", path + " must be an object.");
            }
            MapTrait mapTrait = field.getTrait(MapTrait.class);
            SdkField<?> valueField = mapTrait.valueFieldInfo();
            Map<String, Object> map = new LinkedHashMap<>();
            var entries = node.fields();
            while (entries.hasNext()) {
                var entry = entries.next();
                if (entry.getValue() != null && !entry.getValue().isNull()) {
                    map.put(entry.getKey(), convertValue(path + "." + entry.getKey(), valueField, entry.getValue()));
                }
            }
            return map;
        }
        throw new Main.SidecarException("invalid_request", "Unsupported field type for " + path + ": " + type);
    }

    private static Map<String, Object> invokeOperation(
            S3Client client, String op, S3Request request, byte[] bodyBytes) {
        AttemptTracker tracker = new AttemptTracker();
        CURRENT_TRACKER.set(tracker);
        long startedNanos = System.nanoTime();
        try {
            if ("GetObject".equals(op)) {
                Map<String, Object> bodyDigest;
                GetObjectResponse response;
                try (ResponseInputStream<GetObjectResponse> stream = client.getObject((GetObjectRequest) request)) {
                    response = stream.response();
                    bodyDigest = digestStream(stream, stream::abort);
                }
                double latencyMs = elapsedMs(startedNanos);
                SdkHttpResponse http = response.sdkHttpResponse() != null
                    ? response.sdkHttpResponse()
                    : tracker.lastHttpResponse;
                int status = http != null ? http.statusCode() : 0;
                Map<String, String> headers = http != null ? filterHeaders(http.headers()) : Map.of();
                Map<String, Object> output = projectPojo(response);
                output.put("Body", bodyDigest);
                String requestId = extractRequestId(headers, response.responseMetadata().requestId());
                return buildResult(
                    op, "service", status, null, null, headers, output,
                    latencyMs, Math.max(tracker.attempts, 1), requestId
                );
            }

            OpBinding binding = bindingFor(op);
            Object rawResponse;
            try {
                if (BODY_OPS.contains(op)) {
                    RequestBody body = RequestBody.fromBytes(bodyBytes == null ? new byte[0] : bodyBytes);
                    rawResponse = binding.clientMethod.invoke(client, request, body);
                } else {
                    rawResponse = binding.clientMethod.invoke(client, request);
                }
            } catch (InvocationTargetException error) {
                Throwable cause = error.getCause();
                if (cause instanceof RuntimeException runtime) throw runtime;
                if (cause instanceof Error err) throw err;
                throw new RuntimeException(cause);
            } catch (IllegalAccessException error) {
                throw new RuntimeException(error);
            }

            double latencyMs = elapsedMs(startedNanos);
            S3Response response = (S3Response) rawResponse;
            SdkHttpResponse http = response.sdkHttpResponse() != null
                ? response.sdkHttpResponse()
                : tracker.lastHttpResponse;
            int status = http != null ? http.statusCode() : 0;
            Map<String, String> headers = http != null ? filterHeaders(http.headers()) : Map.of();
            Map<String, Object> output = projectPojo(response);
            String requestId = extractRequestId(headers, response.responseMetadata().requestId());
            return buildResult(
                op, "service", status, null, null, headers, output,
                latencyMs, Math.max(tracker.attempts, 1), requestId
            );
        } catch (S3Exception error) {
            double latencyMs = elapsedMs(startedNanos);
            SdkHttpResponse http = (error.awsErrorDetails() != null && error.awsErrorDetails().sdkHttpResponse() != null)
                ? error.awsErrorDetails().sdkHttpResponse()
                : tracker.lastHttpResponse;
            int status = error.statusCode() > 0
                ? error.statusCode()
                : (http != null ? http.statusCode() : 0);
            String outcome = status > 0 ? "service" : "sdk_decode";
            String errorCode = error.awsErrorDetails() != null
                ? blankToNull(error.awsErrorDetails().errorCode())
                : null;
            String rawMessage = error.awsErrorDetails() != null && error.awsErrorDetails().errorMessage() != null
                ? error.awsErrorDetails().errorMessage()
                : error.getMessage();
            Map<String, String> headers = http != null ? filterHeaders(http.headers()) : Map.of();
            String requestId = extractRequestId(headers, error.requestId());
            return buildResult(
                op, outcome, status, errorCode, sanitizeErrorMessage(rawMessage, null),
                headers, Map.of(), latencyMs, Math.max(tracker.attempts, status > 0 ? 1 : 0), requestId
            );
        } catch (Throwable error) {
            if (error instanceof Error err) throw err;
            double latencyMs = elapsedMs(startedNanos);
            return classifyNonServiceFailure(op, error, tracker, latencyMs);
        } finally {
            CURRENT_TRACKER.remove();
        }
    }

    private static Map<String, Object> classifyNonServiceFailure(
            String op, Throwable error, AttemptTracker tracker, double latencyMs) {
        SdkHttpResponse http = tracker.lastHttpResponse;
        int status = http != null ? http.statusCode() : 0;
        Map<String, String> headers = http != null ? filterHeaders(http.headers()) : Map.of();
        String requestId = extractRequestId(headers, null);

        boolean transport = isTransportFailure(error);
        String outcome;
        if (http != null) {
            outcome = transport ? "transport" : "sdk_decode";
        } else if (tracker.attempts > 0 || transport) {
            outcome = "transport";
        } else {
            outcome = "sdk_validation";
        }

        int attempts = "sdk_validation".equals(outcome) ? 0 : Math.max(tracker.attempts, 1);
        return buildResult(
            op,
            outcome,
            status,
            error.getClass().getSimpleName(),
            sanitizeErrorMessage(error.getMessage() != null ? error.getMessage() : error.toString(), null),
            headers,
            Map.of(),
            latencyMs,
            attempts,
            requestId
        );
    }

    private static boolean isTransportFailure(Throwable error) {
        for (Throwable cur = error; cur != null; cur = cur.getCause()) {
            if (cur instanceof IOException
                    || cur instanceof UncheckedIOException
                    || cur instanceof TimeoutException
                    || cur instanceof ApiCallTimeoutException
                    || cur instanceof ApiCallAttemptTimeoutException
                    || cur instanceof SSLException
                    || cur instanceof GeneralSecurityException
                    || cur instanceof UnknownHostException
                    || cur instanceof ConnectException
                    || cur instanceof SocketException
                    || cur instanceof SocketTimeoutException) {
                return true;
            }
            String msg = cur.getMessage();
            if (msg != null) {
                String lower = msg.toLowerCase(Locale.ROOT);
                if (lower.contains("unable to execute http request")
                        || lower.contains("connection refused")
                        || lower.contains("timed out")
                        || lower.contains("timeout")
                        || lower.contains("certificate")
                        || lower.contains("ssl")
                        || lower.contains("tls")) {
                    return true;
                }
            }
        }
        return false;
    }

    private static Map<String, Object> runPresignedRequest(
            Main.Profile profile, JsonNode inputNode, JsonNode bodyNode) {
        if (inputNode == null || !inputNode.isObject()) {
            throw new Main.SidecarException("invalid_request", "PresignedRequest requires an input object.");
        }
        var names = inputNode.fieldNames();
        while (names.hasNext()) {
            String k = names.next();
            if (!Set.of("Method", "Bucket", "Key", "VersionId", "ContentType", "ExpiresIn", "DelayMs").contains(k)) {
                throw new Main.SidecarException("invalid_request", "Unknown PresignedRequest field: " + k);
            }
        }

        String method = inputNode.hasNonNull("Method") ? inputNode.get("Method").asText("").toUpperCase(Locale.ROOT) : "GET";
        if (!"GET".equals(method) && !"PUT".equals(method)) {
            throw new Main.SidecarException("invalid_request", "PresignedRequest.Method must be GET or PUT.");
        }
        JsonNode bucketNode = inputNode.get("Bucket");
        JsonNode keyNode = inputNode.get("Key");
        if (bucketNode == null || !bucketNode.isTextual() || bucketNode.asText().isEmpty()) {
            throw new Main.SidecarException("invalid_request", "PresignedRequest.Bucket is required.");
        }
        if (keyNode == null || !keyNode.isTextual() || keyNode.asText().isEmpty()) {
            throw new Main.SidecarException("invalid_request", "PresignedRequest.Key is required.");
        }
        String bucket = bucketNode.asText();
        String key = keyNode.asText();

        int expiresIn = 300;
        if (inputNode.hasNonNull("ExpiresIn")) {
            JsonNode expNode = inputNode.get("ExpiresIn");
            if (!expNode.isIntegralNumber() || !expNode.canConvertToInt()) {
                throw new Main.SidecarException("invalid_request", "ExpiresIn must be an integer 1..3600.");
            }
            expiresIn = expNode.intValue();
        }
        if (expiresIn < 1 || expiresIn > 3600) {
            throw new Main.SidecarException("invalid_request", "ExpiresIn must be 1..3600 seconds.");
        }

        int delayMs = 0;
        if (inputNode.hasNonNull("DelayMs")) {
            JsonNode delayNode = inputNode.get("DelayMs");
            if (!delayNode.isIntegralNumber() || !delayNode.canConvertToInt()) {
                throw new Main.SidecarException("invalid_request", "DelayMs must be an integer 0..5000.");
            }
            delayMs = delayNode.intValue();
        }
        if (delayMs < 0 || delayMs > 5000) {
            throw new Main.SidecarException("invalid_request", "DelayMs must be 0..5000 ms.");
        }

        String versionId = null;
        String contentType = null;
        byte[] bodyBytes = new byte[0];
        if ("GET".equals(method)) {
            if (bodyNode != null && !bodyNode.isMissingNode() && !bodyNode.isNull()) {
                throw new Main.SidecarException("invalid_request", "A presigned GET does not accept a body.");
            }
            if (inputNode.hasNonNull("VersionId")) {
                if (!inputNode.get("VersionId").isTextual()) {
                    throw new Main.SidecarException("invalid_request", "VersionId must be a string.");
                }
                versionId = inputNode.get("VersionId").asText();
            }
        } else {
            if (inputNode.hasNonNull("ContentType")) {
                if (!inputNode.get("ContentType").isTextual()) {
                    throw new Main.SidecarException("invalid_request", "ContentType must be a string.");
                }
                contentType = inputNode.get("ContentType").asText();
            }
            bodyBytes = parseBody(bodyNode);
        }

        URL signedUrl;
        Map<String, List<String>> signedHeaders;
        double presignMs;
        S3Configuration serviceConfig = S3Configuration.builder()
            .pathStyleAccessEnabled(profile.pathStyle())
            .build();
        try (S3Presigner presigner = S3Presigner.builder()
                .region(Region.of(profile.region()))
                .credentialsProvider(Main.credentialsProvider(profile))
                .endpointOverride(URI.create(profile.endpointUrl()))
                .serviceConfiguration(serviceConfig)
                .build()) {
            long presignStart = System.nanoTime();
            if ("GET".equals(method)) {
                GetObjectRequest.Builder req = GetObjectRequest.builder().bucket(bucket).key(key);
                if (versionId != null) req.versionId(versionId);
                PresignedGetObjectRequest presigned = presigner.presignGetObject(
                    GetObjectPresignRequest.builder()
                        .signatureDuration(Duration.ofSeconds(expiresIn))
                        .getObjectRequest(req.build())
                        .build()
                );
                signedUrl = presigned.url();
                signedHeaders = presigned.signedHeaders();
            } else {
                PutObjectRequest.Builder req = PutObjectRequest.builder().bucket(bucket).key(key);
                if (contentType != null) req.contentType(contentType);
                PresignedPutObjectRequest presigned = presigner.presignPutObject(
                    PutObjectPresignRequest.builder()
                        .signatureDuration(Duration.ofSeconds(expiresIn))
                        .putObjectRequest(req.build())
                        .build()
                );
                signedUrl = presigned.url();
                signedHeaders = presigned.signedHeaders();
            }
            presignMs = elapsedMs(presignStart);
        } catch (RuntimeException error) {
            return buildResult(
                "PresignedRequest",
                "sdk_validation",
                0,
                error.getClass().getSimpleName(),
                sanitizeErrorMessage(error.getMessage(), null),
                Map.of(),
                Map.of(),
                0.0,
                0,
                null
            );
        }

        String rawUrl = signedUrl.toString();
        URI uri;
        try {
            uri = signedUrl.toURI();
        } catch (Exception error) {
            throw new Main.SidecarException("unknown", "Presigner produced an invalid URI.");
        }

        Map<String, Object> presignShape = new LinkedHashMap<>();
        presignShape.put("Method", method);
        presignShape.put("Scheme", uri.getScheme());
        presignShape.put("Host", uri.getAuthority());
        presignShape.put("QueryKeys", extractSortedQueryKeys(uri.getRawQuery()));
        presignShape.put("PresignMs", presignMs);

        if (delayMs > 0) {
            try {
                Thread.sleep(delayMs);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw new Main.SidecarException("cancelled", "Presigned request delay was interrupted.");
            }
        }

        HttpRequest.Builder reqBuilder = HttpRequest.newBuilder(uri)
            .timeout(Duration.ofSeconds(profile.readTimeoutSeconds()));
        if ("PUT".equals(method)) {
            reqBuilder.PUT(HttpRequest.BodyPublishers.ofByteArray(bodyBytes));
        } else {
            reqBuilder.GET();
        }
        // Apply signed headers only (skip host/content-length which HttpClient sets automatically).
        for (var entry : signedHeaders.entrySet()) {
            String headerName = entry.getKey();
            if (headerName.equalsIgnoreCase("host") || headerName.equalsIgnoreCase("content-length")) {
                continue;
            }
            for (String value : entry.getValue()) {
                reqBuilder.header(headerName, value);
            }
        }

        long sendStarted = System.nanoTime();
        try (HttpClient httpClient = buildPresignHttpClient(profile)) {
            HttpResponse<InputStream> response = httpClient.send(
                reqBuilder.build(),
                HttpResponse.BodyHandlers.ofInputStream()
            );
            int status = response.statusCode();
            Map<String, String> headers = filterHeaders(response.headers().map());
            String errorCode = null;
            String errorMessage = null;
            Map<String, Object> bodyDigest;
            try (InputStream bodyStream = response.body()) {
                if (status >= 300) {
                    byte[] raw = readBounded(bodyStream, MAX_PRESIGN_ERROR_BODY);
                    bodyDigest = digestBytes(raw);
                    String xml = new String(raw, StandardCharsets.UTF_8);
                    Matcher codeMatch = XML_ERROR_CODE.matcher(xml);
                    Matcher msgMatch = XML_ERROR_MESSAGE.matcher(xml);
                    if (codeMatch.find()) errorCode = codeMatch.group(1);
                    if (msgMatch.find()) {
                        errorMessage = sanitizeErrorMessage(msgMatch.group(1), rawUrl);
                    }
                } else {
                    bodyDigest = digestStream(bodyStream, null);
                }
            }
            double latencyMs = elapsedMs(sendStarted);
            Map<String, Object> output = new LinkedHashMap<>();
            output.put("Presign", presignShape);
            output.put("Body", bodyDigest);
            String requestId = headers.get("x-amz-request-id");
            return buildResult(
                "PresignedRequest", "service", status, errorCode, errorMessage,
                headers, output, latencyMs, 1, requestId
            );
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            double latencyMs = elapsedMs(sendStarted);
            Map<String, Object> output = new LinkedHashMap<>();
            output.put("Presign", presignShape);
            return buildResult(
                "PresignedRequest", "transport", 0, "InterruptedException",
                "Presigned HTTP request was interrupted.", Map.of(), output, latencyMs, 1, null
            );
        } catch (Exception error) {
            double latencyMs = elapsedMs(sendStarted);
            Map<String, Object> output = new LinkedHashMap<>();
            output.put("Presign", presignShape);
            return buildResult(
                "PresignedRequest",
                "transport",
                0,
                error.getClass().getSimpleName(),
                sanitizeErrorMessage(error.getMessage() != null ? error.getMessage() : error.toString(), rawUrl),
                Map.of(),
                output,
                latencyMs,
                1,
                null
            );
        }
    }

    private static HttpClient buildPresignHttpClient(Main.Profile profile) {
        HttpClient.Builder builder = HttpClient.newBuilder()
            .followRedirects(HttpClient.Redirect.NEVER)
            .connectTimeout(Duration.ofSeconds(profile.connectTimeoutSeconds()));
        if (!profile.verifyTls()) {
            builder.sslContext(sslContext(TRUST_ALL_EXTENDED));
        } else if (!profile.caBundlePath().isBlank()) {
            builder.sslContext(sslContext(Main.customCa(profile.caBundlePath())));
        }
        return builder.build();
    }

    private static SSLContext sslContext(TrustManager[] managers) {
        try {
            SSLContext context = SSLContext.getInstance("TLS");
            context.init(null, managers, new SecureRandom());
            return context;
        } catch (GeneralSecurityException error) {
            throw new Main.SidecarException("invalid_config", "Cannot initialize TLS context: " + error.getMessage());
        }
    }

    private static List<String> extractSortedQueryKeys(String rawQuery) {
        if (rawQuery == null || rawQuery.isEmpty()) return List.of();
        Set<String> keys = new TreeSet<>();
        for (String pair : rawQuery.split("&")) {
            if (pair.isEmpty()) continue;
            int eq = pair.indexOf('=');
            String key = eq >= 0 ? pair.substring(0, eq) : pair;
            if (!key.isEmpty()) keys.add(key);
        }
        return new ArrayList<>(keys);
    }

    static Map<String, String> filterHeaders(Map<String, List<String>> rawHeaders) {
        if (rawHeaders == null || rawHeaders.isEmpty()) return Map.of();
        Map<String, List<String>> grouped = new TreeMap<>();
        for (var entry : rawHeaders.entrySet()) {
            if (entry.getKey() == null || entry.getValue() == null) continue;
            String lower = entry.getKey().toLowerCase(Locale.ROOT);
            boolean allowed = HEADER_ALLOWLIST.contains(lower)
                || lower.startsWith("x-amz-meta-")
                || lower.startsWith("x-amz-checksum-");
            if (!allowed) continue;
            grouped.computeIfAbsent(lower, k -> new ArrayList<>()).addAll(entry.getValue());
        }
        Map<String, String> result = new LinkedHashMap<>();
        // Add non-meta headers first so core headers are never displaced by x-amz-meta-* headers.
        for (var entry : grouped.entrySet()) {
            if (result.size() >= MAX_HEADERS) break;
            if (entry.getKey().startsWith("x-amz-meta-")) continue;
            result.put(entry.getKey(), joinAndTruncateHeader(entry.getValue()));
        }
        int metaCount = 0;
        for (var entry : grouped.entrySet()) {
            if (result.size() >= MAX_HEADERS || metaCount >= MAX_META_HEADERS) break;
            if (!entry.getKey().startsWith("x-amz-meta-")) continue;
            result.put(entry.getKey(), joinAndTruncateHeader(entry.getValue()));
            metaCount++;
        }
        return result;
    }

    private static String joinAndTruncateHeader(List<String> values) {
        String joined = String.join(", ", values);
        return joined.length() > MAX_HEADER_VALUE ? joined.substring(0, MAX_HEADER_VALUE) : joined;
    }

    static Map<String, Object> projectPojo(SdkPojo pojo) {
        Map<String, Object> out = new LinkedHashMap<>();
        if (pojo == null) return out;
        for (SdkField<?> field : pojo.sdkFields()) {
            Object value = field.getValueOrDefault(pojo);
            if (value == null) continue;
            if (value instanceof SdkAutoConstructList || value instanceof SdkAutoConstructMap) continue;
            Object projected = projectValue(value);
            if (projected != null) {
                out.put(field.memberName(), projected);
            }
        }
        return out;
    }

    private static Object projectValue(Object value) {
        if (value == null) return null;
        if (value instanceof SdkAutoConstructList || value instanceof SdkAutoConstructMap) return null;
        if (value instanceof Instant instant) {
            return DateTimeFormatter.ISO_INSTANT.format(instant);
        }
        if (value instanceof SdkPojo nested) {
            return projectPojo(nested);
        }
        if (value instanceof Collection<?> collection) {
            List<Object> list = new ArrayList<>(collection.size());
            for (Object item : collection) {
                Object projected = projectValue(item);
                if (projected != null) list.add(projected);
            }
            return list;
        }
        if (value instanceof Map<?, ?> map) {
            Map<String, Object> copy = new LinkedHashMap<>();
            for (var entry : map.entrySet()) {
                Object projected = projectValue(entry.getValue());
                if (projected != null) copy.put(String.valueOf(entry.getKey()), projected);
            }
            return copy;
        }
        if (value instanceof Enum<?> enumVal) {
            return enumVal.toString();
        }
        if (value instanceof SdkBytes bytes) {
            return Base64.getEncoder().encodeToString(bytes.asByteArray());
        }
        if (value instanceof byte[] bytes) {
            return Base64.getEncoder().encodeToString(bytes);
        }
        return value;
    }

    private static Map<String, Object> digestStream(InputStream stream, Runnable onTruncate) throws IOException {
        MessageDigest sha256 = newSha256();
        byte[] buffer = new byte[65536];
        long length = 0;
        boolean truncated = false;
        while (length < MAX_BODY_READ) {
            int maxRead = (int) Math.min(buffer.length, MAX_BODY_READ - length);
            int read = stream.read(buffer, 0, maxRead);
            if (read < 0) break;
            if (read > 0) {
                sha256.update(buffer, 0, read);
                length += read;
            }
        }
        if (length == MAX_BODY_READ) {
            byte[] probe = new byte[1];
            int extra = stream.read(probe, 0, 1);
            if (extra > 0) {
                truncated = true;
                if (onTruncate != null) onTruncate.run();
            }
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("length", length);
        result.put("sha256", HEX.formatHex(sha256.digest()));
        if (truncated) result.put("truncated", true);
        return result;
    }

    private static Map<String, Object> digestBytes(byte[] bytes) {
        MessageDigest sha256 = newSha256();
        sha256.update(bytes);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("length", bytes.length);
        result.put("sha256", HEX.formatHex(sha256.digest()));
        return result;
    }

    private static byte[] readBounded(InputStream stream, int maxBytes) throws IOException {
        if (stream == null) return new byte[0];
        byte[] buffer = new byte[8192];
        var out = new java.io.ByteArrayOutputStream();
        int remaining = maxBytes;
        while (remaining > 0) {
            int read = stream.read(buffer, 0, Math.min(buffer.length, remaining));
            if (read < 0) break;
            out.write(buffer, 0, read);
            remaining -= read;
        }
        return out.toByteArray();
    }

    private static MessageDigest newSha256() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (Exception error) {
            throw new IllegalStateException("SHA-256 unavailable", error);
        }
    }

    static String sanitizeErrorMessage(String raw, String presignedUrl) {
        if (raw == null) return null;
        String text = raw;
        if (presignedUrl != null && !presignedUrl.isEmpty()) {
            text = text.replace(presignedUrl, "[presigned-url]");
            int qIdx = presignedUrl.indexOf('?');
            if (qIdx >= 0 && qIdx + 1 < presignedUrl.length()) {
                String rawQuery = presignedUrl.substring(qIdx + 1);
                if (!rawQuery.isEmpty()) {
                    text = text.replace(rawQuery, "[query]");
                }
            }
        }
        text = URL_WITH_QUERY.matcher(text).replaceAll("$1?[query]");
        text = SecretHygiene.text(text);
        if (text == null) return null;
        return text.length() > MAX_ERROR_MESSAGE ? text.substring(0, MAX_ERROR_MESSAGE) : text;
    }

    private static String extractRequestId(Map<String, String> headers, String sdkRequestId) {
        String fromHeader = blankToNull(headers.get("x-amz-request-id"));
        if (fromHeader != null) return fromHeader;
        String cleaned = blankToNull(sdkRequestId);
        if (cleaned == null || "UNKNOWN".equals(cleaned)) return null;
        return cleaned;
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value;
    }

    private static double elapsedMs(long startedNanos) {
        double ms = (System.nanoTime() - startedNanos) / 1_000_000.0;
        return Math.round(ms * 1000.0) / 1000.0;
    }

    private static Map<String, Object> buildResult(
            String op,
            String outcome,
            int httpStatus,
            String errorCode,
            String errorMessage,
            Map<String, String> headers,
            Map<String, Object> output,
            double latencyMs,
            int attempts,
            String requestId) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("op", op);
        result.put("outcome", outcome);
        result.put("httpStatus", httpStatus);
        result.put("errorCode", errorCode);
        result.put("errorMessage", errorMessage);
        result.put("headers", headers == null ? Map.of() : headers);
        result.put("output", output == null ? Map.of() : output);
        result.put("latencyMs", latencyMs);
        result.put("attempts", attempts);
        result.put("requestId", requestId);
        return result;
    }

    private static final class AttemptTracker {
        int attempts;
        SdkHttpResponse lastHttpResponse;
    }

    private static final class ConformanceInterceptor implements ExecutionInterceptor {
        @Override
        public void beforeTransmission(Context.BeforeTransmission context, ExecutionAttributes attributes) {
            AttemptTracker tracker = CURRENT_TRACKER.get();
            if (tracker != null) tracker.attempts++;
        }

        @Override
        public void afterTransmission(Context.AfterTransmission context, ExecutionAttributes attributes) {
            AttemptTracker tracker = CURRENT_TRACKER.get();
            if (tracker != null) tracker.lastHttpResponse = context.httpResponse();
        }
    }

    private record OpBinding(Method builderMethod, Method clientMethod, Map<String, SdkField<?>> fields) {}
}
