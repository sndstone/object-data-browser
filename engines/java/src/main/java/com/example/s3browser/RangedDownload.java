package com.example.s3browser;

import java.io.*;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.util.Objects;

/** Retries interrupted response bodies without retrying invalid responses or local writes. */
final class RangedDownload {
    record Response(InputStream body, String contentRange, String etag, Long length) implements AutoCloseable {
        @Override public void close() throws IOException { body.close(); }
    }
    interface Open { Response get() throws IOException; }
    private static final class InterruptedBody extends IOException {
        InterruptedBody(IOException cause) { super("Download response body was interrupted.", cause); }
    }

    static long transfer(FileChannel target, long start, long end, long total, String etag,
                         int maxAttempts, Open open, Runnable checkpoint) throws IOException {
        return transfer(target, start, end, total, etag, maxAttempts, true, open, checkpoint);
    }

    static long transfer(FileChannel target, long start, long end, long total, String etag,
                         int maxAttempts, boolean ranged, Open open, Runnable checkpoint) throws IOException {
        long expected = end - start + 1;
        byte[] buffer = new byte[(int) Math.min(1024 * 1024, expected)];
        for (int attempt = 1; ; attempt++) {
            checkpoint.run();
            try (Response response = open.get()) {
                if ((ranged && !("bytes " + start + "-" + end + "/" + total).equals(response.contentRange()))
                        || (etag != null && !Objects.equals(etag, response.etag()))
                        || (response.length() != null && response.length() != expected)) {
                    throw new IOException("Download range or source validator mismatch; partial file discarded.");
                }
                long count = 0;
                while (true) {
                    checkpoint.run();
                    int read;
                    try { read = response.body().read(buffer); }
                    catch (IOException error) { throw new InterruptedBody(error); }
                    if (read == -1) break;
                    if (count + read > expected) throw new IOException("Oversized range body.");
                    ByteBuffer bytes = ByteBuffer.wrap(buffer, 0, read);
                    long position = start + count;
                    while (bytes.hasRemaining()) {
                        checkpoint.run();
                        position += target.write(bytes, position);
                    }
                    count += read;
                }
                if (count != expected) throw new InterruptedBody(new EOFException("Incomplete range body."));
                return count;
            } catch (InterruptedBody failure) {
                if (attempt >= Math.clamp(maxAttempts, 1, 5)) throw failure;
                // Check pause/cancel during backoff, too. Retrying rewrites the range from its start.
                for (int tick = 0; tick < Math.min(2 << (attempt - 1), 20); tick++) {
                    checkpoint.run();
                    try { Thread.sleep(50); }
                    catch (InterruptedException error) {
                        Thread.currentThread().interrupt();
                        throw new java.io.InterruptedIOException("Download retry interrupted.");
                    }
                }
            }
        }
    }
}
