package com.example.s3browser;

import com.fasterxml.jackson.databind.*;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sun.net.httpserver.HttpServer;
import software.amazon.awssdk.auth.credentials.*;
import software.amazon.awssdk.core.checksums.*;
import software.amazon.awssdk.core.retry.RetryPolicy;
import software.amazon.awssdk.http.*;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.s3.*;
import software.amazon.awssdk.services.s3.model.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

/** The same wire fixture runs over loopback normally, or an SDK HTTP transport in a sandbox. */
final class EncryptionRegressionTest {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String KEY = Base64.getEncoder().encodeToString("0123456789abcdef0123456789abcdef".getBytes(StandardCharsets.UTF_8));
    private static final String SOURCE_KEY = Base64.getEncoder().encodeToString("fedcba9876543210fedcba9876543210".getBytes(StandardCharsets.UTF_8));
    private static final AtomicInteger PORT = new AtomicInteger(19000);
    private static boolean inMemory;

    public static void main(String[] args) throws Exception {
        inMemory = Arrays.asList(args).contains("--in-memory");
        run();
        System.out.println("Encryption regression checks passed" + (inMemory ? " (SDK fixture transport)." : " (loopback HTTP)."));
    }

    static void run() throws Exception {
        ClientEncryptionRegressionTest.run();
        validation();
        secretHygiene();
        capabilitiesAndReportedEncryption();
        for (String mode : new String[]{"absent", "null", "bucketDefault", "sse-s3", "sse-kms", "dsse-kms", "sse-c"}) {
            writesAndReads(mode);
            copies(mode, false);
            copies(mode, true);
        }
        independentCopyKeys();
        failingTransfersRedactKeys();
        errorHintsAndRedaction();
        bucketEncryptionRoundTrip();
        clientEncryptedTransfers();
        clientEncryptedDownloadNames();
        clientEncryptedDownloadNameCollisions();
        ordinaryAgeDownloadKeepsName();
        clientEncryptedUploadBoundariesAndAbort();
        clientEncryptionDefaultOff();
    }

    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
    private static Object invoke(String method, Class<?> type, Object value) throws Exception {
        var call = Main.class.getDeclaredMethod(method, type);
        call.setAccessible(true);
        try { return call.invoke(null, value); }
        catch (java.lang.reflect.InvocationTargetException error) {
            if (error.getCause() instanceof Exception cause) throw cause;
            throw error;
        }
    }

    private static ObjectNode params() {
        var p = JSON.createObjectNode();
        p.putObject("profile").put("endpointType", "awsS3").put("endpointUrl", "https://example.invalid")
            .put("region", "us-east-1").put("accessKey", "fixture").put("secretKey", "fixture")
            .put("pathStyle", true).put("maxAttempts", 2).put("maxConcurrentRequests", 2)
            .putObject("diagnostics").put("enableApiLogging", true).put("enableDebugLogging", true);
        p.put("bucketName", "bucket").put("key", "object");
        return p;
    }
    private static void encryption(ObjectNode p, String field, String mode, String key) {
        if (mode.equals("absent")) { p.remove(field); return; }
        if (mode.equals("null")) { p.putNull(field); return; }
        var e = p.putObject(field).put("mode", mode);
        if (mode.equals("sse-c")) e.put("customerKey", key);
        if (mode.equals("sse-kms") || mode.equals("dsse-kms")) {
            e.put("kmsKeyId", "alias/test").putObject("kmsEncryptionContext").put("tenant", "fixture");
            if (mode.equals("sse-kms")) e.put("bucketKeyEnabled", false);
        }
    }
    private static void invalid(ObjectNode p) {
        try { ObjectEncryption.parse(p, "encryption"); throw new AssertionError("Invalid encryption accepted"); }
        catch (Main.SidecarException error) {
            try {
                var code = error.getClass().getDeclaredField("code"); code.setAccessible(true);
                check(code.get(error).equals("invalid_config"), "Encryption validation code");
            } catch (ReflectiveOperationException e) { throw new AssertionError(e); }
            check(!error.getMessage().contains(KEY), "Key leaked in validation error");
        }
    }
    private static void validation() throws Exception {
        for (String mode : new String[]{"bucketDefault", "sse-s3", "sse-kms", "dsse-kms", "sse-c"}) {
            var p = params(); encryption(p, "encryption", mode, KEY);
            ObjectEncryption.parse(p, "encryption");
            ((ObjectNode)p.path("encryption")).put("unexpected", KEY); invalid(p);
        }
        for (String bad : new String[]{"{}", "[]", "42", "{\"mode\":\"unknown\"}",
                "{\"mode\":\"dsse-kms\",\"bucketKeyEnabled\":true}", "{\"mode\":\"bucketDefault\",\"customerKey\":\"x\"}",
                "{\"mode\":\"sse-kms\",\"kmsKeyId\":12}", "{\"mode\":\"sse-kms\",\"bucketKeyEnabled\":\"false\"}",
                "{\"mode\":\"sse-kms\",\"kmsEncryptionContext\":[]}", "{\"mode\":\"sse-kms\",\"kmsEncryptionContext\":{\"a\":1}}",
                "{\"mode\":\"sse-c\"}", "{\"mode\":\"sse-c\",\"customerKey\":\"%%%\"}",
                "{\"mode\":\"sse-c\",\"customerKey\":\"YWJj\"}", "{\"mode\":\"sse-c\",\"customerKey\":null}",
                "{\"mode\":\"azure-scope\",\"encryptionScope\":\"scope\"}", "{\"mode\":\"azure-cpk\",\"customerKey\":\"x\"}"}) {
            var p = params(); p.set("encryption", JSON.readTree(bad)); invalid(p);
        }
        for (String mode : new String[]{"sse-s3", "sse-kms", "dsse-kms", "sse-c"}) {
            var p = params(); encryption(p, "encryption", mode, KEY);
            ((ObjectNode)p.path("profile")).put("endpointType", "azureBlob"); invalid(p);
        }
        for (String mode : new String[]{"azure-scope", "azure-cpk"}) {
            var p = params(); ((ObjectNode)p.path("profile")).put("endpointType", "azureBlob");
            var option = p.putObject("encryption").put("mode", mode);
            if (mode.equals("azure-cpk")) option.put("customerKey", KEY); else option.put("encryptionScope", "scope");
            check(rpc("generatePresignedUrl", p).path("error").path("code").asText().equals("unsupported_feature"), "Azure encryption remains unsupported");
            if (mode.equals("azure-cpk")) { ((ObjectNode)p.path("profile")).put("endpointUrl", "http://example.invalid"); invalid(p); }
        }
        for (String host : new String[]{"localhost", "127.0.0.1", "127.8.9.10", "[::1]"}) {
            var p = params(); encryption(p, "encryption", "sse-c", KEY);
            ((ObjectNode)p.path("profile")).put("endpointUrl", "http://" + host + ":1234");
            ObjectEncryption.parse(p, "encryption");
        }
        for (int length : new int[]{0, 31, 33}) {
            var p = params(); encryption(p, "encryption", "sse-c", Base64.getEncoder().encodeToString(new byte[length])); invalid(p);
        }
        for (String endpoint : new String[]{"http://example.invalid", "http://127.999.0.1", "http://localhost.evil", "file://localhost/key"}) {
            var p = params(); encryption(p, "encryption", "sse-c", KEY);
            ((ObjectNode)p.path("profile")).put("endpointUrl", endpoint); invalid(p);
        }
        var p = params(); encryption(p, "sourceEncryption", "sse-s3", KEY);
        try { ObjectEncryption.parse(p, "sourceEncryption"); throw new AssertionError("Non-customer source mode accepted"); }
        catch (Main.SidecarException expected) { }
        p = params(); encryption(p, "encryption", "sse-s3", KEY);
        ((ObjectNode)p.path("profile")).put("endpointType", "unknown"); invalid(p);
        p = params(); encryption(p, "encryption", "sse-c", KEY);
        check(rpc("generatePresignedUrl", p).path("error").path("code").asText().equals("unsupported_feature"), "Customer-key presign denied");
    }

    private static void secretHygiene() throws Exception {
        for (String field : new String[]{"fileName", "fileKey", "customerKey", "x-amz-server-side-encryption-customer-key",
                "X-Amz-Copy-Source-Server-Side-Encryption-Customer-Key", "x-ms-encryption-key"}) {
            check(!SecretHygiene.text(field + ": " + KEY).contains(KEY), "Header redaction");
            check(!SecretHygiene.text("{\"" + field + "\":\"" + KEY + "\"}").contains(KEY), "JSON redaction");
        }
        var p = params(); encryption(p, "encryption", "sse-c", KEY);
        p.putObject("clientEncryption").put("fileKey", SOURCE_KEY).put("fileName", "hidden-name-sentinel.pdf");
        try (var secrets = new SecretHygiene(p)) {
            check(!SecretHygiene.text("Provider echoed " + KEY).contains(KEY), "Provider echo redaction");
            check(!JSON.writeValueAsString(SecretHygiene.clean(Map.of("nested", List.of(Map.of("customerKey", KEY))))).contains(KEY), "Retained data redaction");
            check(!JSON.writeValueAsString(SecretHygiene.clean(Map.of("nested", List.of(Map.of("fileKey", SOURCE_KEY))))).contains(SOURCE_KEY), "Retained file key redaction");
            check(!SecretHygiene.text("Provider echoed " + SOURCE_KEY).contains(SOURCE_KEY), "File key provider echo redaction");
            check(!JSON.writeValueAsString(SecretHygiene.clean(Map.of("clientEncryption", Map.of("fileName", "hidden-name-sentinel.pdf")))).contains("hidden-name-sentinel.pdf"), "Hidden name field redaction");
            // The value is an ordinary word and the published path contains it: it is not scrubbed from text.
            check(SecretHygiene.text("Saved to /tmp/hidden-name-sentinel.pdf").contains("hidden-name-sentinel.pdf"), "Published path stays readable");
            var log = new ByteArrayOutputStream(); var original = System.err;
            try { System.setErr(new PrintStream(log, true, StandardCharsets.UTF_8)); Main.emitStructuredLog("DEBUG", "Encryption", "customerKey=" + KEY, "fixture"); }
            finally { System.setErr(original); }
            check(!log.toString(StandardCharsets.UTF_8).contains(KEY), "Structured log redaction");
            @SuppressWarnings("unchecked") var state = (Map<String, Object>) invoke("publicBenchmarkState", Map.class,
                new LinkedHashMap<>(Map.of("config", Map.of("encryption", Map.of("customerKey", KEY)), "profile", Map.of("secretKey", "secret"))));
            check(!JSON.writeValueAsString(state).contains(KEY), "Benchmark checkpoint redaction");
        }
        try (Temp temp = new Temp(); var secrets = new SecretHygiene(p)) {
            String previous = System.getProperty("java.io.tmpdir");
            try {
                System.setProperty("java.io.tmpdir", temp.path.toString());
                var state = new LinkedHashMap<String, Object>();
                state.put("id", "encryption-checkpoint");
                state.put("config", Map.of("encryption", Map.of("customerKey", KEY), "clientEncryption", Map.of("fileKey", SOURCE_KEY),
                    "csvOutputPath", temp.path.resolve("export.csv").toString(),
                    "jsonOutputPath", temp.path.resolve("export.json").toString(),
                    "logFilePath", temp.path.resolve("export.log").toString()));
                state.put("history", List.of(Map.of("second", 1, "key", KEY)));
                state.put("liveLog", List.of("Provider echo " + KEY));
                state.put("resultSummary", Map.of("customerKey", KEY, "message", "Provider echo " + KEY));
                invoke("writeBenchmarkState", Map.class, state);
                invoke("persistBenchmarkOutputs", Map.class, state);
                try (var paths = Files.walk(temp.path)) {
                    for (Path path : paths.filter(Files::isRegularFile).toList())
                        check(!Files.readString(path).contains(KEY) && !Files.readString(path).contains(SOURCE_KEY), "Key persisted in checkpoint or benchmark file");
                }
            } finally { System.setProperty("java.io.tmpdir", previous); }
        }
        check(SecretHygiene.text(KEY).equals(KEY), "Request keys released after scope");
    }

    private static void capabilitiesAndReportedEncryption() throws Exception {
        JsonNode result = rpc("getCapabilities", params()).path("result");
        var items = result.findValues("key");
        for (String mode : new String[]{"sse-s3", "sse-kms", "dsse-kms", "sse-c", "azure-scope", "azure-cpk"}) {
            String wanted = "object.encryption." + mode;
            check(items.stream().anyMatch(v -> v.asText().equals(wanted)), "Encryption capability missing");
            JsonNode item = findItem(result, wanted);
            check(item.path("state").asText().equals(mode.startsWith("azure") ? "unsupported" : "supported"), "Encryption capability state");
            if (mode.startsWith("azure")) check(!item.path("reason").asText().isBlank(), "Azure capability reason");
        }
        check(ObjectEncryption.reported(HeadObjectResponse.builder().build()).isEmpty(), "Absent provider encryption omitted");
        for (String[] pair : new String[][]{{"AES256", "sse-s3"}, {"aws:kms", "sse-kms"}, {"aws:kms:dsse", "dsse-kms"}}) {
            var reported = ObjectEncryption.reported(HeadObjectResponse.builder().serverSideEncryption(pair[0]).ssekmsKeyId("key-id").bucketKeyEnabled(false).build());
            check(reported.get("mode").equals(pair[1]) && reported.get("bucketKeyEnabled").equals(false), "Normalized encryption mode");
        }
        var reported = ObjectEncryption.reported(HeadObjectResponse.builder().sseCustomerAlgorithm("AES256").sseCustomerKeyMD5("fingerprint").build());
        check(reported.equals(Map.of("mode", "sse-c", "customerKeyMd5", "fingerprint")), "Customer key fingerprint only");
    }
    private static JsonNode findItem(JsonNode node, String key) {
        if (node.isObject() && node.path("key").asText().equals(key)) return node;
        for (JsonNode child : node) { var found = findItem(child, key); if (found != null) return found; }
        return null;
    }

    /** Captures every progress event, response and diagnostic for every tested operation. */
    private static JsonNode rpc(String method, ObjectNode params) throws Exception {
        var output = new ByteArrayOutputStream(); var diagnostics = new ByteArrayOutputStream();
        PrintStream stdout = System.out, stderr = System.err;
        try {
            System.setOut(new PrintStream(output, true, StandardCharsets.UTF_8));
            System.setErr(new PrintStream(diagnostics, true, StandardCharsets.UTF_8));
            invoke("processRequest", String.class, JSON.writeValueAsString(Map.of("requestId", "encryption-test", "method", method, "params", params)));
        } finally { System.setOut(stdout); System.setErr(stderr); }
        String captured = output.toString(StandardCharsets.UTF_8), logs = diagnostics.toString(StandardCharsets.UTF_8);
        check(!captured.contains(KEY) && !captured.contains(SOURCE_KEY) && !logs.contains(KEY) && !logs.contains(SOURCE_KEY), "Customer key escaped into captured logs/output");
        String fileKey = params.path("clientEncryption").path("fileKey").asText("");
        if (!fileKey.isEmpty()) check(!captured.contains(fileKey) && !logs.contains(fileKey), "File key escaped into captured logs/output");
        JsonNode response = null;
        for (String line : captured.lines().toList()) {
            JsonNode value = JSON.readTree(line);
            if (value.has("ok")) response = value;
        }
        check(response != null, "Missing RPC response");
        return response;
    }
    private static JsonNode success(String method, ObjectNode params) throws Exception {
        JsonNode response = rpc(method, params);
        check(response.path("ok").asBoolean(), "Fixture operation failed: " + method + ": " + response.path("error"));
        return response.path("result");
    }

    private static Map<String, String> expected(String mode, String key) throws Exception {
        Map<String, String> expected = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
        if (mode.equals("sse-c")) {
            expected.put("x-amz-server-side-encryption-customer-algorithm", "AES256");
            expected.put("x-amz-server-side-encryption-customer-key", key);
            expected.put("x-amz-server-side-encryption-customer-key-md5", Base64.getEncoder().encodeToString(MessageDigest.getInstance("MD5").digest(Base64.getDecoder().decode(key))));
        } else if (Set.of("sse-s3", "sse-kms", "dsse-kms").contains(mode)) {
            expected.put("x-amz-server-side-encryption", mode.equals("sse-s3") ? "AES256" : mode.equals("sse-kms") ? "aws:kms" : "aws:kms:dsse");
            if (!mode.equals("sse-s3")) {
                expected.put("x-amz-server-side-encryption-aws-kms-key-id", "alias/test");
                expected.put("x-amz-server-side-encryption-context", Base64.getEncoder().encodeToString("{\"tenant\":\"fixture\"}".getBytes(StandardCharsets.UTF_8)));
                if (mode.equals("sse-kms")) expected.put("x-amz-server-side-encryption-bucket-key-enabled", "false");
            }
        }
        return expected;
    }
    private static void headers(Request request, Map<String, String> expected) {
        Map<String, String> actual = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
        request.headers.forEach((key, values) -> { if (key.toLowerCase(Locale.ROOT).contains("server-side-encryption")) actual.put(key, String.join(",", values)); });
        check(actual.equals(expected), "Unexpected encryption headers on " + request.method + " " + request.path + " " + request.query + "; header names=" + actual.keySet());
    }
    private static void writesAndReads(String mode) throws Exception {
        try (Fixture fixture = new Fixture(); Temp temp = new Temp()) {
            var p = fixture.params(); encryption(p, "encryption", mode, KEY);
            Path file = temp.path.resolve("upload.bin"); Files.write(file, new byte[128]);
            p.putArray("filePaths").add(file.toString());
            success("startUpload", p); headers(fixture.only("PUT"), expected(mode, KEY));
            fixture.requests.clear();
            try (var sparse = new RandomAccessFile(file.toFile(), "rw")) { sparse.setLength(6L * 1024 * 1024); }
            p.put("multipartThresholdMiB", 1).put("multipartChunkMiB", 5);
            success("startUpload", p);
            int parts = 0;
            for (Request r : fixture.requests) {
                if (r.query.contains("uploads")) headers(r, expected(mode, KEY));
                else if (r.query.contains("partNumber=")) { parts++; headers(r, expected(mode.equals("sse-c") ? mode : "absent", KEY)); }
                else headers(r, expected(mode.equals("sse-c") ? mode : "absent", KEY));
            }
            check(parts == 2, "Every upload part captured");
            fixture.requests.clear(); success("createFolder", p); headers(fixture.only("PUT"), expected(mode, KEY));
            fixture.requests.clear();
            p.putObject("config").put("bucketName", "bucket").put("objectCount", 2).put("versions", 2).put("objectSizeBytes", 10);
            success("runPutTestData", p); check(fixture.requests.size() == 4, "Every generated write captured");
            for (Request r : fixture.requests) headers(r, expected(mode, KEY));
            fixture.requests.clear();
            fixture.reported = mode.equals("sse-c") ? Map.of("x-amz-server-side-encryption-customer-algorithm", "AES256", "x-amz-server-side-encryption-customer-key-MD5", "fingerprint")
                : Set.of("sse-s3", "sse-kms", "dsse-kms").contains(mode) ? Map.of("x-amz-server-side-encryption", mode.equals("sse-s3") ? "AES256" : mode.equals("sse-kms") ? "aws:kms" : "aws:kms:dsse") : Map.of();
            JsonNode details = success("getObjectDetails", p);
            check(details.has("encryption") == !fixture.reported.isEmpty(), "Optional encryption in object details");
            if (!fixture.reported.isEmpty()) check(details.path("encryption").path("mode").asText().equals(mode), "Object details encryption mode");
            for (Request r : fixture.requests) headers(r, expected(r.method.equals("HEAD") && mode.equals("sse-c") ? mode : "absent", KEY));
            fixture.requests.clear(); fixture.size = 2L * 1024 * 1024 + 17; fixture.interruptOnce = true;
            p.putArray("keys").add("download.bin"); p.put("destinationPath", temp.path.toString()).put("multipartChunkMiB", 1);
            success("startDownload", p);
            int gets = 0, heads = 0;
            for (Request r : fixture.requests) {
                headers(r, expected(mode.equals("sse-c") ? mode : "absent", KEY));
                if (r.method.equals("HEAD")) heads++;
                if (r.method.equals("GET")) { gets++; check(r.headers.keySet().stream().anyMatch(k -> k.equalsIgnoreCase("range")), "Range header"); }
            }
            check(heads == 1 && gets == 4, "All ranges and the interrupted-body retry captured");
            check(Files.size(temp.path.resolve("download.bin")) == fixture.size, "Downloaded size");
            fixture.requests.clear(); fixture.interruptOnce = false; fixture.size = 17;
            p.putArray("keys").add("small.bin"); success("startDownload", p);
            for (Request r : fixture.requests) headers(r, expected(mode.equals("sse-c") ? mode : "absent", KEY));
            if (!mode.equals("sse-c")) success("generatePresignedUrl", p);
        }
    }

    private static void copies(String mode, boolean multipart) throws Exception {
        try (Fixture fixture = new Fixture()) {
            fixture.size = multipart ? 5L * 1024 * 1024 * 1024 + 1 : 17;
            var p = fixture.params(); encryption(p, "encryption", mode, KEY);
            p.put("sourceBucketName", "bucket").put("sourceKey", "source").put("destinationBucketName", "bucket").put("destinationKey", "destination");
            // Exercise independent source and destination keys on both paths.
            if (mode.equals("sse-c")) encryption(p, "sourceEncryption", "sse-c", SOURCE_KEY);
            success("copyObject", p);
            verifyCopyHeaders(fixture, mode, multipart);
            fixture.requests.clear(); success("moveObject", p);
            check(fixture.requests.stream().anyMatch(r -> r.method.equals("DELETE")), "Move deletes source after encrypted copy");
            verifyCopyHeaders(fixture, mode, multipart);
            if (multipart) {
                // Absent preserves today's inherited KMS metadata, while an explicit override replaces it.
                fixture.requests.clear(); fixture.reported = Map.of("x-amz-server-side-encryption", "aws:kms", "x-amz-server-side-encryption-aws-kms-key-id", "legacy", "x-amz-server-side-encryption-bucket-key-enabled", "true");
                success("copyObject", p);
                Request create = fixture.requests.stream().filter(r -> r.query.contains("uploads")).findFirst().orElseThrow();
                Map<String, String> expected = expected(mode, KEY);
                if (mode.equals("absent") || mode.equals("null")) expected.putAll(Map.of("x-amz-server-side-encryption", "aws:kms", "x-amz-server-side-encryption-aws-kms-key-id", "legacy", "x-amz-server-side-encryption-bucket-key-enabled", "true"));
                headers(create, expected);
            }
        }
    }
    private static void verifyCopyHeaders(Fixture fixture, String mode, boolean multipart) throws Exception {
        int copies = 0;
        for (Request r : fixture.requests) {
            Map<String, String> want = expected("absent", KEY);
            if (r.method.equals("HEAD") && mode.equals("sse-c")) want.putAll(expected("sse-c", SOURCE_KEY));
            if (r.query.contains("uploads") || r.method.equals("PUT") && !multipart) want.putAll(expected(mode, KEY));
            if (r.query.contains("partNumber=") || !multipart && r.method.equals("PUT")) {
                copies++;
                if (mode.equals("sse-c")) {
                    want.putAll(expected("sse-c", KEY));
                    expected("sse-c", SOURCE_KEY).forEach((key, value) -> want.put(key.replace("x-amz-", "x-amz-copy-source-"), value));
                }
            }
            if (r.query.contains("uploadId=") && r.method.equals("POST") && mode.equals("sse-c")) want.putAll(expected("sse-c", KEY));
            headers(r, want);
        }
        check(copies == (multipart ? 41 : 1), "Every server-side copy part captured");
    }

    private static void independentCopyKeys() throws Exception {
        for (boolean multipart : new boolean[]{false, true}) {
            for (String destination : new String[]{"absent", "sse-kms", "sse-c"}) {
                for (boolean sourceKey : new boolean[]{false, true}) {
                    try (Fixture fixture = new Fixture()) {
                        fixture.size = multipart ? 5L * 1024 * 1024 * 1024 + 1 : 17;
                        var p = fixture.params(); encryption(p, "encryption", destination, KEY);
                        if (sourceKey) encryption(p, "sourceEncryption", "sse-c", SOURCE_KEY);
                        p.put("sourceBucketName", "bucket").put("sourceKey", "source")
                            .put("destinationBucketName", "bucket").put("destinationKey", "destination");
                        success("copyObject", p);
                        for (Request r : fixture.requests) {
                            var want = expected("absent", KEY);
                            if (r.method.equals("HEAD") && sourceKey) want.putAll(expected("sse-c", SOURCE_KEY));
                            boolean copy = r.method.equals("PUT") && (!multipart || r.query.contains("partNumber="));
                            if (r.query.contains("uploads") || copy && !multipart) want.putAll(expected(destination, KEY));
                            if (multipart && (copy || r.method.equals("POST") && r.query.contains("uploadId=")) && destination.equals("sse-c")) want.putAll(expected("sse-c", KEY));
                            if (copy && sourceKey) expected("sse-c", SOURCE_KEY).forEach((k, v) -> want.put(k.replace("x-amz-", "x-amz-copy-source-"), v));
                            headers(r, want);
                        }
                    }
                }
            }
        }
    }

    private static void failingTransfersRedactKeys() throws Exception {
        try (Fixture fixture = new Fixture(); Temp temp = new Temp()) {
            var p = fixture.params(); encryption(p, "encryption", "sse-c", KEY);
            encryption(p, "sourceEncryption", "sse-c", SOURCE_KEY);
            fixture.errorStatus = 403; fixture.errorCode = "AccessDenied";
            fixture.errorMessage = "Provider echoed customer keys " + KEY + " " + SOURCE_KEY;
            Path file = temp.path.resolve("upload.bin"); Files.write(file, new byte[17]);
            p.putArray("filePaths").add(file.toString());
            p.putArray("keys").add("source"); p.put("destinationPath", temp.path.toString());
            p.put("sourceBucketName", "bucket").put("sourceKey", "source")
                .put("destinationBucketName", "bucket").put("destinationKey", "destination");
            for (String method : new String[]{"startUpload", "startDownload", "copyObject"})
                check(!rpc(method, p).path("ok").asBoolean(), "Provider failure reaches encrypted operation");
        }
        var malformed = "{\"encryption\":{\"customerKey\":" + KEY + "}}";
        var output = new ByteArrayOutputStream(); var original = System.out;
        try {
            System.setOut(new PrintStream(output, true, StandardCharsets.UTF_8));
            invoke("processRequest", String.class, malformed);
        } finally { System.setOut(original); }
        check(!output.toString(StandardCharsets.UTF_8).contains(KEY), "Malformed JSON cannot echo customer key");
    }

    private static void errorHintsAndRedaction() throws Exception {
        try (Fixture fixture = new Fixture()) {
            var p = fixture.params();
            fixture.errorCode = "BadRequest"; fixture.errorMessage = ""; fixture.errorStatus = 400;
            var headError = rpc("getObjectDetails", p);
            check(headError.path("error").path("details").path("encryptionHint").asText().equals("sse_c_key_required"), "Bare HEAD customer-key hint: " + headError);
            fixture.errorCode = "AccessDenied"; fixture.errorStatus = 403;
            fixture.errorMessage = "Not authorized to perform kms:GenerateDataKey " + KEY;
            encryption(p, "encryption", "sse-c", KEY);
            JsonNode error = rpc("createFolder", p).path("error");
            check(error.path("code").asText().equals("auth_failed"), "Existing error code preserved");
            check(error.path("details").path("encryptionHint").asText().equals("kms_access_denied"), "KMS access hint");
            fixture.errorMessage = "Access Denied";
            check(!rpc("createFolder", p).path("error").path("details").has("encryptionHint"), "No speculative SSE-C blocked hint");
            fixture.errorMessage = "SSE-C is blocked by this bucket " + KEY;
            check(rpc("createFolder", p).path("error").path("details").path("encryptionHint").asText().equals("sse_c_blocked"), "Explicit SSE-C blocked hint");
            for (Request request : fixture.requests) if (request.method.equals("PUT")) headers(request, expected("sse-c", KEY));
        }
        var unrelated = (S3Exception) S3Exception.builder().statusCode(400).awsErrorDetails(software.amazon.awssdk.awscore.exception.AwsErrorDetails.builder().errorCode("InvalidRequest").errorMessage("Invalid range").build()).build();
        check(EncryptionErrors.hint(unrelated, true, false) == null, "Unrelated read error has no encryption hint");
        for (String[] pair : new String[][]{{"KMS.DisabledException", "", "kms_key_unavailable"}, {"InvalidRequest", "Customer key does not match", "sse_c_key_mismatch"},
                {"AccessDenied", "Encryption required by policy", "encryption_required_by_policy"}, {"NotImplemented", "Encryption not supported", "unsupported_by_endpoint"}}) {
            var error = (S3Exception) S3Exception.builder().statusCode(400).awsErrorDetails(software.amazon.awssdk.awscore.exception.AwsErrorDetails.builder().errorCode(pair[0]).errorMessage(pair[1]).build()).build();
            check(pair[2].equals(EncryptionErrors.hint(error, false, true)), "Provider error hint mapping");
        }
    }

    private static void bucketEncryptionRoundTrip() throws Exception {
        String raw = "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"arn:key\"},\"BucketKeyEnabled\":false,\"BlockedEncryptionTypes\":{\"EncryptionType\":[\"SSE-C\",\"FUTURE\"]}},{\"BlockedEncryptionTypes\":{\"EncryptionType\":[\"NONE\"]}}]}";
        var parsed = (ServerSideEncryptionConfiguration) invoke("parseEncryptionConfiguration", JsonNode.class, JSON.readTree(raw));
        JsonNode output = JSON.valueToTree(invoke("encryptionRaw", ServerSideEncryptionConfiguration.class, parsed));
        var reparsed = (ServerSideEncryptionConfiguration) invoke("parseEncryptionConfiguration", JsonNode.class, output);
        check(parsed.equals(reparsed), "Every modeled encryption rule field round-trips");
        check(reparsed.rules().getFirst().blockedEncryptionTypes().encryptionTypeAsStrings().equals(List.of("SSE-C", "FUTURE")), "Unknown blocked encryption enum retained");
        var future = (ServerSideEncryptionConfiguration) invoke("parseEncryptionConfiguration", JsonNode.class,
            JSON.readTree("{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"FUTURE\"}}]}"));
        check(future.rules().getFirst().applyServerSideEncryptionByDefault().sseAlgorithmAsString().equals("FUTURE"), "Unknown default algorithm retained");
        try (Fixture fixture = new Fixture()) {
            fixture.bucketEncryption = true;
            JsonNode state = success("getBucketAdminState", fixture.params());
            JsonNode encryption = JSON.readTree(state.path("encryptionJson").asText());
            check(encryption.path("Rules").get(0).path("BlockedEncryptionTypes").path("EncryptionType").get(0).asText().equals("SSE-C"), "Admin state preserves SSE-C block");
            var p = fixture.params(); p.put("encryptionJson", state.path("encryptionJson").asText());
            success("putBucketEncryption", p);
            check(fixture.bucketPut.contains("<BlockedEncryptionTypes><EncryptionType>SSE-C</EncryptionType></BlockedEncryptionTypes>"), "Bucket write preserves SSE-C block XML");
            check(fixture.bucketPut.contains("<BucketKeyEnabled>false</BucketKeyEnabled>") && fixture.bucketPut.contains("<KMSMasterKeyID>arn:key</KMSMasterKeyID>"), "Bucket write preserves other rule fields");
        }
    }

    private static void clientEncryptedTransfers() throws Exception {
        var vectors = ClientEncryptionRegressionTest.vectors();
        for (int index = 0; index < vectors.size(); index++) {
            JsonNode vector = vectors.get(index);
            // Every vector uses PUT; the 11 MiB vector also crosses two 5 MiB part boundaries.
            for (boolean multipart : index == vectors.size() - 1 ? new boolean[]{false, true} : new boolean[]{false}) {
                try (Fixture fixture = new Fixture(); Temp temp = new Temp()) {
                    fixture.storage = true; fixture.retryFirstPart = multipart;
                    Path source = temp.path.resolve("source.bin");
                    byte[] plaintext = ClientEncryptionRegressionTest.plaintext(vector); Files.write(source, plaintext);
                    byte[] expected = ClientEncryptionRegressionTest.object(vector, source);
                    var p = fixture.params(); p.set("clientEncryption", ClientEncryptionRegressionTest.option(vector, true).path("clientEncryption"));
                    p.putArray("filePaths").add(source.toString());
                    p.putObject("objectKeyByPath").put(source.toString(), "payload.age");
                    p.put("multipartThresholdMiB", multipart ? 1 : 32).put("multipartChunkMiB", 5);
                    encryption(p, "encryption", "sse-c", KEY); // Provider encryption composes with the payload cipher.
                    JsonNode upload = success("startUpload", p);
                    check(Arrays.equals(fixture.stored, expected), "Fixture ciphertext matches complete vector bytes: case " + index
                        + ", received " + fixture.stored.length + ", expected " + expected.length);
                    check(ClientEncryptionRegressionTest.sha(fixture.stored).equals(vector.path("objectSha256").asText()), "Fixture vector SHA-256");
                    check(upload.path("bytesTransferred").asLong() == expected.length, "Upload progress counts ciphertext bytes");
                    for (Request request : fixture.requests) {
                        if (request.method.equals("PUT")) {
                            String length = header(request, "x-amz-decoded-content-length");
                            if (length.isEmpty()) length = header(request, "content-length");
                            check(length.equals(String.valueOf(request.body.length)), "Provider ciphertext content length");
                            headers(request, expected("sse-c", KEY));
                        }
                    }
                    if (multipart) {
                        check(fixture.partOneAttempts.get() == 2, "Ciphertext part retried");
                        check(fixture.partOrder.getFirst() == 2, "Parts delivered out of order");
                        check(fixture.partBodies.size() == 3, "Ciphertext multipart count");
                        check(fixture.partBodies.get(1).length == 5 * 1024 * 1024 && fixture.partBodies.get(2).length == 5 * 1024 * 1024,
                            "Uniform provider ciphertext parts");
                        check(Arrays.equals(fixture.firstPartAttempt, fixture.partBodies.get(1)), "Retry ciphertext identical");
                    }
                    Path destination = Files.createDirectory(temp.path.resolve("download"));
                    p.set("clientEncryption", ClientEncryptionRegressionTest.option(vector, false).path("clientEncryption"));
                    p.putArray("keys").add("payload.age"); p.put("destinationPath", destination.toString());
                    p.put("versionId", "fixture-version"); fixture.interruptOnce = true;
                    fixture.interruptRange = vector.path("headerLength").asLong() + 16;
                    int requestsBefore = fixture.requests.size();
                    success("startDownload", p);
                    check(Arrays.equals(Files.readAllBytes(destination.resolve("payload")), plaintext), "Engine decrypted plaintext");
                    long firstChunk = vector.path("headerLength").asLong() + 16;
                    check(fixture.requests.subList(requestsBefore, fixture.requests.size()).stream()
                        .filter(r -> r.method.equals("GET") && header(r, "range").startsWith("bytes=" + firstChunk + "-")).count() == 2,
                        "Interrupted chunk body retried");
                    for (Request request : fixture.requests.subList(requestsBefore, fixture.requests.size())) {
                        if (!request.method.equals("GET")) continue;
                        check(header(request, "if-match").equals("\"fixture-etag\""), "Ciphertext GET bound to HEAD");
                        check(request.query.contains("versionId=fixture-version"), "Ciphertext GET bound to version");
                        String range = header(request, "range");
                        long start = Long.parseLong(range.substring(6).split("-")[0]);
                        int prefix = vector.path("headerLength").asInt() + 16;
                        check(start == vector.path("headerLength").asInt() || (start - prefix) % ClientEncryption.SEALED == 0,
                            "Nonce/chunk aligned ciphertext ranges");
                    }
                    // Atomic conflict policies still apply to the authenticated plaintext.
                    p.put("conflictPolicy", "keepBoth"); success("startDownload", p);
                    check(Arrays.equals(Files.readAllBytes(destination.resolve("payload (1)")), plaintext), "Encrypted keepBoth");
                    p.put("conflictPolicy", "replace"); success("startDownload", p);
                    check(Arrays.equals(Files.readAllBytes(destination.resolve("payload")), plaintext), "Encrypted replace");
                    long corruptChunk = plaintext.length > ClientEncryption.CHUNK ? 1 : 0;
                    int corruptOffset = vector.path("headerLength").asInt() + 16 + (int) corruptChunk * ClientEncryption.SEALED;
                    fixture.stored[corruptOffset] ^= 1;
                    Path failed = Files.createDirectory(temp.path.resolve("failed")); p.put("destinationPath", failed.toString());
                    JsonNode error = rpc("startDownload", p).path("error");
                    check(error.path("code").asText().equals("decryption_failed") && error.path("details").path("chunk").asLong(-1) == corruptChunk,
                        "Authentication failure exposes code and chunk");
                    try (var files = Files.list(failed)) { check(files.findAny().isEmpty(), "Failed plaintext and stage removed"); }
                    // A failed replace must preserve an existing destination.
                    p.put("destinationPath", destination.toString());
                    check(!rpc("startDownload", p).path("ok").asBoolean(), "Corrupt replacement fails");
                    check(Arrays.equals(Files.readAllBytes(destination.resolve("payload")), plaintext), "Existing plaintext preserved after authentication failure");
                    // Impossible HEAD lengths fail without fetching/publishing any payload.
                    fixture.stored = new byte[vector.path("headerLength").asInt() + 16 + ClientEncryption.SEALED + 1];
                    p.put("destinationPath", failed.toString());
                    check(rpc("startDownload", p).path("error").path("code").asText().equals("decryption_failed"), "Impossible HEAD length error");
                    try (var files = Files.list(failed)) { check(files.findAny().isEmpty(), "Impossible length leaves no files"); }
                }
            }
        }
        // File-key values echoed by provider failures must not escape either output stream.
        try (Fixture fixture = new Fixture(); Temp temp = new Temp()) {
            var vector = vectors.get(0); var p = fixture.params();
            p.set("clientEncryption", ClientEncryptionRegressionTest.option(vector, true).path("clientEncryption"));
            Path source = temp.path.resolve("source"); Files.write(source, new byte[0]); p.putArray("filePaths").add(source.toString());
            fixture.errorStatus = 403; fixture.errorCode = "AccessDenied"; fixture.errorMessage = "echo " + vector.path("fileKey").asText();
            check(!rpc("startUpload", p).path("ok").asBoolean(), "Provider file-key echo redacted");
            p.putArray("filePaths").add(source.toString()).add(source.toString());
            check(rpc("startUpload", p).path("error").path("code").asText().equals("invalid_config"), "Multi-file encryption rejected");
            p.set("clientEncryption", ClientEncryptionRegressionTest.option(vector, false).path("clientEncryption"));
            p.putArray("keys").add("one").add("two"); p.put("destinationPath", temp.path.toString());
            check(rpc("startDownload", p).path("error").path("code").asText().equals("invalid_config"), "Multi-key encryption rejected");
        }
        JsonNode item = findItem(rpc("getCapabilities", params()).path("result"), "object.clientEncryption");
        check(item != null && item.path("state").asText().equals("supported") && item.path("formats").equals(JSON.readTree("[\"age-v1\"]")), "Client encryption capability shape");
    }

    private static void clientEncryptedDownloadNames() throws Exception {
        JsonNode vector = ClientEncryptionRegressionTest.vectors().get(1);
        for (String[] names : new String[][] {{"report.pdf.age", "report.pdf"}, {".age", ".age"},
                {"notes", "notes"}, {"a.age.age", "a.age"}, {"...age", "download"}, {"CON.age", "_CON"},
                {"token.age", "hidden-report.pdf", "hidden-report.pdf"}, {"token.age", "_CON", "CON"}}) {
            try (Fixture fixture = new Fixture(); Temp temp = new Temp()) {
                fixture.storage = true;
                Path source = temp.path.resolve("source");
                byte[] plaintext = ClientEncryptionRegressionTest.plaintext(vector); Files.write(source, plaintext);
                fixture.stored = ClientEncryptionRegressionTest.object(vector, source);
                Path destination = Files.createDirectory(temp.path.resolve("download"));
                var p = fixture.params();
                p.set("clientEncryption", ClientEncryptionRegressionTest.option(vector, false).path("clientEncryption"));
                if (names.length == 3) ((ObjectNode) p.path("clientEncryption")).put("fileName", names[2]);
                p.putArray("keys").add("folder/" + names[0]); p.put("destinationPath", destination.toString());
                JsonNode result = success("startDownload", p);
                Path target = destination.resolve(names[1]);
                check(Arrays.equals(Files.readAllBytes(target), plaintext), "Published plaintext name: " + names[0]);
                try (var files = Files.list(destination)) { check(files.count() == 1, "Only plaintext name published"); }
                if (names.length == 3) {
                    success("startDownload", p);
                    String stem = names[1].contains(".") ? names[1].substring(0, names[1].lastIndexOf('.')) : names[1];
                    String ext = names[1].contains(".") ? names[1].substring(names[1].lastIndexOf('.')) : "";
                    check(Arrays.equals(Files.readAllBytes(destination.resolve(stem + " (1)" + ext)), plaintext), "Supplied-name collision");
                    p.put("conflictPolicy", "replace"); success("startDownload", p);
                    check(Arrays.equals(Files.readAllBytes(target), plaintext), "Supplied-name replacement");
                    continue;
                }
                check(result.path("outputLines").toString().contains("to " + target + "."), "Saved line reports published path");
                check(result.path("outputLines").toString().contains("Finished downloading " + names[1] + "."), "Finished line reports published name");
            }
        }
    }

    private static void clientEncryptedDownloadNameCollisions() throws Exception {
        JsonNode vector = ClientEncryptionRegressionTest.vectors().get(1);
        try (Fixture fixture = new Fixture(); Temp temp = new Temp()) {
            fixture.storage = true;
            Path source = temp.path.resolve("source");
            byte[] plaintext = ClientEncryptionRegressionTest.plaintext(vector); Files.write(source, plaintext);
            fixture.stored = ClientEncryptionRegressionTest.object(vector, source);
            Path destination = Files.createDirectory(temp.path.resolve("download"));
            Files.writeString(destination.resolve("report.pdf"), "existing");
            var p = fixture.params();
            p.set("clientEncryption", ClientEncryptionRegressionTest.option(vector, false).path("clientEncryption"));
            p.putArray("keys").add("folder/report.pdf.age");
            p.put("destinationPath", destination.toString()).put("conflictPolicy", "keepBoth");
            JsonNode result = success("startDownload", p);
            check(Files.readString(destination.resolve("report.pdf")).equals("existing"), "Stripped-name collision preserves existing file");
            check(Arrays.equals(Files.readAllBytes(destination.resolve("report (1).pdf")), plaintext), "Unique name uses plaintext extension");
            check(result.path("outputLines").toString().contains("Finished downloading report (1).pdf."), "Finished line reports collision name");
            p.put("conflictPolicy", "replace"); success("startDownload", p);
            check(Arrays.equals(Files.readAllBytes(destination.resolve("report.pdf")), plaintext), "Replace targets stripped name");
            check(!Files.exists(destination.resolve("report.pdf.age")), "Ciphertext name never published");
        }
    }

    private static void ordinaryAgeDownloadKeepsName() throws Exception {
        try (Fixture fixture = new Fixture(); Temp temp = new Temp()) {
            fixture.storage = true; fixture.stored = new byte[]{1, 2, 3};
            var p = fixture.params(); p.putArray("keys").add("folder/report.pdf.age");
            p.put("destinationPath", temp.path.toString()); success("startDownload", p);
            check(Arrays.equals(Files.readAllBytes(temp.path.resolve("report.pdf.age")), fixture.stored), "Ordinary .age download keeps name and bytes");
            check(!Files.exists(temp.path.resolve("report.pdf")), "Ordinary download does not strip suffix");
        }
    }

    private static String header(Request request, String name) {
        return request.headers.entrySet().stream().filter(e -> e.getKey().equalsIgnoreCase(name))
            .map(e -> e.getValue().getFirst()).findFirst().orElse("");
    }

    private static void clientEncryptedUploadBoundariesAndAbort() throws Exception {
        JsonNode vector = ClientEncryptionRegressionTest.vectors().get(7);
        try (Fixture fixture = new Fixture(); Temp temp = new Temp()) {
            fixture.storage = true;
            Path source = temp.path.resolve("source.bin");
            // Ciphertext crosses the threshold even though plaintext is below it.
            Files.write(source, new byte[1024 * 1024 - 200]);
            var p = fixture.params(); p.set("clientEncryption", ClientEncryptionRegressionTest.option(vector, true).path("clientEncryption"));
            p.putArray("filePaths").add(source.toString()); p.put("multipartThresholdMiB", 1).put("multipartChunkMiB", 5);
            success("startUpload", p);
            check(fixture.requests.stream().anyMatch(r -> r.query.contains("uploads")), "Ciphertext threshold chooses multipart");
            check(fixture.partBodies.size() == 1 && fixture.stored.length > 1024 * 1024, "Ciphertext part count below minimum part size");
        }
        for (boolean mutate : new boolean[]{false, true}) {
            try (Fixture fixture = new Fixture(); Temp temp = new Temp()) {
                fixture.storage = true;
                Path source = temp.path.resolve("source.bin"); Files.write(source, ClientEncryptionRegressionTest.plaintext(vector));
                fixture.mutateSource = mutate ? source : null; fixture.rejectPart = !mutate;
                var p = fixture.params(); p.set("clientEncryption", ClientEncryptionRegressionTest.option(vector, true).path("clientEncryption"));
                p.putArray("filePaths").add(source.toString()); p.put("multipartThresholdMiB", 1).put("multipartChunkMiB", 5);
                check(!rpc("startUpload", p).path("ok").asBoolean(), "Encrypted upload failure surfaced");
                check(fixture.requests.stream().anyMatch(r -> r.method.equals("DELETE") && r.query.contains("uploadId=")), "Failed encrypted multipart aborted");
                check(fixture.requests.stream().noneMatch(r -> r.method.equals("POST") && r.query.contains("uploadId=")), "Failed encrypted multipart never completed");
                check(fixture.stored.length == 0, "Failed encrypted upload not committed");
            }
        }
        try (Fixture fixture = new Fixture(); Temp temp = new Temp()) {
            fixture.storage = true;
            Path source = temp.path.resolve("source.bin"); Files.write(source, ClientEncryptionRegressionTest.plaintext(vector));
            fixture.stored = ClientEncryptionRegressionTest.object(vector, source);
            Path destination = Files.createDirectory(temp.path.resolve("download"));
            var p = fixture.params(); p.set("clientEncryption", ClientEncryptionRegressionTest.option(vector, false).path("clientEncryption"));
            p.putArray("keys").add("payload.age"); p.put("destinationPath", destination.toString());
            for (boolean badEtag : new boolean[]{false, true}) {
                fixture.badEtag = badEtag; fixture.badRange = !badEtag;
                check(!rpc("startDownload", p).path("ok").asBoolean(), "Ciphertext validators rejected");
                try (var files = Files.list(destination)) { check(files.findAny().isEmpty(), "Validator mismatch leaves no stage or plaintext"); }
            }
        }
    }

    private static void clientEncryptionDefaultOff() throws Exception {
        for (boolean multipart : new boolean[]{false, true}) {
            try (Fixture fixture = new Fixture(); Temp temp = new Temp()) {
                fixture.storage = true;
                Path source = temp.path.resolve("plain"); byte[] plain = ClientEncryptionRegressionTest.plaintext(ClientEncryptionRegressionTest.vectors().get(multipart ? 7 : 4));
                Files.write(source, plain); var p = fixture.params(); p.putArray("filePaths").add(source.toString());
                p.put("multipartThresholdMiB", multipart ? 1 : 32).put("multipartChunkMiB", 5);
                success("startUpload", p); List<Request> absent = List.copyOf(fixture.requests); fixture.requests.clear();
                check(Arrays.equals(fixture.stored, plain), "Default upload bytes unchanged");
                p.putNull("clientEncryption"); success("startUpload", p);
                List<Request> explicitNull = List.copyOf(fixture.requests); fixture.requests.clear();
                sameRequests(absent, explicitNull);
                Path destination = Files.createDirectory(temp.path.resolve("download"));
                p.putArray("keys").add("plain"); p.put("destinationPath", destination.toString()).put("conflictPolicy", "replace");
                p.remove("clientEncryption"); success("startDownload", p); absent = List.copyOf(fixture.requests); fixture.requests.clear();
                check(Arrays.equals(Files.readAllBytes(destination.resolve("plain")), plain), "Default published bytes unchanged");
                p.putNull("clientEncryption"); success("startDownload", p); sameRequests(absent, fixture.requests);
                check(Arrays.equals(Files.readAllBytes(destination.resolve("plain")), plain), "Null published bytes unchanged");
            }
        }
    }

    private static void sameRequests(List<Request> before, List<Request> after) {
        // Parallel ranged GETs share method, path and query, so order by range too.
        Comparator<Request> order = Comparator.comparing(Request::method).thenComparing(Request::path).thenComparing(Request::query)
            .thenComparing(request -> request.headers.entrySet().stream()
                .filter(entry -> entry.getKey().equalsIgnoreCase("range")).map(entry -> String.valueOf(entry.getValue())).findFirst().orElse(""));
        before = before.stream().sorted(order).toList(); after = after.stream().sorted(order).toList();
        check(before.size() == after.size(), "Default request count unchanged");
        for (int i = 0; i < before.size(); i++) {
            Request a = before.get(i), b = after.get(i);
            check(a.method.equals(b.method) && a.path.equals(b.path) && a.query.equals(b.query) && Arrays.equals(a.body, b.body), "Default requests unchanged");
            var left = new TreeMap<>(String.CASE_INSENSITIVE_ORDER); left.putAll(a.headers);
            var right = new TreeMap<>(String.CASE_INSENSITIVE_ORDER); right.putAll(b.headers);
            for (String name : new String[]{"authorization", "x-amz-date", "amz-sdk-invocation-id", "amz-sdk-request"}) { left.remove(name); right.remove(name); }
            if (!left.equals(right)) {
                var differing = new TreeSet<String>(String.CASE_INSENSITIVE_ORDER);
                for (String name : left.keySet()) if (!Objects.equals(left.get(name), right.get(name))) differing.add(name);
                for (String name : right.keySet()) if (!left.containsKey(name)) differing.add(name);
                throw new AssertionError("Default request headers unchanged; differing headers: " + differing);
            }
        }
    }

    private record Request(String method, String path, String query, Map<String, List<String>> headers, byte[] body) { }
    private record Reply(int status, Map<String, String> headers, byte[] body, long length) { }
    private static final class Temp implements AutoCloseable {
        final Path path = Files.createTempDirectory("odb-encryption-test-");
        Temp() throws IOException { }
        @Override public void close() throws IOException { try (var paths = Files.walk(path)) { for (Path file : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(file); } }
    }
    private static final class Fixture implements AutoCloseable {
        final List<Request> requests = Collections.synchronizedList(new ArrayList<>());
        final HttpServer server;
        final String endpoint;
        Object cachedProfile;
        S3Client cachedClient;
        long size = 17;
        Map<String, String> reported = Map.of();
        boolean interruptOnce, bucketEncryption;
        boolean storage, retryFirstPart, rejectPart, badEtag, badRange;
        Path mutateSource;
        long interruptRange = -1;
        volatile byte[] stored = new byte[0], firstPartAttempt;
        final Map<Integer, byte[]> partBodies = new java.util.concurrent.ConcurrentHashMap<>();
        final List<Integer> partOrder = Collections.synchronizedList(new ArrayList<>());
        final AtomicInteger partOneAttempts = new AtomicInteger();
        final java.util.concurrent.CountDownLatch secondPart = new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.ExecutorService httpWorkers = java.util.concurrent.Executors.newFixedThreadPool(4);
        String errorCode, errorMessage = "", bucketPut = "";
        int errorStatus;
        Fixture() throws Exception {
            if (inMemory) {
                server = null; endpoint = "http://127.0.0.1:" + PORT.incrementAndGet();
                cachedClient = S3Client.builder().endpointOverride(URI.create(endpoint)).region(Region.US_EAST_1)
                    .credentialsProvider(StaticCredentialsProvider.create(AwsBasicCredentials.create("fixture", "fixture")))
                    .serviceConfiguration(S3Configuration.builder().pathStyleAccessEnabled(true).build())
                    .requestChecksumCalculation(RequestChecksumCalculation.WHEN_REQUIRED).responseChecksumValidation(ResponseChecksumValidation.WHEN_REQUIRED)
                    .overrideConfiguration(c -> c.addExecutionInterceptor(new EncryptionErrors()).retryPolicy(RetryPolicy.builder().numRetries(1).build()))
                    .httpClient(new SdkHttpClient() {
                        @Override public void close() { }
                        @Override public ExecutableHttpRequest prepareRequest(HttpExecuteRequest request) {
                            return new ExecutableHttpRequest() {
                                @Override public void abort() { }
                                @Override public HttpExecuteResponse call() throws IOException {
                                    byte[] body = new byte[0];
                                    if (request.contentStreamProvider().isPresent()) {
                                        try (var stream = request.contentStreamProvider().get().newStream()) { body = stream.readAllBytes(); }
                                    }
                                    var http = request.httpRequest();
                                    Reply reply = respond(http.method().name(), http.getUri(), http.headers(), body);
                                    var response = SdkHttpResponse.builder().statusCode(reply.status);
                                    reply.headers.forEach((key, value) -> response.putHeader(key, value));
                                    return HttpExecuteResponse.builder().response(response.build()).responseBody(AbortableInputStream.create(new ByteArrayInputStream(reply.body))).build();
                                }
                            };
                        }
                    }).build();
                cachedProfile = invoke("parseProfile", JsonNode.class, params().path("profile"));
                clients().put(cachedProfile, cachedClient);
            } else {
                server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
                server.setExecutor(httpWorkers);
                endpoint = "http://127.0.0.1:" + server.getAddress().getPort();
                server.createContext("/", exchange -> {
                    Reply reply = respond(exchange.getRequestMethod(), exchange.getRequestURI(), exchange.getRequestHeaders(), exchange.getRequestBody().readAllBytes());
                    reply.headers.forEach((key, value) -> exchange.getResponseHeaders().add(key, value));
                    exchange.sendResponseHeaders(reply.status, exchange.getRequestMethod().equals("HEAD") || reply.status == 204 ? -1 : reply.length);
                    try { if (!exchange.getRequestMethod().equals("HEAD") && reply.status != 204) exchange.getResponseBody().write(reply.body); }
                    finally { try { exchange.close(); } catch (Exception ignored) { } }
                });
                server.start();
            }
        }
        ObjectNode params() {
            var p = EncryptionRegressionTest.params(); ((ObjectNode)p.path("profile")).put("endpointUrl", endpoint); return p;
        }
        Request only(String method) {
            var matches = requests.stream().filter(r -> r.method.equals(method)).toList();
            check(matches.size() == 1, "Expected exactly one " + method); return matches.getFirst();
        }
        Reply respond(String method, URI uri, Map<String, List<String>> headers, byte[] body) {
            String query = Objects.toString(uri.getRawQuery(), "");
            // S3 removes SigV4 streaming frames before storing the object.
            if (headers.entrySet().stream().anyMatch(e -> e.getKey().equalsIgnoreCase("content-encoding")
                    && e.getValue().stream().anyMatch(v -> v.contains("aws-chunked")))) body = decodeAwsChunks(body);
            requests.add(new Request(method, uri.getPath(), query, new LinkedHashMap<>(headers), body));
            Map<String, String> out = new LinkedHashMap<>(); out.put("ETag", "\"fixture-etag\"");
            if (errorCode != null) {
                byte[] error = ("<Error><Code>" + errorCode + "</Code><Message>" + errorMessage + "</Message></Error>").getBytes(StandardCharsets.UTF_8);
                return new Reply(errorStatus, out, error, error.length);
            }
            String xml = "";
            if (storage && method.equals("PUT")) {
                if (query.contains("partNumber=")) {
                    int part = Integer.parseInt(query.split("partNumber=")[1].split("&")[0]);
                    if (rejectPart) {
                        byte[] denied = "<Error><Code>AccessDenied</Code></Error>".getBytes(StandardCharsets.UTF_8);
                        return new Reply(403, out, denied, denied.length);
                    }
                    synchronized (this) {
                        if (mutateSource != null) {
                            try { Files.write(mutateSource, new byte[]{99}); }
                            catch (IOException error) { throw new UncheckedIOException(error); }
                            mutateSource = null;
                            byte[] retry = "<Error><Code>SlowDown</Code></Error>".getBytes(StandardCharsets.UTF_8);
                            return new Reply(503, out, retry, retry.length);
                        }
                    }
                    if (part == 1 && retryFirstPart && partOneAttempts.incrementAndGet() == 1) {
                        firstPartAttempt = body.clone();
                        try { check(secondPart.await(10, java.util.concurrent.TimeUnit.SECONDS), "Part two reaches fixture before retry"); }
                        catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new AssertionError(error); }
                        byte[] retry = "<Error><Code>SlowDown</Code></Error>".getBytes(StandardCharsets.UTF_8);
                        return new Reply(503, out, retry, retry.length);
                    }
                    partBodies.put(part, body); partOrder.add(part); if (part == 2) secondPart.countDown();
                } else stored = body;
            }
            if (storage && method.equals("POST") && query.contains("uploadId=")) {
                var joined = new ByteArrayOutputStream();
                partBodies.entrySet().stream().sorted(Map.Entry.comparingByKey()).forEach(entry -> joined.writeBytes(entry.getValue()));
                stored = joined.toByteArray();
            }
            if (storage) size = stored.length;
            if (bucketEncryption) {
                if (query.contains("encryption")) {
                    if (method.equals("PUT")) bucketPut = new String(body, StandardCharsets.UTF_8);
                    else xml = "<ServerSideEncryptionConfiguration><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>aws:kms</SSEAlgorithm><KMSMasterKeyID>arn:key</KMSMasterKeyID></ApplyServerSideEncryptionByDefault><BucketKeyEnabled>false</BucketKeyEnabled><BlockedEncryptionTypes><EncryptionType>SSE-C</EncryptionType></BlockedEncryptionTypes></Rule></ServerSideEncryptionConfiguration>";
                } else {
                    byte[] missing = "<Error><Code>NoSuchConfiguration</Code></Error>".getBytes(StandardCharsets.UTF_8);
                    return new Reply(404, out, missing, missing.length);
                }
            } else if (method.equals("HEAD")) {
                out.putAll(reported); out.put("Content-Length", String.valueOf(size));
                return new Reply(200, out, new byte[0], 0);
            } else if (method.equals("GET") && query.contains("tagging")) xml = "<Tagging><TagSet/></Tagging>";
            else if (method.equals("POST") && query.contains("uploads")) xml = "<InitiateMultipartUploadResult><UploadId>fixture-upload</UploadId></InitiateMultipartUploadResult>";
            else if (method.equals("POST")) xml = "<CompleteMultipartUploadResult><ETag>\"fixture-etag\"</ETag></CompleteMultipartUploadResult>";
            else if (method.equals("PUT") && headers.keySet().stream().anyMatch(k -> k.equalsIgnoreCase("x-amz-copy-source"))) {
                String tag = query.contains("partNumber") ? "CopyPartResult" : "CopyObjectResult";
                xml = "<" + tag + "><ETag>\"fixture-etag\"</ETag></" + tag + ">";
            } else if (method.equals("GET")) {
                String range = headers.entrySet().stream().filter(e -> e.getKey().equalsIgnoreCase("range")).map(e -> e.getValue().getFirst()).findFirst().orElse(null);
                long start = range == null ? 0 : Long.parseLong(range.substring(6).split("-")[0]);
                long end = range == null ? size - 1 : Long.parseLong(range.substring(6).split("-")[1]);
                int length = (int)(end - start + 1);
                out.put("Content-Length", String.valueOf(length));
                if (range != null) out.put("Content-Range", "bytes " + start + "-" + end + "/" + size);
                if (badRange) out.put("Content-Range", "bytes 0-0/1");
                if (badEtag) out.put("ETag", "\"changed\"");
                boolean truncated;
                synchronized (this) {
                    truncated = interruptOnce || interruptRange == start;
                    interruptOnce = false;
                    if (interruptRange == start) interruptRange = -1;
                }
                byte[] bytes = storage ? Arrays.copyOfRange(stored, (int) start, (int) end + 1) : new byte[length];
                return new Reply(range == null ? 200 : 206, out, truncated ? Arrays.copyOf(bytes, bytes.length - 1) : bytes, length);
            }
            byte[] bytes = xml.getBytes(StandardCharsets.UTF_8);
            return new Reply(method.equals("DELETE") ? 204 : 200, out, bytes, bytes.length);
        }
        @SuppressWarnings("unchecked") private static Map<Object, S3Client> clients() throws Exception {
            var field = Main.class.getDeclaredField("CLIENTS"); field.setAccessible(true); return (Map<Object, S3Client>)field.get(null);
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
                output.write(bytes, offset, count); offset += count + 2;
            }
            throw new AssertionError("Incomplete aws-chunked request");
        }
        @Override public void close() throws Exception {
            if (server != null) server.stop(0);
            BoundedTasks.shutdownAndAwait(httpWorkers);
            Object profile = cachedProfile == null ? invoke("parseProfile", JsonNode.class, params().path("profile")) : cachedProfile;
            S3Client client = clients().remove(profile); if (client != null) client.close();
        }
    }
}
