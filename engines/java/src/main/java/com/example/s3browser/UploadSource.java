package com.example.s3browser;

import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.FileTime;

/** Detect accidental source changes, and share one stable open handle across part retries. */
final class UploadSource implements AutoCloseable {
    record Snapshot(long size, FileTime modified, Object identity) {
        static Snapshot capture(Path path) throws IOException {
            var attrs = Files.readAttributes(path, BasicFileAttributes.class);
            if (!attrs.isRegularFile()) throw new IOException("Upload source is not a regular file.");
            return new Snapshot(attrs.size(), attrs.lastModifiedTime(), attrs.fileKey());
        }
        void verify(Path path) throws IOException {
            if (!equals(capture(path))) throw new IOException("Upload source changed; upload stopped.");
        }
    }

    final Path path;
    final FileChannel channel;
    final Snapshot snapshot;

    UploadSource(Path path, Snapshot snapshot) throws IOException {
        this.path = path;
        this.snapshot = snapshot;
        snapshot.verify(path);
        channel = FileChannel.open(path, StandardOpenOption.READ);
        try { verify(); } catch (IOException error) { channel.close(); throw error; }
    }

    void verify() throws IOException {
        snapshot.verify(path);
        if (channel.size() != snapshot.size()) throw new IOException("Upload source changed; upload stopped.");
    }

    @Override public void close() throws IOException { channel.close(); }
}
