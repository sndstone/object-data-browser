package com.example.s3browser;

import java.io.IOException;
import java.io.InputStream;
import java.io.RandomAccessFile;
import java.nio.file.Path;

/** A repeatable bounded file range, including S3 parts larger than 2 GiB. */
final class FilePartStream extends InputStream {
    private final RandomAccessFile file;
    private final Runnable checkpoint;
    private long remaining;
    FilePartStream(Path path, long offset, long length, Runnable checkpoint) throws IOException {
        this.file = new RandomAccessFile(path.toFile(), "r");
        this.remaining = length;
        this.checkpoint = checkpoint;
        try { file.seek(offset); } catch (IOException error) { file.close(); throw error; }
    }
    @Override public int read() throws IOException {
        byte[] one = new byte[1];
        return read(one, 0, 1) == -1 ? -1 : Byte.toUnsignedInt(one[0]);
    }
    @Override public int read(byte[] bytes, int offset, int length) throws IOException {
        if (length == 0) return 0;
        checkpoint.run();
        if (remaining == 0) return -1;
        int count = file.read(bytes, offset, (int) Math.min(remaining, length));
        if (count < 0) throw new IOException("Upload source ended before its declared size.");
        remaining -= count;
        return count;
    }
    @Override public void close() throws IOException { file.close(); }
}
