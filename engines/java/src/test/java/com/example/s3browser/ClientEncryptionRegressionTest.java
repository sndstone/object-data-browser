package com.example.s3browser;

import com.fasterxml.jackson.databind.*;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.io.*;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;

/** Contract vectors run before transport tests; no additional crypto/test dependencies. */
final class ClientEncryptionRegressionTest {
    private static final ObjectMapper JSON = new ObjectMapper();

    public static void main(String[] args) throws Exception {
        run();
        System.out.println("Client encryption vectors, RFC 5869 and negative checks passed.");
    }

    static void run() throws Exception {
        hkdfRfc5869();
        vectorsAndRanges();
        rejectsUnauthenticatedPayloads();
        validationAndArithmetic();
        ciphertextSizeValidation();
    }

    static JsonNode vectors() throws IOException {
        Path directory = Path.of("").toAbsolutePath();
        while (directory != null) {
            Path path = directory.resolve("contracts/vectors/age-stream.json");
            if (Files.exists(path)) return JSON.readTree(path.toFile()).path("cases");
            directory = directory.getParent();
        }
        throw new IOException("Cannot locate age-stream contract vectors.");
    }

    static byte[] plaintext(JsonNode vector) {
        byte[] bytes = new byte[vector.path("plaintextLength").asInt()];
        for (int i = 0; i < bytes.length; i++) bytes[i] = (byte) (i * 31 + (i >> 8) * 7 + 3);
        return bytes;
    }

    static ObjectNode option(JsonNode vector, boolean upload) {
        var p = JSON.createObjectNode();
        var c = p.putObject("clientEncryption").put("format", "age-v1").put("fileKey", vector.path("fileKey").asText());
        if (upload) c.put("header", vector.path("header").asText()).put("payloadNonce", vector.path("payloadNonce").asText());
        else c.put("headerLength", vector.path("headerLength").asInt());
        return p;
    }

    static String sha(byte[] bytes) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }

    private static void hkdfRfc5869() {
        byte[] ikm = new byte[22]; Arrays.fill(ikm, (byte) 0x0b);
        hkdf(ikm, sequence(0, 13), sequence(0xf0, 10),
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", 42);
        hkdf(sequence(0, 80), sequence(0x60, 80), sequence(0xb0, 80),
            "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87", 82);
        hkdf(ikm, new byte[0], new byte[0],
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8", 42);
    }
    private static byte[] sequence(int first, int length) {
        byte[] bytes = new byte[length]; for (int i = 0; i < length; i++) bytes[i] = (byte) (first + i); return bytes;
    }
    private static void hkdf(byte[] ikm, byte[] salt, byte[] info, String expected, int length) {
        check(Arrays.equals(ClientEncryption.hkdf(ikm, salt, info, length), HexFormat.of().parseHex(expected)), "RFC 5869 SHA-256 vector");
    }

    static byte[] object(JsonNode vector, Path source) throws Exception {
        var cipher = ClientEncryption.parse(option(vector, true), true, 1);
        try (var input = new UploadSource(source, UploadSource.Snapshot.capture(source));
             var stream = cipher.stream(input, 0, vector.path("objectLength").asLong(), () -> {})) {
            return stream.readAllBytes();
        }
    }

    private static byte[] decrypt(JsonNode vector, byte[] object) throws Exception {
        var cipher = ClientEncryption.parse(option(vector, false), false, 1);
        var layout = cipher.downloadLayout(object.length);
        byte[] key = cipher.key(Arrays.copyOfRange(object, cipher.headerLength, cipher.headerLength + 16));
        var output = new ByteArrayOutputStream();
        for (long i = 0; i < layout.chunks(); i++) {
            int start = (int) layout.offset(i), end = start + layout.plainLength(i) + ClientEncryption.TAG;
            output.write(ClientEncryption.open(key, i, i == layout.chunks() - 1, Arrays.copyOfRange(object, start, end)));
        }
        return output.toByteArray();
    }

    private static void vectorsAndRanges() throws Exception {
        Path source = Files.createTempFile("odb-age-vector-", ".bin");
        try {
            for (JsonNode vector : vectors()) {
                byte[] plain = plaintext(vector); Files.write(source, plain);
                byte[] object = object(vector, source);
                check(object.length == vector.path("objectLength").asLong(), "Vector object length");
                check(sha(object).equals(vector.path("objectSha256").asText()), "Vector object bytes: " + plain.length);
                check(sha(decrypt(vector, object)).equals(vector.path("plaintextSha256").asText()), "Vector plaintext SHA-256");
                var cipher = ClientEncryption.parse(option(vector, true), true, 1);
                var layout = cipher.uploadLayout(plain.length);
                check(cipher.downloadLayout(object.length).plaintext() == plain.length, "Layout roundtrip");
                long[] offsets = {0, 1, cipher.headerLength - 1, cipher.headerLength, layout.prefix() - 1,
                    layout.prefix(), layout.prefix() + ClientEncryption.CHUNK - 1,
                    layout.prefix() + ClientEncryption.SEALED - 1, 5L * 1024 * 1024 - 7, object.length - 1};
                try (var input = new UploadSource(source, UploadSource.Snapshot.capture(source))) {
                    for (long offset : offsets) if (offset < object.length) {
                        int count = (int) Math.min(131093, object.length - offset);
                        for (int retry = 0; retry < 2; retry++) {
                            try (var stream = cipher.stream(input, offset, count, () -> {})) {
                                check(Arrays.equals(stream.readAllBytes(), Arrays.copyOfRange(object, (int) offset, (int) offset + count)), "Repeatable straddling cipher range");
                            }
                        }
                    }
                    Files.write(source, new byte[]{99});
                    try (var stream = cipher.stream(input, layout.prefix(), ClientEncryption.TAG, () -> {})) {
                        stream.read(); throw new AssertionError("Changed source accepted");
                    } catch (IOException expected) { }
                }
            }
        } finally { Files.delete(source); }
    }

    private static void rejectsUnauthenticatedPayloads() throws Exception {
        JsonNode vector = vectors().get(6); // Four chunks, including a short final chunk.
        Path source = Files.createTempFile("odb-age-negative-", ".bin");
        try {
            Files.write(source, plaintext(vector)); byte[] object = object(vector, source);
            int prefix = vector.path("headerLength").asInt() + 16;
            var layout = ClientEncryption.parse(option(vector, false), false, 1).downloadLayout(object.length);
            for (int i = 0; i < layout.chunks(); i++) {
                byte[] flipped = object.clone(); flipped[prefix + i * ClientEncryption.SEALED] ^= 1;
                fails(vector, flipped, i);
            }
            // At a full non-final chunk boundary the receiver must require the final flag.
            fails(vector, Arrays.copyOf(object, prefix + ClientEncryption.SEALED), 0);
            fails(vector, Arrays.copyOf(object, prefix + 2 * ClientEncryption.SEALED), 1);
            fails(vector, Arrays.copyOf(object, object.length - 1), 3);
            fails(vector, Arrays.copyOf(object, prefix + ClientEncryption.SEALED + 8), 1);
            byte[] trailing = Arrays.copyOf(object, object.length + ClientEncryption.SEALED);
            System.arraycopy(object, prefix, trailing, object.length, ClientEncryption.SEALED);
            fails(vector, trailing, 3);
            byte[] swapped = object.clone();
            System.arraycopy(object, prefix, swapped, prefix + ClientEncryption.SEALED, ClientEncryption.SEALED);
            System.arraycopy(object, prefix + ClientEncryption.SEALED, swapped, prefix, ClientEncryption.SEALED);
            fails(vector, swapped, 0);
            byte[] nonce = object.clone(); nonce[prefix - 1] ^= 1; fails(vector, nonce, 0);
        } finally { Files.delete(source); }
    }

    private static void fails(JsonNode vector, byte[] bytes, long chunk) throws Exception {
        try { decrypt(vector, bytes); throw new AssertionError("Unauthenticated payload accepted"); }
        catch (Main.SidecarException error) {
            var code = error.getClass().getDeclaredField("code"); code.setAccessible(true);
            var details = error.getClass().getDeclaredField("details"); details.setAccessible(true);
            check(code.get(error).equals("decryption_failed"), "Authentication error code");
            check(((Map<?, ?>) details.get(error)).get("chunk").equals(chunk), "Authentication chunk index");
        }
    }

    private static void validationAndArithmetic() throws Exception {
        JsonNode vector = vectors().get(0);
        check(ClientEncryption.parse(JSON.createObjectNode(), true, 2) == null, "Default off");
        check(ClientEncryption.parse(JSON.createObjectNode().putNull("clientEncryption"), true, 2) == null, "Null off");
        for (boolean upload : new boolean[]{true, false}) {
            for (int count : new int[]{0, 2}) invalid(option(vector, upload), upload, count);
            for (String bad : new String[]{"[]", "false", "{}", "{\"format\":\"other\"}"}) {
                var p = JSON.createObjectNode(); p.set("clientEncryption", JSON.readTree(bad)); invalid(p, upload, 1);
            }
            for (String field : new String[]{"format", "fileKey", upload ? "header" : "headerLength", upload ? "payloadNonce" : "unknown"}) {
                var p = option(vector, upload); ((ObjectNode) p.path("clientEncryption")).put(field, "%%%"); invalid(p, upload, 1);
            }
            for (int size : new int[]{0, 15, 17}) {
                var p = option(vector, upload); ((ObjectNode) p.path("clientEncryption")).put("fileKey", Base64.getEncoder().encodeToString(new byte[size])); invalid(p, upload, 1);
            }
        }
        for (int size : new int[]{0, 15, 17}) {
            var p = option(vector, true); ((ObjectNode) p.path("clientEncryption")).put("payloadNonce", Base64.getEncoder().encodeToString(new byte[size])); invalid(p, true, 1);
        }
        var p = option(vector, true); ((ObjectNode) p.path("clientEncryption")).put("header", Base64.getEncoder().encodeToString(new byte[65537])); invalid(p, true, 1);
        for (String bad : new String[]{"0", "65537", "1.5", "9223372036854775807", "null"}) {
            p = option(vector, false); ((ObjectNode) p.path("clientEncryption")).set("headerLength", JSON.readTree(bad)); invalid(p, false, 1);
        }
        for (String bad : new String[]{"null", "1", "false", "[]", "{}", "\"\"", "\".\"", "\"..\"", "\"a/b\"", "\"a\\\\b\"", "\"a\\u0000b\""}) {
            p = option(vector, false);
            ((ObjectNode) p.path("clientEncryption")).set("fileName", JSON.readTree(bad));
            invalid(p, false, 1);
            p.putArray("keys").add("token.age");
            // No profile or destination: reaching provider setup would fail differently.
            var method = Main.class.getDeclaredMethod("startDownload", JsonNode.class);
            method.setAccessible(true);
            try { method.invoke(null, p); throw new AssertionError("Invalid download name accepted"); }
            catch (java.lang.reflect.InvocationTargetException error) {
                check(error.getCause() instanceof Main.SidecarException, "Configuration rejected before provider setup");
                var code = error.getCause().getClass().getDeclaredField("code"); code.setAccessible(true);
                check(code.get(error.getCause()).equals("invalid_config"), "Download name validation code");
            }
        }
        var cipher = ClientEncryption.parse(option(vector, false), false, 1);
        for (long length : new long[]{0, 183, 199, 184L + ClientEncryption.SEALED + 1, 184L + ClientEncryption.SEALED + 16}) {
            try { cipher.downloadLayout(length); throw new AssertionError("Impossible length accepted"); }
            catch (Main.SidecarException expected) { }
        }
        long max = 50000L * 1024 * 1024 * 1024;
        check(cipher.downloadLayout(cipher.uploadLayout(max).ciphertext()).plaintext() == max, "Large offset arithmetic");
    }

    private static void invalid(ObjectNode p, boolean upload, int count) {
        try { ClientEncryption.parse(p, upload, count); throw new AssertionError("Invalid client encryption accepted"); }
        catch (Main.SidecarException expected) {
            try {
                var code = expected.getClass().getDeclaredField("code"); code.setAccessible(true);
                check(code.get(expected).equals("invalid_config"), "Invalid configuration error code");
            } catch (ReflectiveOperationException error) { throw new AssertionError(error); }
        }
    }

    private static void ciphertextSizeValidation() throws Exception {
        Path source = Files.createTempFile("odb-age-size-", ".bin");
        try {
            // Plaintext fits exactly 10,000 minimum-size parts; age overhead needs more.
            try (var sparse = new RandomAccessFile(source.toFile(), "rw")) { sparse.setLength(5L * 1024 * 1024 * 10000); }
            var p = option(vectors().get(0), true);
            p.putObject("profile").put("endpointUrl", "invalid endpoint").put("accessKey", "test").put("secretKey", "test");
            p.put("bucketName", "bucket").put("multipartThresholdMiB", 1).put("multipartChunkMiB", 5);
            p.putArray("filePaths").add(source.toString());
            var call = Main.class.getDeclaredMethod("startUpload", JsonNode.class); call.setAccessible(true);
            try { call.invoke(null, p); throw new AssertionError("Ciphertext part limit ignored"); }
            catch (java.lang.reflect.InvocationTargetException error) {
                check(error.getCause().getMessage().contains("10,000-part limits"), "Ciphertext size validated before client creation");
            }
        } finally { Files.delete(source); }
    }
    static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
