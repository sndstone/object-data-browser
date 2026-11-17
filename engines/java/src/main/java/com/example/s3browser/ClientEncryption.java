package com.example.s3browser;

import com.fasterxml.jackson.databind.JsonNode;
import java.io.*;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.util.*;
import javax.crypto.*;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** age v1 STREAM payload only. The host supplies and authenticates the age header. */
final class ClientEncryption {
    static final int CHUNK = 65536, TAG = 16, SEALED = CHUNK + TAG;
    final int headerLength;
    final String fileName;
    private final byte[] fileKey, header, payloadNonce;

    private ClientEncryption(byte[] fileKey, byte[] header, byte[] nonce, int headerLength, String fileName) {
        this.fileName = fileName; this.fileKey = fileKey; this.header = header; this.payloadNonce = nonce; this.headerLength = headerLength;
    }

    static ClientEncryption parse(JsonNode params, boolean upload, int count) {
        JsonNode option = params.path("clientEncryption");
        if (option.isMissingNode() || option.isNull()) return null;
        if (!option.isObject() || count != 1 || !option.path("format").asText().equals("age-v1"))
            throw invalid();
        Set<String> allowed = upload ? Set.of("format", "fileKey", "header", "payloadNonce")
            : Set.of("format", "fileKey", "headerLength", "fileName");
        option.fieldNames().forEachRemaining(field -> { if (!allowed.contains(field)) throw invalid(); });
        byte[] key = decode(option, "fileKey", 16, 16);
        byte[] header = upload ? decode(option, "header", 1, CHUNK) : null;
        byte[] nonce = upload ? decode(option, "payloadNonce", 16, 16) : null;
        JsonNode length = option.path("headerLength");
        if (!upload && (!length.isIntegralNumber() || !length.canConvertToInt()
                || length.intValue() < 1 || length.intValue() > CHUNK)) throw invalid();
        String fileName = null;
        if (option.has("fileName")) {
            JsonNode name = option.get("fileName");
            if (!name.isTextual()) throw invalid();
            fileName = name.textValue();
            if (fileName.isEmpty() || fileName.equals(".") || fileName.equals("..")
                    || fileName.indexOf('/') >= 0 || fileName.indexOf('\\') >= 0 || fileName.indexOf(0) >= 0) throw invalid();
        }
        return new ClientEncryption(key, header, nonce, upload ? header.length : length.intValue(), fileName);
    }

    private static byte[] decode(JsonNode option, String field, int min, int max) {
        JsonNode value = option.path(field);
        if (!value.isTextual() || value.textValue().length() > ((max + 2) / 3) * 4) throw invalid();
        try {
            byte[] bytes = Base64.getDecoder().decode(value.textValue());
            if (bytes.length < min || bytes.length > max) throw invalid();
            return bytes;
        } catch (IllegalArgumentException error) { throw invalid(); }
    }

    private static Main.SidecarException invalid() {
        return new Main.SidecarException("invalid_config", "Client encryption requires age-v1, one file/key, a 16-byte file key and nonce, and a header of 1–65536 bytes (or its length for download).");
    }

    static Main.SidecarException failed(long index) {
        return new Main.SidecarException("decryption_failed", "Client-encrypted payload authentication failed; partial file discarded.", Map.of("chunk", index));
    }

    record Layout(long plaintext, int headerLength) {
        Layout {
            if (plaintext < 0 || headerLength < 1 || headerLength > CHUNK) throw invalid();
        }
        long chunks() { return Math.max(1, plaintext / CHUNK + (plaintext % CHUNK == 0 ? 0 : 1)); }
        long prefix() { return headerLength + 16L; }
        long ciphertext() {
            try { return Math.addExact(prefix(), Math.addExact(plaintext, Math.multiplyExact(TAG, chunks()))); }
            catch (ArithmeticException error) { throw invalid(); }
        }
        long offset(long index) { return prefix() + index * SEALED; }
        int plainLength(long index) { return (int) Math.min(CHUNK, plaintext - index * CHUNK); }
    }

    Layout uploadLayout(long plaintext) { return new Layout(plaintext, headerLength); }

    Layout downloadLayout(long ciphertext) {
        long payload = ciphertext - headerLength - 16;
        if (ciphertext < headerLength + 32L) throw failed(0);
        long chunks = payload / SEALED + (payload % SEALED == 0 ? 0 : 1);
        long plaintext = payload - TAG * chunks;
        if (plaintext < 0 || (chunks > 1 && plaintext <= (chunks - 1) * CHUNK)) throw failed(chunks - 1);
        return new Layout(plaintext, headerLength);
    }

    byte[] key(byte[] nonce) {
        return hkdf(fileKey, nonce, "payload".getBytes(StandardCharsets.US_ASCII), 32);
    }

    /** RFC 5869 extract-and-expand, using the JDK's maintained HMAC implementation. */
    static byte[] hkdf(byte[] ikm, byte[] salt, byte[] info, int length) {
        if (length < 0 || length > 255 * 32) throw new IllegalArgumentException("Invalid HKDF output length.");
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(salt.length == 0 ? new byte[32] : salt, "HmacSHA256"));
            byte[] prk = mac.doFinal(ikm);
            mac.init(new SecretKeySpec(prk, "HmacSHA256"));
            byte[] output = new byte[length], previous = new byte[0];
            for (int offset = 0, counter = 1; offset < length; counter++) {
                mac.update(previous); mac.update(info); mac.update((byte) counter);
                previous = mac.doFinal();
                int count = Math.min(previous.length, length - offset);
                System.arraycopy(previous, 0, output, offset, count); offset += count;
            }
            Arrays.fill(prk, (byte) 0);
            return output;
        } catch (GeneralSecurityException error) { throw new IllegalStateException("JDK HmacSHA256 unavailable."); }
    }

    static byte[] seal(byte[] key, long index, boolean last, byte[] plaintext) {
        try { return crypt(Cipher.ENCRYPT_MODE, key, index, last, plaintext); }
        catch (GeneralSecurityException error) { throw new IllegalStateException("JDK ChaCha20-Poly1305 unavailable."); }
    }

    static byte[] open(byte[] key, long index, boolean last, byte[] sealed) {
        try { return crypt(Cipher.DECRYPT_MODE, key, index, last, sealed); }
        catch (AEADBadTagException error) { throw failed(index); }
        catch (GeneralSecurityException error) { throw new IllegalStateException("JDK ChaCha20-Poly1305 unavailable."); }
    }

    private static byte[] crypt(int mode, byte[] key, long index, boolean last, byte[] input) throws GeneralSecurityException {
        byte[] nonce = new byte[12];
        // Object-size limits keep the 88-bit counter within a positive Java long.
        for (int i = 10; i >= 0; i--) { nonce[i] = (byte) index; index >>>= 8; }
        nonce[11] = (byte) (last ? 1 : 0);
        Cipher cipher = Cipher.getInstance("ChaCha20-Poly1305");
        cipher.init(mode, new SecretKeySpec(key, "ChaCha20"), new IvParameterSpec(nonce));
        return cipher.doFinal(input);
    }

    InputStream stream(UploadSource source, long offset, long length, Runnable checkpoint) {
        Layout layout = uploadLayout(source.snapshot.size());
        byte[] key = key(payloadNonce);
        // One cached sealed chunk per stream, even for multi-GiB provider parts.
        return new InputStream() {
            long position = offset, remaining = length, cachedIndex = -1;
            byte[] cached;
            @Override public int read() throws IOException {
                byte[] one = new byte[1]; return read(one, 0, 1) < 0 ? -1 : one[0] & 255;
            }
            @Override public int read(byte[] bytes, int start, int count) throws IOException {
                Objects.checkFromIndexSize(start, count, bytes.length);
                if (count == 0) return 0;
                checkpoint.run();
                if (remaining == 0) return -1;
                byte[] segment; int segmentOffset;
                if (position < headerLength) { segment = header; segmentOffset = (int) position; }
                else if (position < layout.prefix()) { segment = payloadNonce; segmentOffset = (int) (position - headerLength); }
                else {
                    long index = (position - layout.prefix()) / SEALED;
                    if (cachedIndex != index) {
                        source.verify();
                        byte[] plain = new byte[layout.plainLength(index)];
                        ByteBuffer buffer = ByteBuffer.wrap(plain);
                        long readPosition = index * CHUNK;
                        while (buffer.hasRemaining()) {
                            checkpoint.run();
                            int read = source.channel.read(buffer, readPosition);
                            if (read < 0) throw new EOFException("Upload source ended before its declared size.");
                            readPosition += read;
                        }
                        source.verify();
                        cached = seal(key, index, index == layout.chunks() - 1, plain);
                        cachedIndex = index;
                    }
                    segment = cached; segmentOffset = (int) (position - layout.offset(index));
                }
                int copied = (int) Math.min(Math.min(count, remaining), segment.length - segmentOffset);
                System.arraycopy(segment, segmentOffset, bytes, start, copied);
                position += copied; remaining -= copied;
                return copied;
            }
            @Override public void close() { Arrays.fill(key, (byte) 0); }
        };
    }
}
