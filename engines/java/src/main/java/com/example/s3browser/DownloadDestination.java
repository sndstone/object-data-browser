package com.example.s3browser;

import java.io.IOException;
import java.nio.file.*;
import java.util.Locale;
import java.util.Map;
import java.util.TreeMap;

/** Publishes validated downloads without replacing an existing directory entry. */
final class DownloadDestination implements AutoCloseable {
    final Path path;
    DownloadDestination(Path directory) throws IOException {
        path = Files.createTempFile(directory, ".odb-", ".part");
    }
    Path publish(Path directory, String key, String policy) throws IOException {
        return publish(new Allocator(directory), key, policy);
    }

    /** One name index per batch; exclusive publication remains the collision authority. */
    static final class Allocator {
        final Path directory;
        final Map<String, Path> occupied = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
        Allocator(Path directory) throws IOException {
            this.directory = directory;
            try (var entries = Files.list(directory)) {
                entries.forEach(entry -> occupied.putIfAbsent(entry.getFileName().toString(), entry));
            }
        }
    }

    Path publish(Allocator allocator, String key, String policy) throws IOException {
        synchronized (allocator) { return publishLocked(allocator, key, policy); }
    }

    private Path publishLocked(Allocator allocator, String key, String policy) throws IOException {
        Path directory = allocator.directory;
        Map<String, Path> occupied = allocator.occupied;
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
            Path existing = occupied.get(candidate);
            if (policy.equals("replace")) {
                Path target = existing == null ? directory.resolve(candidate) : existing;
                Path published = Files.move(path, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                occupied.put(candidate, published);
                return published;
            }
            if (existing != null) continue;
            Path target = directory.resolve(candidate);
            try {
                Files.createLink(target, path);
                occupied.put(candidate, target);
                return target;
            } catch (FileAlreadyExistsException conflict) {
                occupied.put(candidate, target);
            }
        }
        throw new IOException("Cannot allocate a unique download name.");
    }
    public void close() throws IOException { Files.deleteIfExists(path); }
}
