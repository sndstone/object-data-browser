package com.example.s3browser;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/** Newline-delimited UTF-8 frames, bounded in bytes before decoding or parsing. */
final class InputFrames {
    static final int MAX_BYTES = 64 * 1024 * 1024;
    private final InputStream input;
    private final int limit;

    InputFrames(InputStream input, int limit) {
        if (limit < 1) throw new IllegalArgumentException("Positive frame limit required.");
        this.input = new BufferedInputStream(input);
        this.limit = limit;
    }

    String read() throws IOException {
        var bytes = new ByteArrayOutputStream();
        boolean oversized = false;
        int next;
        while ((next = input.read()) != -1 && next != '\n') {
            if (bytes.size() == limit) oversized = true;
            else bytes.write(next);
        }
        // Discard the rest of an oversized frame so the next request stays aligned.
        if (oversized) throw new TooLargeException();
        if (next == -1 && bytes.size() == 0) return null;
        return bytes.toString(StandardCharsets.UTF_8);
    }

    static final class TooLargeException extends IOException {}
}
