package com.example.s3browser;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import software.amazon.awssdk.services.s3.model.*;
import java.net.URI;
import java.security.MessageDigest;
import java.util.*;

/** Validated per-operation options. Keys are only held by the operation, never by a profile/client. */
final class ObjectEncryption {
    private static final ObjectMapper JSON = new ObjectMapper();
    private final String mode;
    private final Map<String, String> headers;
    private ObjectEncryption(String mode, Map<String, String> headers) { this.mode = mode; this.headers = headers; }

    static ObjectEncryption parse(JsonNode params, String field) {
        JsonNode node = params.path(field);
        if (node.isMissingNode() || node.isNull()) return new ObjectEncryption("bucketDefault", Map.of());
        if (!node.isObject() || !node.path("mode").isTextual()) throw invalid();
        String mode = node.path("mode").asText();
        Set<String> allowed = new HashSet<>(Set.of("mode"));
        switch (mode) {
            case "bucketDefault", "sse-s3" -> { }
            case "sse-kms", "dsse-kms" -> {
                allowed.addAll(Set.of("kmsKeyId", "kmsEncryptionContext"));
                if (mode.equals("sse-kms")) allowed.add("bucketKeyEnabled");
            }
            case "sse-c", "azure-cpk" -> allowed.add("customerKey");
            case "azure-scope" -> allowed.add("encryptionScope");
            default -> throw invalid();
        }
        var fields = node.fieldNames();
        while (fields.hasNext()) if (!allowed.contains(fields.next())) throw invalid();
        String provider = params.path("profile").path("endpointType").asText("s3Compatible");
        boolean azure = "azureBlob".equals(provider);
        if (!mode.equals("bucketDefault") && !Set.of("awsS3", "s3Compatible", "azureBlob").contains(provider)) throw invalid();
        if (!mode.equals("bucketDefault") && mode.startsWith("azure-") != azure) throw invalid();
        if (field.equals("sourceEncryption") && !Set.of("bucketDefault", "sse-c", "azure-cpk").contains(mode)) throw invalid();
        Map<String, String> headers = new LinkedHashMap<>();
        if (mode.equals("sse-c") || mode.equals("azure-cpk")) {
            if (!node.path("customerKey").isTextual()) throw invalid();
            byte[] key;
            try { key = Base64.getDecoder().decode(node.path("customerKey").asText()); }
            catch (IllegalArgumentException error) { throw invalid(); }
            if (key.length != 32) throw invalid();
            try {
                URI endpoint = URI.create(params.path("profile").path("endpointUrl").asText());
                String host = endpoint.getHost();
                boolean loopback = host != null && (host.equalsIgnoreCase("localhost") || host.equals("[::1]")
                    || host.equals("::1") || host.matches("127\\.(?:[0-9]{1,3}\\.){2}[0-9]{1,3}")
                        && Arrays.stream(host.split("\\.")).allMatch(s -> Integer.parseInt(s) <= 255));
                if (!"https".equalsIgnoreCase(endpoint.getScheme()) && !("http".equalsIgnoreCase(endpoint.getScheme()) && loopback)) throw invalid();
                if (azure) throw new Main.SidecarException("unsupported_feature", "Azure encryption is not supported by the java engine.");
                headers.put("x-amz-server-side-encryption-customer-algorithm", "AES256");
                headers.put("x-amz-server-side-encryption-customer-key", node.path("customerKey").asText());
                headers.put("x-amz-server-side-encryption-customer-key-MD5", Base64.getEncoder().encodeToString(MessageDigest.getInstance("MD5").digest(key)));
            } catch (Main.SidecarException error) { throw error; }
            catch (Exception error) { throw invalid(); }
            finally { Arrays.fill(key, (byte) 0); }
        } else if (mode.equals("azure-scope")) {
            if (!node.path("encryptionScope").isTextual() || node.path("encryptionScope").asText().isBlank()) throw invalid();
            throw new Main.SidecarException("unsupported_feature", "Azure encryption is not supported by the java engine.");
        } else if (!mode.equals("bucketDefault")) {
            headers.put("x-amz-server-side-encryption", switch (mode) { case "sse-s3" -> "AES256"; case "sse-kms" -> "aws:kms"; default -> "aws:kms:dsse"; });
            if (node.has("kmsKeyId")) {
                if (!node.path("kmsKeyId").isTextual()) throw invalid();
                headers.put("x-amz-server-side-encryption-aws-kms-key-id", node.path("kmsKeyId").asText());
            }
            if (node.has("bucketKeyEnabled")) {
                if (!node.path("bucketKeyEnabled").isBoolean()) throw invalid();
                headers.put("x-amz-server-side-encryption-bucket-key-enabled", node.path("bucketKeyEnabled").asText());
            }
            if (node.has("kmsEncryptionContext")) {
                JsonNode context = node.path("kmsEncryptionContext");
                if (!context.isObject()) throw invalid();
                for (JsonNode value : context) if (!value.isTextual()) throw invalid();
                try { headers.put("x-amz-server-side-encryption-context", Base64.getEncoder().encodeToString(JSON.writeValueAsBytes(context))); }
                catch (Exception error) { throw invalid(); }
            }
        }
        // Header control characters would otherwise be echoed by the HTTP client's validator.
        for (String value : headers.values()) if (value.indexOf('\r') >= 0 || value.indexOf('\n') >= 0) throw invalid();
        return new ObjectEncryption(mode, Map.copyOf(headers));
    }

    private static Main.SidecarException invalid() {
        return new Main.SidecarException("invalid_config", "Invalid object encryption configuration: check mode, allowed fields, key encoding and endpoint security.");
    }
    boolean customer() { return mode.equals("sse-c"); }
    <B extends S3Request.Builder> B write(B builder) { return apply(builder, headers); }
    <B extends S3Request.Builder> B read(B builder) { return customer() ? write(builder) : builder; }
    <B extends S3Request.Builder> B source(B builder) {
        if (!customer()) return builder;
        Map<String, String> source = new LinkedHashMap<>();
        headers.forEach((key, value) -> source.put(key.replace("x-amz-", "x-amz-copy-source-"), value));
        return apply(builder, source);
    }
    private static <B extends S3Request.Builder> B apply(B builder, Map<String, String> values) {
        if (!values.isEmpty()) {
            var config = builder.overrideConfiguration() == null
                ? software.amazon.awssdk.awscore.AwsRequestOverrideConfiguration.builder() : builder.overrideConfiguration().toBuilder();
            values.forEach(config::putHeader);
            builder.overrideConfiguration(config.build());
        }
        return builder;
    }

    static Map<String, Object> reported(HeadObjectResponse head) {
        Map<String, Object> out = new LinkedHashMap<>();
        String mode = switch (Objects.toString(head.serverSideEncryptionAsString(), "")) {
            case "AES256" -> "sse-s3";
            case "aws:kms" -> "sse-kms";
            case "aws:kms:dsse" -> "dsse-kms";
            default -> null;
        };
        if (head.sseCustomerAlgorithm() != null) mode = "sse-c";
        if (mode == null) return out;
        out.put("mode", mode);
        if (head.ssekmsKeyId() != null) out.put("kmsKeyId", head.ssekmsKeyId());
        if (head.bucketKeyEnabled() != null) out.put("bucketKeyEnabled", head.bucketKeyEnabled());
        if (head.sseCustomerKeyMD5() != null) out.put("customerKeyMd5", head.sseCustomerKeyMD5());
        return out;
    }
}
