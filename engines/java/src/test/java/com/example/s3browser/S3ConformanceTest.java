package com.example.s3browser;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sun.net.httpserver.HttpServer;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.lang.reflect.Method;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Collections;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** Offline regression tests for S3 API conformance (`s3ConformanceOp`) and SecretHygiene cursor fix. */
public final class S3ConformanceTest {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final HexFormat HEX = HexFormat.of();
    private static final String SSE_KEY =
        Base64.getEncoder().encodeToString("0123456789abcdef0123456789abcdef".getBytes(StandardCharsets.UTF_8));
    private static final String SRC_SSE_KEY =
        Base64.getEncoder().encodeToString("fedcba9876543210fedcba9876543210".getBytes(StandardCharsets.UTF_8));

    public static void main(String[] args) throws Exception {
        run();
        System.out.println("S3Conformance checks passed.");
    }

    static void run() throws Exception {
        bodyGeneratorVectors();
        bodyValidationCaps();
        secretHygienePaginationCursors();
        allAllowlistOperationsBind();
        healthAndCapabilities();
        fakeS3ConformanceFlows();
        nonServiceOutcomes();
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static Path vectorsPath() {
        for (Path candidate : List.of(
                Path.of("../../contracts/vectors/s3-conformance-body.json"),
                Path.of("contracts/vectors/s3-conformance-body.json"))) {
            if (Files.isRegularFile(candidate)) return candidate;
        }
        throw new AssertionError("Cannot locate contracts/vectors/s3-conformance-body.json from " + Path.of("").toAbsolutePath());
    }

    private static String sha256Hex(byte[] data) throws Exception {
        return HEX.formatHex(MessageDigest.getInstance("SHA-256").digest(data));
    }

    private static void bodyGeneratorVectors() throws Exception {
        JsonNode root = JSON.readTree(Files.readString(vectorsPath(), StandardCharsets.UTF_8));
        JsonNode cases = root.path("cases");
        check(cases.isArray() && cases.size() >= 7, "Expected conformance body vectors");
        for (JsonNode c : cases) {
            int size = c.path("size").asInt();
            int seed = c.path("seed").asInt();
            String expectedSha = c.path("sha256").asText();
            String expectedFirst8 = c.path("first8Hex").asText();
            byte[] actual = S3Conformance.generateBody(size, seed);
            check(actual.length == size, "Generated body length mismatch for size=" + size);
            String actualSha = sha256Hex(actual);
            check(actualSha.equals(expectedSha),
                "Generated body sha256 mismatch for size=" + size + " seed=" + seed
                    + ": got " + actualSha + ", expected " + expectedSha);
            String actualFirst8 = HEX.formatHex(actual, 0, Math.min(8, actual.length));
            check(actualFirst8.equals(expectedFirst8),
                "Generated body first8Hex mismatch for size=" + size + " seed=" + seed
                    + ": got " + actualFirst8 + ", expected " + expectedFirst8);
        }
    }

    private static void bodyValidationCaps() throws Exception {
        check(S3Conformance.parseBody(null).length == 0, "Null body -> empty bytes");
        check(Arrays.equals(
            S3Conformance.parseBody(JSON.readTree("{\"text\":\"hello\"}")),
            "hello".getBytes(StandardCharsets.UTF_8)), "Text body");
        check(Arrays.equals(
            S3Conformance.parseBody(JSON.readTree("{\"base64\":\"YWJj\"}")),
            "abc".getBytes(StandardCharsets.UTF_8)), "Base64 body");

        String[] badBodies = {
            "{}",
            "{\"text\":\"a\",\"base64\":\"YQ==\"}",
            "{\"unknown\":1}",
            "{\"generate\":{\"size\":-1,\"seed\":0}}",
            "{\"generate\":{\"size\":16777217,\"seed\":0}}",
            "{\"generate\":{\"size\":10,\"seed\":-1}}",
            "{\"generate\":{\"size\":10,\"seed\":65536}}",
            "{\"generate\":{\"size\":10,\"seed\":1,\"extra\":2}}",
            "{\"base64\":\"not-valid-base64!!!\"}",
            "{\"text\":123}"
        };
        for (String raw : badBodies) {
            try {
                S3Conformance.parseBody(JSON.readTree(raw));
                throw new AssertionError("Invalid body accepted: " + raw);
            } catch (Main.SidecarException expected) {
                check(sidecarCode(expected).equals("invalid_request"),
                    "Expected invalid_request for " + raw + ", got " + sidecarCode(expected));
            }
        }

        ObjectNode overBase64 = JSON.createObjectNode()
            .put("base64", Base64.getEncoder().encodeToString(new byte[1024 * 1024 + 1]));
        try {
            S3Conformance.parseBody(overBase64);
            throw new AssertionError("Over-cap base64 accepted");
        } catch (Main.SidecarException expected) {
            check(sidecarCode(expected).equals("invalid_request"), "Over-cap base64 -> invalid_request");
        }

        ObjectNode overText = JSON.createObjectNode().put("text", "a".repeat(64 * 1024 + 1));
        try {
            S3Conformance.parseBody(overText);
            throw new AssertionError("Over-cap text accepted");
        } catch (Main.SidecarException expected) {
            check(sidecarCode(expected).equals("invalid_request"), "Over-cap text -> invalid_request");
        }
    }

    private static void secretHygienePaginationCursors() throws Exception {
        // Pagination cursors survive both SecretHygiene.sensitive/clean and SecretHygiene.text.
        for (String cursorField : List.of(
                "ContinuationToken", "NextContinuationToken", "Marker", "NextMarker")) {
            check(!SecretHygiene.sensitive(cursorField), "Cursor field must not be sensitive: " + cursorField);
            Map<String, Object> cleaned = castMap(SecretHygiene.clean(Map.of(cursorField, "opaque-cursor-value-1234567890")));
            check("opaque-cursor-value-1234567890".equals(cleaned.get(cursorField)),
                "Cursor value must survive SecretHygiene.clean: " + cursorField);
            String diag = SecretHygiene.text(cursorField + "=opaque-cursor-value-1234567890");
            check(diag.contains("opaque-cursor-value-1234567890"),
                "Cursor value must survive SecretHygiene.text: " + cursorField);
        }

        // Real tokens, authorization, secrets, and customer keys MUST stay redacted.
        for (String secretField : List.of(
                "sessionToken", "x-amz-security-token", "accessToken", "refreshToken",
                "sasToken", "token", "authorization", "secretKey", "customerKey", "fileKey",
                // Only the exact S3 cursor names are exempt; other *Token fields stay sensitive.
                "X-Auth-Page-Token", "nextPageToken", "rewriteToken", "NextToken", "continuation_token",
                "x-amz-server-side-encryption-customer-key",
                "x-amz-copy-source-server-side-encryption-customer-key")) {
            check(SecretHygiene.sensitive(secretField), "Secret field must stay sensitive: " + secretField);
            Map<String, Object> cleaned = castMap(SecretHygiene.clean(Map.of(secretField, "super-secret-value-1234567890")));
            check("[REDACTED]".equals(cleaned.get(secretField)),
                "Secret field must be redacted by SecretHygiene.clean: " + secretField);
            String diag = SecretHygiene.text(secretField + "=super-secret-value-1234567890");
            check(!diag.contains("super-secret-value-1234567890"),
                "Secret field must be redacted by SecretHygiene.text: " + secretField);
        }

        // Long ContinuationToken in request input must NOT be collected into ACTIVE scrub set.
        ObjectNode req = JSON.createObjectNode();
        req.putObject("params")
            .putObject("input")
            .put("ContinuationToken", "cursor-token-over-sixteen-chars-xyz");
        try (SecretHygiene hygiene = new SecretHygiene(req)) {
            Map<String, Object> cleaned = castMap(SecretHygiene.clean(
                Map.of("ContinuationToken", "cursor-token-over-sixteen-chars-xyz",
                       "NextContinuationToken", "cursor-token-over-sixteen-chars-xyz-next")));
            check("cursor-token-over-sixteen-chars-xyz".equals(cleaned.get("ContinuationToken")),
                "Long ContinuationToken echoed in response must not be scrubbed");
        }
    }

    private static void allAllowlistOperationsBind() throws Exception {
        check(S3Conformance.OPERATIONS.size() == 88,
            "Expected 88 operations in allowlist, got " + S3Conformance.OPERATIONS.size());
        Method resolve = S3Conformance.class.getDeclaredMethod("bindingFor", String.class);
        resolve.setAccessible(true);
        for (String op : S3Conformance.OPERATIONS) {
            if ("PresignedRequest".equals(op)) continue;
            Object binding = resolve.invoke(null, op);
            check(binding != null, "Binding failed for " + op);
        }
    }

    private static void healthAndCapabilities() throws Exception {
        JsonNode health = rpc("health", JSON.createObjectNode()).path("result");
        boolean hasMethod = false;
        for (JsonNode m : health.path("methods")) {
            if ("s3ConformanceOp".equals(m.asText())) hasMethod = true;
        }
        check(hasMethod, "health.methods must include s3ConformanceOp");

        for (String endpointType : List.of("s3Compatible", "awsS3")) {
            ObjectNode params = JSON.createObjectNode();
            params.putObject("profile").put("endpointType", endpointType);
            JsonNode caps = rpc("getCapabilities", params).path("result");
            JsonNode item = findCapability(caps, "conformance.s3");
            check(item != null, "conformance.s3 missing for " + endpointType);
            check("supported".equals(item.path("state").asText()), "Expected supported for " + endpointType);
            check(item.path("version").asInt() == 1, "Expected version 1");
            check(S3Conformance.SDK_VERSION.equals(item.path("sdk").asText()), "Expected SDK version");
            check(item.path("client").path("maxAttempts").asInt() == 1, "client.maxAttempts == 1");
            check("when_required".equals(item.path("client").path("requestChecksumCalculation").asText()),
                "client.requestChecksumCalculation == when_required");
            check("when_required".equals(item.path("client").path("responseChecksumValidation").asText()),
                "client.responseChecksumValidation == when_required");
            check(item.path("ops").size() == 88, "Expected 88 ops in capability");
        }

        for (String nonS3 : List.of("azureBlob", "googleCloudStorage")) {
            ObjectNode params = JSON.createObjectNode();
            params.putObject("profile").put("endpointType", nonS3);
            JsonNode caps = rpc("getCapabilities", params).path("result");
            JsonNode item = findCapability(caps, "conformance.s3");
            check(item != null && "unsupported".equals(item.path("state").asText()),
                "Expected unsupported conformance.s3 for " + nonS3);

            ObjectNode opParams = JSON.createObjectNode();
            opParams.putObject("profile")
                .put("endpointType", nonS3)
                .put("endpointUrl", "https://example.invalid")
                .put("accessKey", "ak")
                .put("secretKey", "sk");
            opParams.put("op", "ListBuckets");
            JsonNode err = rpc("s3ConformanceOp", opParams);
            check(!err.path("ok").asBoolean() && "unsupported_feature".equals(err.path("error").path("code").asText()),
                "Expected unsupported_feature for " + nonS3 + " profile");
        }
    }

    private static void fakeS3ConformanceFlows() throws Exception {
        Map<String, byte[]> store = new LinkedHashMap<>();
        List<CapturedRequest> requests = new CopyOnWriteArrayList<>();
        AtomicInteger hits500 = new AtomicInteger();
        AtomicInteger hitsRedirectTarget = new AtomicInteger();
        AtomicReference<String> lastPresignedQuery = new AtomicReference<>("");

        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", ex -> {
            String method = ex.getRequestMethod();
            String rawPath = ex.getRequestURI().getRawPath();
            String rawQuery = ex.getRequestURI().getRawQuery();
            byte[] reqBody = ex.getRequestBody().readAllBytes();
            Map<String, List<String>> reqHeaders = new LinkedHashMap<>();
            ex.getRequestHeaders().forEach((k, v) -> reqHeaders.put(k.toLowerCase(), List.copyOf(v)));
            if (reqHeaders.getOrDefault("content-encoding", List.of()).stream().anyMatch(v -> v.contains("aws-chunked"))) {
                reqBody = decodeAwsChunks(reqBody);
            }
            requests.add(new CapturedRequest(method, rawPath, rawQuery == null ? "" : rawQuery, reqHeaders, reqBody));

            var respHeaders = ex.getResponseHeaders();
            respHeaders.add("x-amz-request-id", "req-fake-123");
            // Non-allowlisted headers that must NEVER leak into observation.headers:
            respHeaders.add("X-Internal-Secret", "must-not-leak");
            respHeaders.add("Set-Cookie", "sid=secret-cookie");
            respHeaders.add("Authorization", "AWS4-HMAC-SHA256 secret");
            respHeaders.add("X-Amz-Security-Token", "secret-session-tok");

            if ("PUT".equals(method) && rawPath.equals("/test-bucket/hello.bin")) {
                store.put("hello.bin", reqBody);
                respHeaders.add("ETag", "\"etag-hello\"");
                respHeaders.add("Content-Type", "application/octet-stream");
                respHeaders.add("x-amz-version-id", "v-put-1");
                ex.sendResponseHeaders(200, -1);
            } else if ("GET".equals(method) && rawPath.equals("/test-bucket/hello.bin")) {
                byte[] data = store.getOrDefault("hello.bin", new byte[0]);
                respHeaders.add("ETag", "\"etag-hello\"");
                respHeaders.add("Content-Type", "application/octet-stream");
                respHeaders.add("x-amz-meta-author", "alice");
                respHeaders.add("x-amz-meta-long", "x".repeat(600));
                for (int i = 0; i < 20; i++) {
                    respHeaders.add("x-amz-meta-k" + String.format("%02d", i), "v" + i);
                }
                if (rawQuery != null && rawQuery.contains("X-Amz-Signature=")) {
                    lastPresignedQuery.set(rawQuery);
                }
                ex.sendResponseHeaders(200, data.length);
                ex.getResponseBody().write(data);
            } else if ("PUT".equals(method) && rawPath.equals("/test-bucket/presigned-put.txt")) {
                if (rawQuery != null && rawQuery.contains("X-Amz-Signature=")) {
                    lastPresignedQuery.set(rawQuery);
                }
                store.put("presigned-put.txt", reqBody);
                respHeaders.add("ETag", "\"etag-presigned-put\"");
                ex.sendResponseHeaders(200, -1);
            } else if ("GET".equals(method) && rawPath.equals("/test-bucket/presigned-denied.txt")) {
                if (rawQuery != null && rawQuery.contains("X-Amz-Signature=")) {
                    lastPresignedQuery.set(rawQuery);
                }
                byte[] xml = ("<Error><Code>AccessDenied</Code><Message>Request has expired</Message></Error>")
                    .getBytes(StandardCharsets.UTF_8);
                respHeaders.add("Content-Type", "application/xml");
                ex.sendResponseHeaders(403, xml.length);
                ex.getResponseBody().write(xml);
            } else if ("GET".equals(method) && rawPath.equals("/test-bucket/missing-404")) {
                respHeaders.add("x-amz-delete-marker", "true");
                respHeaders.add("x-amz-version-id", "dm-v1");
                byte[] xml = ("<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>")
                    .getBytes(StandardCharsets.UTF_8);
                respHeaders.add("Content-Type", "application/xml");
                ex.sendResponseHeaders(404, xml.length);
                ex.getResponseBody().write(xml);
            } else if ("HEAD".equals(method) && rawPath.equals("/test-bucket/missing-head")) {
                respHeaders.add("x-amz-delete-marker", "true");
                ex.sendResponseHeaders(404, -1);
            } else if ("GET".equals(method) && rawPath.equals("/test-bucket/not-modified")) {
                respHeaders.add("ETag", "\"etag-304\"");
                ex.sendResponseHeaders(304, -1);
            } else if ("GET".equals(method) && rawPath.equals("/test-bucket/redirect-302")) {
                respHeaders.add("Location", "http://127.0.0.1:" + server.getAddress().getPort() + "/test-bucket/redirect-target");
                ex.sendResponseHeaders(302, -1);
            } else if (rawPath.equals("/test-bucket/redirect-target")) {
                hitsRedirectTarget.incrementAndGet();
                ex.sendResponseHeaders(200, 0);
            } else if ("GET".equals(method) && rawPath.equals("/test-bucket/error-500")) {
                hits500.incrementAndGet();
                byte[] xml = "<Error><Code>InternalError</Code><Message>Transient failure</Message></Error>"
                    .getBytes(StandardCharsets.UTF_8);
                ex.sendResponseHeaders(500, xml.length);
                ex.getResponseBody().write(xml);
            } else if ("GET".equals(method) && rawPath.equals("/test-bucket") && rawQuery != null && rawQuery.contains("list-type=2")) {
                byte[] xml = (
                    "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
                    + "<Name>test-bucket</Name>"
                    + "<Prefix>docs/</Prefix>"
                    + "<KeyCount>1</KeyCount>"
                    + "<MaxKeys>10</MaxKeys>"
                    + "<IsTruncated>true</IsTruncated>"
                    + "<ContinuationToken>cursor-in-1234567890abcdef</ContinuationToken>"
                    + "<NextContinuationToken>cursor-next-9876543210fedcba</NextContinuationToken>"
                    + "<Contents>"
                    + "<Key>docs/readme.md</Key>"
                    + "<LastModified>2026-11-22T10:00:00.000Z</LastModified>"
                    + "<ETag>\"etag-readme\"</ETag>"
                    + "<Size>42</Size>"
                    + "<StorageClass>STANDARD</StorageClass>"
                    + "</Contents>"
                    + "<CommonPrefixes><Prefix>docs/sub/</Prefix></CommonPrefixes>"
                    + "</ListBucketResult>"
                ).getBytes(StandardCharsets.UTF_8);
                respHeaders.add("Content-Type", "application/xml");
                ex.sendResponseHeaders(200, xml.length);
                ex.getResponseBody().write(xml);
            } else if ("POST".equals(method) && rawPath.equals("/test-bucket") && rawQuery != null && rawQuery.contains("delete")) {
                byte[] xml = (
                    "<DeleteResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
                    + "<Deleted><Key>a.txt</Key><VersionId>v1</VersionId><DeleteMarker>true</DeleteMarker><DeleteMarkerVersionId>dm1</DeleteMarkerVersionId></Deleted>"
                    + "<Error><Key>b.txt</Key><VersionId>v2</VersionId><Code>AccessDenied</Code><Message>Denied</Message></Error>"
                    + "</DeleteResult>"
                ).getBytes(StandardCharsets.UTF_8);
                respHeaders.add("Content-Type", "application/xml");
                ex.sendResponseHeaders(200, xml.length);
                ex.getResponseBody().write(xml);
            } else if ("PUT".equals(method) && rawPath.equals("/test-bucket/copied.txt")) {
                byte[] xml = (
                    "<CopyObjectResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
                    + "<ETag>\"etag-copied\"</ETag>"
                    + "<LastModified>2026-11-22T11:00:00.000Z</LastModified>"
                    + "</CopyObjectResult>"
                ).getBytes(StandardCharsets.UTF_8);
                respHeaders.add("Content-Type", "application/xml");
                respHeaders.add("x-amz-copy-source-version-id", "src-v1");
                ex.sendResponseHeaders(200, xml.length);
                ex.getResponseBody().write(xml);
            } else if ("PUT".equals(method) && rawPath.equals("/test-bucket/mpu-copy.bin")) {
                byte[] xml = (
                    "<CopyPartResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
                    + "<ETag>\"etag-part-copy\"</ETag>"
                    + "<LastModified>2026-11-22T11:05:00.000Z</LastModified>"
                    + "</CopyPartResult>"
                ).getBytes(StandardCharsets.UTF_8);
                respHeaders.add("Content-Type", "application/xml");
                ex.sendResponseHeaders(200, xml.length);
                ex.getResponseBody().write(xml);
            } else {
                ex.sendResponseHeaders(404, -1);
            }
            ex.close();
        });
        server.start();
        String endpoint = "http://127.0.0.1:" + server.getAddress().getPort();
        try {
            // 1. PutObject (awsS3 endpointType to verify WHEN_REQUIRED checksums) + GetObject
            ObjectNode putParams = baseParams(endpoint, "awsS3", "PutObject");
            putParams.putObject("input")
                .put("Bucket", "test-bucket")
                .put("Key", "hello.bin")
                .put("ContentType", "application/octet-stream");
            putParams.putObject("body").putObject("generate").put("size", 1024).put("seed", 7);
            JsonNode putRes = rpcSuccess("s3ConformanceOp", putParams);
            check("service".equals(putRes.path("outcome").asText()), "PutObject outcome");
            check(putRes.path("httpStatus").asInt() == 200, "PutObject status 200");
            check(putRes.path("attempts").asInt() == 1, "PutObject attempts 1");
            check(putRes.path("latencyMs").asDouble() >= 0.0, "PutObject latencyMs present");
            check("\"etag-hello\"".equals(putRes.path("headers").path("etag").asText()), "PutObject etag header");
            check("v-put-1".equals(putRes.path("headers").path("x-amz-version-id").asText()), "PutObject version header");
            check("req-fake-123".equals(putRes.path("requestId").asText()), "PutObject requestId");
            // Verify WHEN_REQUIRED checksum: no x-amz-checksum-crc32 header sent on PutObject!
            CapturedRequest putWire = requests.get(requests.size() - 1);
            check(putWire.headers.keySet().stream().noneMatch(h -> h.startsWith("x-amz-checksum-")),
                "PutObject must not auto-send checksums under WHEN_REQUIRED: " + putWire.headers.keySet());
            byte[] expectedBytes = S3Conformance.generateBody(1024, 7);
            check(Arrays.equals(putWire.body, expectedBytes), "PutObject wire body matches generator");

            ObjectNode getParams = baseParams(endpoint, "s3Compatible", "GetObject");
            getParams.putObject("input").put("Bucket", "test-bucket").put("Key", "hello.bin");
            JsonNode getRes = rpcSuccess("s3ConformanceOp", getParams);
            check("service".equals(getRes.path("outcome").asText()), "GetObject outcome");
            check(getRes.path("httpStatus").asInt() == 200, "GetObject status 200");
            check(getRes.path("output").path("Body").path("length").asInt() == 1024, "GetObject Body.length");
            check(sha256Hex(expectedBytes).equals(getRes.path("output").path("Body").path("sha256").asText()),
                "GetObject Body.sha256");
            check(!getRes.path("output").path("Body").has("truncated"), "GetObject Body not truncated");
            JsonNode getHeaders = getRes.path("headers");
            check(!getHeaders.has("x-internal-secret") && !getHeaders.has("set-cookie")
                && !getHeaders.has("authorization") && !getHeaders.has("x-amz-security-token"),
                "Non-allowlisted/secret headers must not leak: " + getHeaders);
            int metaHeaders = 0;
            var hn = getHeaders.fieldNames();
            while (hn.hasNext()) {
                String k = hn.next();
                check(k.equals(k.toLowerCase()), "Header key must be lower-case: " + k);
                check(getHeaders.get(k).asText().length() <= 512, "Header value must be <= 512 chars: " + k);
                if (k.startsWith("x-amz-meta-")) metaHeaders++;
            }
            check(metaHeaders <= 16, "At most 16 x-amz-meta-* headers, got " + metaHeaders);

            // 2. GetObject 404 NoSuchKey + x-amz-delete-marker preserved
            ObjectNode get404 = baseParams(endpoint, "s3Compatible", "GetObject");
            get404.putObject("input").put("Bucket", "test-bucket").put("Key", "missing-404");
            JsonNode res404 = rpcSuccess("s3ConformanceOp", get404);
            check("service".equals(res404.path("outcome").asText()), "404 outcome service");
            check(res404.path("httpStatus").asInt() == 404, "404 status");
            check("NoSuchKey".equals(res404.path("errorCode").asText()), "404 errorCode NoSuchKey");
            check("true".equals(res404.path("headers").path("x-amz-delete-marker").asText()),
                "404 x-amz-delete-marker header preserved");
            check("dm-v1".equals(res404.path("headers").path("x-amz-version-id").asText()),
                "404 x-amz-version-id preserved");

            // 3. HeadObject 404 (no body) -> status 404 outcome service
            ObjectNode head404 = baseParams(endpoint, "s3Compatible", "HeadObject");
            head404.putObject("input").put("Bucket", "test-bucket").put("Key", "missing-head");
            JsonNode resHead404 = rpcSuccess("s3ConformanceOp", head404);
            check("service".equals(resHead404.path("outcome").asText()), "HEAD 404 outcome service");
            check(resHead404.path("httpStatus").asInt() == 404, "HEAD 404 status");
            check("true".equals(resHead404.path("headers").path("x-amz-delete-marker").asText()),
                "HEAD 404 x-amz-delete-marker preserved");

            // 4. GetObject 304 Not Modified
            ObjectNode get304 = baseParams(endpoint, "s3Compatible", "GetObject");
            get304.putObject("input").put("Bucket", "test-bucket").put("Key", "not-modified")
                .put("IfNoneMatch", "\"etag-304\"");
            JsonNode res304 = rpcSuccess("s3ConformanceOp", get304);
            check("service".equals(res304.path("outcome").asText()), "304 outcome service");
            check(res304.path("httpStatus").asInt() == 304, "304 status");
            check("\"etag-304\"".equals(res304.path("headers").path("etag").asText()), "304 etag header");

            // 5. GetObject 302 redirect NOT followed
            ObjectNode get302 = baseParams(endpoint, "s3Compatible", "GetObject");
            get302.putObject("input").put("Bucket", "test-bucket").put("Key", "redirect-302");
            JsonNode res302 = rpcSuccess("s3ConformanceOp", get302);
            check("service".equals(res302.path("outcome").asText()), "302 outcome service");
            check(res302.path("httpStatus").asInt() == 302, "302 status");
            check(hitsRedirectTarget.get() == 0, "Redirect must not be followed");
            check(res302.path("headers").path("location").asText().endsWith("/redirect-target"), "302 location header");

            // 6. GetObject 500 -> single attempt (no SDK retry)
            ObjectNode get500 = baseParams(endpoint, "s3Compatible", "GetObject");
            get500.putObject("input").put("Bucket", "test-bucket").put("Key", "error-500");
            JsonNode res500 = rpcSuccess("s3ConformanceOp", get500);
            check("service".equals(res500.path("outcome").asText()), "500 outcome service");
            check(res500.path("httpStatus").asInt() == 500, "500 status");
            check(hits500.get() == 1 && res500.path("attempts").asInt() == 1,
                "Expected exactly 1 attempt on 500, hits=" + hits500.get() + " attempts=" + res500.path("attempts"));

            // 7. ListObjectsV2 projection incl. ContinuationToken / NextContinuationToken surviving SecretHygiene.clean
            ObjectNode listV2 = baseParams(endpoint, "s3Compatible", "ListObjectsV2");
            listV2.putObject("input")
                .put("Bucket", "test-bucket")
                .put("Prefix", "docs/")
                .put("Delimiter", "/")
                .put("ContinuationToken", "cursor-in-1234567890abcdef")
                .put("MaxKeys", 10);
            JsonNode resList = rpcSuccess("s3ConformanceOp", listV2);
            JsonNode listOut = resList.path("output");
            check(listOut.path("IsTruncated").asBoolean(), "ListObjectsV2 IsTruncated");
            check(listOut.path("KeyCount").asInt() == 1, "ListObjectsV2 KeyCount");
            check("cursor-in-1234567890abcdef".equals(listOut.path("ContinuationToken").asText()),
                "ContinuationToken must survive SecretHygiene.clean: " + listOut);
            check("cursor-next-9876543210fedcba".equals(listOut.path("NextContinuationToken").asText()),
                "NextContinuationToken must survive SecretHygiene.clean: " + listOut);
            check("docs/readme.md".equals(listOut.path("Contents").get(0).path("Key").asText()), "Contents[0].Key");
            check(listOut.path("Contents").get(0).path("Size").asLong() == 42L, "Contents[0].Size");
            check("2026-11-22T10:00:00Z".equals(listOut.path("Contents").get(0).path("LastModified").asText()),
                "Contents[0].LastModified ISO-8601 UTC: " + listOut.path("Contents").get(0).path("LastModified"));
            check("docs/sub/".equals(listOut.path("CommonPrefixes").get(0).path("Prefix").asText()),
                "CommonPrefixes[0].Prefix");

            // 8. DeleteObjects projection (Deleted and Errors)
            ObjectNode delParams = baseParams(endpoint, "s3Compatible", "DeleteObjects");
            ObjectNode delInput = delParams.putObject("input").put("Bucket", "test-bucket");
            var objs = delInput.putObject("Delete").putArray("Objects");
            objs.addObject().put("Key", "a.txt").put("VersionId", "v1");
            objs.addObject().put("Key", "b.txt").put("VersionId", "v2");
            JsonNode delRes = rpcSuccess("s3ConformanceOp", delParams);
            JsonNode delOut = delRes.path("output");
            check("a.txt".equals(delOut.path("Deleted").get(0).path("Key").asText()), "Deleted[0].Key");
            check("dm1".equals(delOut.path("Deleted").get(0).path("DeleteMarkerVersionId").asText()),
                "Deleted[0].DeleteMarkerVersionId");
            check("b.txt".equals(delOut.path("Errors").get(0).path("Key").asText()), "Errors[0].Key");
            check("AccessDenied".equals(delOut.path("Errors").get(0).path("Code").asText()), "Errors[0].Code");

            // 9. CopyObject with '+', space, '%', unicode, '/' in key
            ObjectNode copyParams = baseParams(endpoint, "s3Compatible", "CopyObject");
            ObjectNode copyInput = copyParams.putObject("input")
                .put("Bucket", "test-bucket")
                .put("Key", "copied.txt");
            copyInput.putObject("CopySource")
                .put("Bucket", "src-b")
                .put("Key", "dir/a+b c%25 é.txt")
                .put("VersionId", "src-v1");
            JsonNode copyRes = rpcSuccess("s3ConformanceOp", copyParams);
            CapturedRequest copyWire = requests.get(requests.size() - 1);
            String copySourceHeader = copyWire.headers.getOrDefault("x-amz-copy-source", List.of("")).get(0);
            check("src-b/dir/a%2Bb%20c%2525%20%C3%A9.txt?versionId=src-v1".equals(copySourceHeader),
                "CopySource must be encoded once: got " + copySourceHeader);
            check("\"etag-copied\"".equals(copyRes.path("output").path("CopyObjectResult").path("ETag").asText()),
                "CopyObjectResult.ETag");
            check("2026-11-22T11:00:00Z".equals(copyRes.path("output").path("CopyObjectResult").path("LastModified").asText()),
                "CopyObjectResult.LastModified");

            // 10. UploadPartCopy with SSE-C encryption and sourceEncryption (loopback HTTP allowed)
            ObjectNode upcParams = baseParams(endpoint, "s3Compatible", "UploadPartCopy");
            ObjectNode upcInput = upcParams.putObject("input")
                .put("Bucket", "test-bucket")
                .put("Key", "mpu-copy.bin")
                .put("UploadId", "up-1")
                .put("PartNumber", 1)
                .put("CopySourceRange", "bytes=0-10");
            upcInput.putObject("CopySource").put("Bucket", "src-b").put("Key", "a+b c");
            upcParams.putObject("encryption").put("mode", "sse-c").put("customerKey", SSE_KEY);
            upcParams.putObject("sourceEncryption").put("mode", "sse-c").put("customerKey", SRC_SSE_KEY);
            RpcCapture upcCapture = rpcCapture("s3ConformanceOp", upcParams);
            check(upcCapture.response.path("ok").asBoolean(), "UploadPartCopy SSE-C failed: " + upcCapture.response);
            check(!upcCapture.stdout.contains(SSE_KEY) && !upcCapture.stdout.contains(SRC_SSE_KEY)
                && !upcCapture.stderr.contains(SSE_KEY) && !upcCapture.stderr.contains(SRC_SSE_KEY),
                "SSE-C keys leaked into output/stderr");
            CapturedRequest upcWire = requests.get(requests.size() - 1);
            check("AES256".equals(upcWire.headers.getOrDefault("x-amz-server-side-encryption-customer-algorithm", List.of("")).get(0)),
                "Destination SSE-C algorithm header");
            check(SSE_KEY.equals(upcWire.headers.getOrDefault("x-amz-server-side-encryption-customer-key", List.of("")).get(0)),
                "Destination SSE-C key header");
            check(SRC_SSE_KEY.equals(upcWire.headers.getOrDefault("x-amz-copy-source-server-side-encryption-customer-key", List.of("")).get(0)),
                "Source SSE-C key header");

            // 11. Unknown op -> unsupported_feature
            ObjectNode unknownOp = baseParams(endpoint, "s3Compatible", "SelectObjectContent");
            JsonNode unknownRes = rpc("s3ConformanceOp", unknownOp);
            check(!unknownRes.path("ok").asBoolean()
                && "unsupported_feature".equals(unknownRes.path("error").path("code").asText()),
                "Unknown op must return unsupported_feature: " + unknownRes);

            // 12. SSECustomerKey / CopySourceSSECustomerKey inside input -> invalid_request
            for (String forbidden : List.of("SSECustomerKey", "SSECustomerAlgorithm", "CopySourceSSECustomerKey")) {
                ObjectNode badInput = baseParams(endpoint, "s3Compatible", "GetObject");
                badInput.putObject("input").put("Bucket", "test-bucket").put("Key", "k").put(forbidden, SSE_KEY);
                RpcCapture badCap = rpcCapture("s3ConformanceOp", badInput);
                check(!badCap.response.path("ok").asBoolean()
                    && "invalid_request".equals(badCap.response.path("error").path("code").asText()),
                    forbidden + " in input must return invalid_request");
                check(!badCap.stdout.contains(SSE_KEY) && !badCap.stderr.contains(SSE_KEY),
                    "Forbidden SSE-C key in input must not echo back");
            }

            // 13. PresignedRequest GET & PUT & 403 error: no query values or signature leak!
            ObjectNode preGet = baseParams(endpoint, "s3Compatible", "PresignedRequest");
            preGet.putObject("input")
                .put("Method", "GET")
                .put("Bucket", "test-bucket")
                .put("Key", "hello.bin")
                .put("VersionId", "v-put-1")
                .put("ExpiresIn", 60)
                .put("DelayMs", 10);
            RpcCapture preGetCap = rpcCapture("s3ConformanceOp", preGet);
            check(preGetCap.response.path("ok").asBoolean(), "Presigned GET failed: " + preGetCap.response);
            JsonNode preGetRes = preGetCap.response.path("result");
            check("service".equals(preGetRes.path("outcome").asText()), "Presigned GET outcome");
            check(preGetRes.path("httpStatus").asInt() == 200, "Presigned GET status");
            check(sha256Hex(expectedBytes).equals(preGetRes.path("output").path("Body").path("sha256").asText()),
                "Presigned GET body digest");
            JsonNode presignMeta = preGetRes.path("output").path("Presign");
            check("GET".equals(presignMeta.path("Method").asText()), "Presign.Method");
            check("http".equals(presignMeta.path("Scheme").asText()), "Presign.Scheme");
            check(presignMeta.path("Host").asText().startsWith("127.0.0.1:"), "Presign.Host");
            check(presignMeta.path("PresignMs").asDouble() >= 0.0, "Presign.PresignMs");
            List<String> queryKeys = new ArrayList<>();
            presignMeta.path("QueryKeys").forEach(n -> queryKeys.add(n.asText()));
            List<String> sortedKeys = new ArrayList<>(queryKeys);
            Collections.sort(sortedKeys);
            check(queryKeys.equals(sortedKeys), "QueryKeys must be sorted: " + queryKeys);
            check(queryKeys.contains("X-Amz-Signature") && queryKeys.contains("X-Amz-Algorithm")
                && queryKeys.contains("versionId"), "QueryKeys contents: " + queryKeys);
            String sigValue = queryParamValue(lastPresignedQuery.get(), "X-Amz-Signature");
            check(sigValue != null && sigValue.length() >= 16, "Fake server observed real SigV4 signature");
            check(!preGetCap.stdout.contains(sigValue) && !preGetCap.stderr.contains(sigValue),
                "Presigned signature leaked in stdout/stderr");
            check(!preGetCap.stdout.contains("X-Amz-Signature="), "Presigned query string leaked");

            ObjectNode prePut = baseParams(endpoint, "s3Compatible", "PresignedRequest");
            prePut.putObject("input")
                .put("Method", "PUT")
                .put("Bucket", "test-bucket")
                .put("Key", "presigned-put.txt")
                .put("ContentType", "text/plain; charset=utf-8")
                .put("ExpiresIn", 60);
            prePut.putObject("body").put("text", "presigned-hello");
            RpcCapture prePutCap = rpcCapture("s3ConformanceOp", prePut);
            check(prePutCap.response.path("ok").asBoolean()
                && prePutCap.response.path("result").path("httpStatus").asInt() == 200,
                "Presigned PUT failed: " + prePutCap.response);
            check(Arrays.equals(store.get("presigned-put.txt"), "presigned-hello".getBytes(StandardCharsets.UTF_8)),
                "Presigned PUT body mismatch");
            CapturedRequest prePutWire = requests.get(requests.size() - 1);
            check("text/plain; charset=utf-8".equals(prePutWire.headers.getOrDefault("content-type", List.of("")).get(0)),
                "Presigned PUT must send signed Content-Type");
            String putSig = queryParamValue(lastPresignedQuery.get(), "X-Amz-Signature");
            check(putSig != null && !prePutCap.stdout.contains(putSig) && !prePutCap.stderr.contains(putSig),
                "Presigned PUT signature leaked");

            ObjectNode preErr = baseParams(endpoint, "s3Compatible", "PresignedRequest");
            preErr.putObject("input")
                .put("Method", "GET")
                .put("Bucket", "test-bucket")
                .put("Key", "presigned-denied.txt")
                .put("ExpiresIn", 60);
            RpcCapture preErrCap = rpcCapture("s3ConformanceOp", preErr);
            JsonNode preErrRes = preErrCap.response.path("result");
            check("service".equals(preErrRes.path("outcome").asText())
                && preErrRes.path("httpStatus").asInt() == 403
                && "AccessDenied".equals(preErrRes.path("errorCode").asText()),
                "Presigned 403 XML error parsing: " + preErrRes);
        } finally {
            server.stop(0);
        }
    }

    private static void nonServiceOutcomes() throws Exception {
        // 1. sdk_decode: server returns 200 with malformed XML for ListBuckets
        HttpServer badXmlServer = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        badXmlServer.createContext("/", ex -> {
            byte[] garbage = "<ListAllMyBucketsResult><broken".getBytes(StandardCharsets.UTF_8);
            ex.getResponseHeaders().add("Content-Type", "application/xml");
            ex.sendResponseHeaders(200, garbage.length);
            ex.getResponseBody().write(garbage);
            ex.close();
        });
        badXmlServer.start();
        try {
            ObjectNode params = baseParams("http://127.0.0.1:" + badXmlServer.getAddress().getPort(),
                "s3Compatible", "ListBuckets");
            JsonNode res = rpcSuccess("s3ConformanceOp", params);
            check("sdk_decode".equals(res.path("outcome").asText()),
                "Malformed XML must be sdk_decode, got: " + res);
            check(res.path("httpStatus").asInt() == 200, "sdk_decode preserves httpStatus 200: " + res);
        } finally {
            badXmlServer.stop(0);
        }

        // 2. transport: closed localhost port
        int closedPort;
        try (var sock = new java.net.ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1"))) {
            closedPort = sock.getLocalPort();
        }
        ObjectNode unreachable = baseParams("http://127.0.0.1:" + closedPort, "s3Compatible", "HeadBucket");
        unreachable.putObject("input").put("Bucket", "b");
        JsonNode transRes = rpcSuccess("s3ConformanceOp", unreachable);
        check("transport".equals(transRes.path("outcome").asText()),
            "Connection refused must be transport, got: " + transRes);
        check(transRes.path("httpStatus").asInt() == 0, "transport httpStatus 0");

        // 3. Error message sanitization strips query strings and caps length at 256 chars
        String sanitized = S3Conformance.sanitizeErrorMessage(
            "Failed GET https://s3.example.com/b/k?X-Amz-Signature=deadbeef&X-Amz-Credential=ak " + "z".repeat(400),
            "https://s3.example.com/b/k?X-Amz-Signature=deadbeef&X-Amz-Credential=ak");
        check(!sanitized.contains("deadbeef") && sanitized.length() <= 256,
            "Sanitized error message must strip query and cap at 256 chars: " + sanitized);
    }

    private static ObjectNode baseParams(String endpoint, String endpointType, String op) {
        ObjectNode params = JSON.createObjectNode();
        params.putObject("profile")
            .put("endpointType", endpointType)
            .put("endpointUrl", endpoint)
            .put("region", "us-east-1")
            .put("accessKey", "AKIAFIXTURE12345")
            .put("secretKey", "fixtureSecretKeyValue1234567890")
            .put("pathStyle", true)
            .put("connectTimeoutSeconds", 3)
            .put("readTimeoutSeconds", 5)
            .put("maxAttempts", 5);
        params.put("op", op);
        return params;
    }

    private static String queryParamValue(String rawQuery, String key) {
        if (rawQuery == null) return null;
        for (String pair : rawQuery.split("&")) {
            int eq = pair.indexOf('=');
            if (eq > 0 && pair.substring(0, eq).equals(key)) {
                return pair.substring(eq + 1);
            }
        }
        return null;
    }

    private static JsonNode findCapability(JsonNode result, String key) {
        for (JsonNode item : result.path("items")) {
            if (key.equals(item.path("key").asText())) return item;
        }
        return null;
    }

    private static String sidecarCode(Main.SidecarException error) throws Exception {
        var f = Main.SidecarException.class.getDeclaredField("code");
        f.setAccessible(true);
        return String.valueOf(f.get(error));
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> castMap(Object value) {
        return (Map<String, Object>) value;
    }

    private static JsonNode rpc(String method, ObjectNode params) throws Exception {
        return rpcCapture(method, params).response;
    }

    private static JsonNode rpcSuccess(String method, ObjectNode params) throws Exception {
        JsonNode response = rpc(method, params);
        check(response.path("ok").asBoolean(), "RPC failed for " + method + ": " + response.path("error"));
        return response.path("result");
    }

    private static RpcCapture rpcCapture(String method, ObjectNode params) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        ByteArrayOutputStream err = new ByteArrayOutputStream();
        PrintStream origOut = System.out, origErr = System.err;
        try {
            System.setOut(new PrintStream(out, true, StandardCharsets.UTF_8));
            System.setErr(new PrintStream(err, true, StandardCharsets.UTF_8));
            Method process = Main.class.getDeclaredMethod("processRequest", String.class);
            process.setAccessible(true);
            String line = JSON.writeValueAsString(Map.of(
                "requestId", "conformance-test",
                "method", method,
                "params", params
            ));
            process.invoke(null, line);
        } finally {
            System.setOut(origOut);
            System.setErr(origErr);
        }
        String stdout = out.toString(StandardCharsets.UTF_8);
        String stderr = err.toString(StandardCharsets.UTF_8);
        JsonNode response = null;
        for (String line : stdout.lines().toList()) {
            if (line.isBlank()) continue;
            JsonNode parsed = JSON.readTree(line);
            if (parsed.has("ok")) response = parsed;
        }
        check(response != null, "Missing RPC response on stdout");
        return new RpcCapture(response, stdout, stderr);
    }

    private static byte[] decodeAwsChunks(byte[] bytes) {
        var output = new ByteArrayOutputStream();
        int offset = 0;
        while (offset < bytes.length) {
            int end = offset;
            while (end + 1 < bytes.length && !(bytes[end] == '\r' && bytes[end + 1] == '\n')) end++;
            String line = new String(bytes, offset, end - offset, StandardCharsets.US_ASCII);
            int count = Integer.parseInt(line.split(";")[0], 16);
            if (count == 0) return output.toByteArray();
            offset = end + 2;
            output.write(bytes, offset, count);
            offset += count + 2;
        }
        throw new AssertionError("Incomplete aws-chunked request");
    }

    private record CapturedRequest(
        String method,
        String rawPath,
        String rawQuery,
        Map<String, List<String>> headers,
        byte[] body
    ) {}

    private record RpcCapture(JsonNode response, String stdout, String stderr) {}
}
