package com.example.s3browser;

import java.io.IOException;
import java.nio.file.*;
import java.util.Locale;

/** Publishes validated downloads without replacing an existing directory entry. */
final class DownloadDestination implements AutoCloseable {
    final Path path;
    DownloadDestination(Path directory) throws IOException {
        path = Files.createTempFile(directory, ".odb-", ".part");
    }
    Path publish(Path directory, String key, String policy) throws IOException {
        if (!policy.equals("keepBoth") && !policy.equals("replace")) throw new IOException("Unknown download conflict policy.");
        String normalized = key.replace('\\', '/');
        String name = normalized.substring(normalized.lastIndexOf('/') + 1)
            .replaceAll("[<>:\"/\\\\|?*\\x00-\\x1f]", "_").replaceAll("[ .]+$", "");
        if (name.isEmpty()) name = "download";
        if (name.length() > 100) name = name.substring(0, 100);
        if (name.toUpperCase(Locale.ROOT).matches("(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\\..*)?")) name = "_" + name;
        int dot = name.lastIndexOf('.');
        String stem = dot > 0 ? name.substring(0, dot) : name;
        String ext = dot > 0 ? name.substring(dot) : "";
        for (int i = 0; i < 100000; i++) {
            String candidate = i == 0 ? name : stem + " (" + i + ")" + ext;
            if (policy.equals("replace")) {
                Path target;
                try (var entries = Files.list(directory)) {
                    target = entries.filter(p -> p.getFileName().toString().equalsIgnoreCase(candidate)).findFirst().orElse(directory.resolve(candidate));
                }
                return Files.move(path, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            }
            try (var entries = Files.list(directory)) {
                if (entries.anyMatch(p -> p.getFileName().toString().equalsIgnoreCase(candidate))) continue;
            }
            Path target = directory.resolve(candidate);
            try { Files.createLink(target, path); return target; }
            catch (FileAlreadyExistsException conflict) { /* Try another name. */ }
        }
        throw new IOException("Cannot allocate a unique download name.");
    }
    public void close() throws IOException { Files.deleteIfExists(path); }
}
