package com.example.s3browser;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpServer;
import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.GetObjectRequest;
import software.amazon.awssdk.services.s3.model.PutObjectRequest;
import java.io.*;
import java.net.InetSocketAddress;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

/** Real Apache HTTP client: progressing bodies outlive the attempt bound; reads still time out. */
final class TimeoutRegressionTest {
    public static void main(String[] args) throws Exception {
        run();
        System.out.println("HTTP timeout regression checks passed.");
    }

    static void run() throws Exception {
        healthySlowBodiesAndStalledReads();
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void healthySlowBodiesAndStalledReads() throws Exception {
        var server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        ExecutorService handlers = Executors.newCachedThreadPool();
        server.setExecutor(handlers);
        AtomicInteger uploaded = new AtomicInteger();
        server.createContext("/", exchange -> {
            try {
                if (exchange.getRequestMethod().equals("PUT")) {
                    uploaded.set(exchange.getRequestBody().readAllBytes().length);
                    exchange.getResponseHeaders().add("ETag", "\"uploaded\"");
                    exchange.sendResponseHeaders(200, -1);
                } else if (exchange.getRequestURI().getPath().equals("/")) {
                    byte[] xml = "<ListAllMyBucketsResult><Buckets></Buckets></ListAllMyBucketsResult>".getBytes(java.nio.charset.StandardCharsets.UTF_8);
                    exchange.sendResponseHeaders(200, xml.length);
                    for (byte next : xml) {
                        exchange.getResponseBody().write(next);
                        exchange.getResponseBody().flush();
                        Thread.sleep(100);
                    }
                } else if (exchange.getRequestURI().getPath().endsWith("stalled-header")) {
                    Thread.sleep(3000);
                    exchange.sendResponseHeaders(200, 0);
                } else {
                    exchange.sendResponseHeaders(200, 24);
                    for (int index = 0; index < 24; index++) {
                        exchange.getResponseBody().write('x');
                        exchange.getResponseBody().flush();
                        Thread.sleep(exchange.getRequestURI().getPath().endsWith("stalled-body") ? 3000 : 100);
                    }
                }
            } catch (IOException expectedDisconnect) {
                // Timeout cases close their socket before this fixture finishes.
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
            } finally { exchange.close(); }
        });
        server.start();
        try (S3Client client = client("http://127.0.0.1:" + server.getAddress().getPort())) {
            check(client.serviceClientConfiguration().overrideConfiguration().apiCallAttemptTimeout().isEmpty(),
                "No whole-attempt deadline on transfer client");
            long start = System.nanoTime();
            int size = 24 * 4096;
            client.putObject(PutObjectRequest.builder().bucket("bucket").key("healthy-upload").build(),
                RequestBody.fromContentProvider(() -> new InputStream() {
                    int remaining = size;
                    @Override public int read() throws IOException {
                        byte[] one = new byte[1];
                        return read(one, 0, 1) == -1 ? -1 : one[0];
                    }
                    @Override public int read(byte[] bytes, int offset, int length) throws IOException {
                        if (remaining == 0) return -1;
                        try { Thread.sleep(100); }
                        catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new InterruptedIOException(); }
                        int count = Math.min(Math.min(length, 4096), remaining);
                        java.util.Arrays.fill(bytes, offset, offset + count, (byte) 'x');
                        remaining -= count;
                        return count;
                    }
                }, size, "application/octet-stream"));
            long uploadNanos = System.nanoTime() - start;
            // Plain-HTTP uploads are chunk-signed, so the wire body carries framing beyond the payload.
            check(uploaded.get() >= size && uploadNanos > TimeUnit.SECONDS.toNanos(1),
                "Progressing upload completes after read-timeout duration (received " + uploaded.get()
                    + " of " + size + " bytes in " + TimeUnit.NANOSECONDS.toMillis(uploadNanos) + " ms)");
            try (var body = client.getObject(get("healthy-download"))) {
                check(body.readAllBytes().length == 24, "Slow progressing download completes");
            }
            for (String key : new String[] {"stalled-header", "stalled-body"}) {
                start = System.nanoTime();
                try (var body = client.getObject(get(key))) {
                    body.readAllBytes();
                    throw new AssertionError("Stalled read completed: " + key);
                } catch (IOException | software.amazon.awssdk.core.exception.SdkClientException expected) {
                    boolean timedOut = false;
                    for (Throwable cause = expected; cause != null; cause = cause.getCause())
                        if (cause instanceof java.net.SocketTimeoutException) timedOut = true;
                    check(timedOut, "Stalled read failed through Apache socket timeout: " + key);
                    check(System.nanoTime() - start < TimeUnit.MILLISECONDS.toNanos(2500),
                        "Apache read inactivity timeout retained: " + key);
                }
            }
            start = System.nanoTime();
            try {
                client.listBuckets();
                throw new AssertionError("Administrative call lost its attempt deadline");
            } catch (software.amazon.awssdk.core.exception.ApiCallAttemptTimeoutException expected) {
                check(System.nanoTime() - start < TimeUnit.MILLISECONDS.toNanos(2500),
                    "Administrative attempt deadline enforced despite progressing response");
            }
        } finally {
            server.stop(0);
            BoundedTasks.shutdownAndAwait(handlers);
        }
    }

    private static GetObjectRequest get(String key) {
        return GetObjectRequest.builder().bucket("bucket").key(key).build();
    }

    private static S3Client client(String endpoint) throws Exception {
        var profile = new ObjectMapper().createObjectNode().put("endpointUrl", endpoint).put("pathStyle", true)
            .put("accessKey", "fixture").put("secretKey", "fixture").put("maxAttempts", 1)
            .put("connectTimeoutSeconds", 1).put("readTimeoutSeconds", 1);
        var parse = Main.class.getDeclaredMethod("parseProfile", com.fasterxml.jackson.databind.JsonNode.class);
        parse.setAccessible(true);
        Object parsed = parse.invoke(null, profile);
        var create = Main.class.getDeclaredMethod("createClient", parsed.getClass());
        create.setAccessible(true);
        return (S3Client) create.invoke(null, parsed);
    }
}
