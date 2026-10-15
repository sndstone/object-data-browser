package com.example.s3browser;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.*;
import java.util.Comparator;

/** Run by Gradle test without an additional test-framework dependency. */
public final class TransferRegressionTest {
    private static final ObjectMapper JSON = new ObjectMapper();

    public static void main(String[] args) throws Exception {
        multipartBoundaries();
        validationBeforeClientCreation();
        keepBothCollisions();
        replaceAndDirectories();
        symlinks();
        System.out.println("Transfer regression checks passed (multipart limits, collisions, replace, symlinks).");
    }

    private static void validationBeforeClientCreation() throws Exception {
        try (Directory directory = new Directory()) {
            Path file = directory.path.resolve("oversized");
            try (var sparse = new java.io.RandomAccessFile(file.toFile(), "rw")) {
                sparse.setLength(5L * 1024 * 1024 * 10000 + 1);
            }
            var params = JSON.createObjectNode();
            params.putObject("profile").put("endpointUrl", "not a valid endpoint")
                .put("accessKey", "test").put("secretKey", "test");
            params.put("bucketName", "test");
            params.putArray("filePaths").add(file.toString());
            params.put("multipartThresholdMiB", 1).put("multipartChunkMiB", 1);
            var startUpload = Main.class.getDeclaredMethod("startUpload", com.fasterxml.jackson.databind.JsonNode.class);
            startUpload.setAccessible(true);
            try {
                startUpload.invoke(null, params);
                throw new AssertionError("Oversized upload accepted");
            } catch (java.lang.reflect.InvocationTargetException error) {
                check(error.getCause().getMessage().contains("10,000-part limits"), "Validation precedes client creation");
            }
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void multipartBoundaries() throws Exception {
        long mib = 1024L * 1024L;
        long[][] cases = {{-1, 5}, {0, 5}, {1, 5}, {5, 5}, {8, 8}, {5120, 5120}, {5121, 5120}, {Long.MAX_VALUE, 5120}};
        for (long[] c : cases) {
            check(Main.uploadPartSizeBytes(JSON.valueToTree(c[0])) == c[1] * mib, "Part-size clamp: " + c[0]);
        }
        check(Main.uploadPartSizeBytes(JSON.readTree("18446744073709551615")) == 5120 * mib, "Large integer clamp");
        check(Main.uploadPartSizeBytes(JSON.readTree("null")) == 8 * mib, "Default part size");
        long chunk = 5 * mib;
        long maxObject = 50000L * 1024 * mib;
        for (long size : new long[] {0, chunk - 1, chunk, chunk * 10000}) {
            Main.validateUploadSize(size, 1, chunk);
        }
        Main.validateUploadSize(maxObject, 1, 5120 * mib);
        Main.validateUploadSize(chunk * 10000 + 1, maxObject, chunk);
        for (long[] c : new long[][] {
                {chunk * 10000 + 1, 1, chunk},
                {chunk * 10000 + 1, chunk * 10000 + 1, chunk},
                {maxObject + 1, Long.MAX_VALUE, chunk},
                {Long.MAX_VALUE, 1, chunk}}) {
            try {
                Main.validateUploadSize(c[0], c[1], c[2]);
                throw new AssertionError("Oversized upload accepted");
            } catch (RuntimeException error) {
                var code = error.getClass().getDeclaredField("code");
                code.setAccessible(true);
                check(code.get(error).equals("invalid_config"), "Upload error code");
                check(error.getMessage().contains("10,000-part limits"), "Upload error message");
            }
        }
    }

    private static void keepBothCollisions() throws Exception {
        try (Directory directory = new Directory()) {
            Files.writeString(directory.path.resolve("FILE.txt"), "original");
            for (int i = 1; i <= 256; i++) {
                Files.writeString(directory.path.resolve("FILE (" + i + ").txt"), "original");
            }
            Path target = directory.publish("prefix/file.txt", "keepBoth");
            check(target.getFileName().toString().equals("file (257).txt"), "Dense case-insensitive collisions");
            check(Files.readString(target).equals("download"), "Published data");
            check(Files.readString(directory.path.resolve("FILE.txt")).equals("original"), "Original preserved");
            // These compare equal with equalsIgnoreCase, but not with String.toLowerCase.
            for (String[] names : new String[][] {{"Σ.txt", "ς.txt"}, {"ſ.txt", "S.txt"}, {"ı.txt", "I.txt"}}) {
                Files.writeString(directory.path.resolve(names[0]), "original");
                check(!directory.publish(names[1], "keepBoth").getFileName().toString().equals(names[1]), "Unicode collision");
            }
        }
    }

    private static void replaceAndDirectories() throws Exception {
        try (Directory directory = new Directory()) {
            Path existing = directory.path.resolve("FILE.txt");
            Files.writeString(existing, "original");
            check(directory.publish("file.txt", "replace").equals(existing), "Existing spelling preserved");
            check(Files.readString(existing).equals("download"), "Replaced data");
            Path folder = Files.createDirectory(directory.path.resolve("folder"));
            Files.writeString(folder.resolve("child"), "original");
            try (DownloadDestination staged = directory.staged()) {
                try {
                    staged.publish(directory.path, "FOLDER", "replace");
                    throw new AssertionError("Directory replaced");
                } catch (java.io.IOException expected) {
                    check(Files.exists(staged.path), "Failed publication preserves staged file until cleanup");
                }
            }
            check(Files.readString(folder.resolve("child")).equals("original"), "Directory preserved");
        }
    }

    private static void symlinks() throws Exception {
        for (boolean dangling : new boolean[] {false, true}) {
            for (String policy : new String[] {"keepBoth", "replace"}) {
                try (Directory directory = new Directory(); Directory outside = new Directory()) {
                    Path referent = outside.path.resolve("outside.txt");
                    if (!dangling) Files.writeString(referent, "original");
                    Path link = directory.path.resolve("FILE.txt");
                    Files.createSymbolicLink(link, referent);
                    Path target = directory.publish("file.txt", policy);
                    check(Files.readString(target).equals("download"), "Published data by symlink");
                    check(Files.exists(referent) != dangling, "Dangling symlink not followed");
                    if (!dangling) check(Files.readString(referent).equals("original"), "Symlink referent preserved");
                    check(Files.isSymbolicLink(link) == policy.equals("keepBoth"), "Symlink entry policy");
                }
            }
        }
    }

    private static final class Directory implements AutoCloseable {
        final Path path = Files.createTempDirectory("odb-test-");
        Directory() throws java.io.IOException {}
        DownloadDestination staged() throws java.io.IOException {
            DownloadDestination staged = new DownloadDestination(path);
            Files.writeString(staged.path, "download");
            return staged;
        }
        Path publish(String key, String policy) throws java.io.IOException {
            try (DownloadDestination staged = staged()) {
                return staged.publish(path, key, policy);
            }
        }
        public void close() throws java.io.IOException {
            try (var entries = Files.walk(path)) {
                for (Path entry : entries.sorted(Comparator.reverseOrder()).toList()) Files.delete(entry);
            }
        }
    }
}
