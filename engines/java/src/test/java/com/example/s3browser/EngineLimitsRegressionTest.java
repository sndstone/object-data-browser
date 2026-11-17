package com.example.s3browser;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.*;
import software.amazon.awssdk.awscore.AwsRequestOverrideConfiguration;
import software.amazon.awssdk.core.interceptor.ExecutionAttributes;
import software.amazon.awssdk.core.interceptor.InterceptorContext;
import software.amazon.awssdk.services.s3.model.*;
import java.time.Duration;

/** Transport limits and worker cleanup checks that do not need a listening socket. */
final class EngineLimitsRegressionTest {
    private static final ObjectMapper JSON = new ObjectMapper();

    public static void main(String[] args) throws Exception {
        ResourceRegressionTest.run();
        run();
        System.out.println("Engine limits and resource regression checks passed.");
    }

    static void run() throws Exception {
        byteFrameBoundaries();
        oversizedFrameIsStructuredAndResynchronizes();
        overloadPreservesControlPath();
        administrativeTimeoutsExcludeTransfers();
        sdkAppliesAdministrativeDeadlineBeforeAttempt();
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void administrativeTimeoutsExcludeTransfers() {
        var policy = new RequestTimeouts(Duration.ofSeconds(60));
        for (S3Request request : new S3Request[] {PutObjectRequest.builder().build(), GetObjectRequest.builder().build(),
                UploadPartRequest.builder().build(), CopyObjectRequest.builder().build(), UploadPartCopyRequest.builder().build()}) {
            var result = (S3Request) policy.modifyRequest(InterceptorContext.builder().request(request).build(), new ExecutionAttributes());
            check(result.overrideConfiguration().flatMap(AwsRequestOverrideConfiguration::apiCallAttemptTimeout).isEmpty(),
                "Transfer has no attempt deadline: " + request.getClass().getSimpleName());
        }
        var request = ListBucketsRequest.builder().overrideConfiguration(c -> c.putHeader("fixture", "retained")).build();
        var result = (S3Request) policy.modifyRequest(InterceptorContext.builder().request(request).build(), new ExecutionAttributes());
        var config = result.overrideConfiguration().orElseThrow();
        check(config.apiCallAttemptTimeout().orElseThrow().equals(Duration.ofSeconds(60)), "Administrative attempt bound retained");
        check(config.headers().get("fixture").equals(java.util.List.of("retained")), "Existing overrides preserved");
        request = request.toBuilder().overrideConfiguration(c -> c.apiCallAttemptTimeout(Duration.ofSeconds(10))).build();
        check(policy.modifyRequest(InterceptorContext.builder().request(request).build(), new ExecutionAttributes()) == request,
            "Explicit request deadline preserved");
    }

    private static void sdkAppliesAdministrativeDeadlineBeforeAttempt() {
        var http = new software.amazon.awssdk.http.SdkHttpClient() {
            @Override public void close() {}
            @Override public software.amazon.awssdk.http.ExecutableHttpRequest prepareRequest(software.amazon.awssdk.http.HttpExecuteRequest request) {
                return new software.amazon.awssdk.http.ExecutableHttpRequest() {
                    @Override public void abort() {}
                    @Override public software.amazon.awssdk.http.HttpExecuteResponse call() throws IOException {
                        try {
                            if (request.contentStreamProvider().isPresent())
                                try (var body = request.contentStreamProvider().orElseThrow().newStream()) { body.readAllBytes(); }
                            Thread.sleep(500);
                        } catch (InterruptedException error) {
                            Thread.currentThread().interrupt();
                            throw new InterruptedIOException("Fixture interrupted by SDK attempt timer");
                        }
                        return software.amazon.awssdk.http.HttpExecuteResponse.builder()
                            .response(software.amazon.awssdk.http.SdkHttpResponse.builder().statusCode(200).build())
                            .responseBody(software.amazon.awssdk.http.AbortableInputStream.createEmpty()).build();
                    }
                };
            }
        };
        try (var client = software.amazon.awssdk.services.s3.S3Client.builder()
                .endpointOverride(java.net.URI.create("http://fixture.invalid"))
                .region(software.amazon.awssdk.regions.Region.US_EAST_1)
                .credentialsProvider(software.amazon.awssdk.auth.credentials.StaticCredentialsProvider.create(
                    software.amazon.awssdk.auth.credentials.AwsBasicCredentials.create("fixture", "fixture")))
                .httpClient(http).overrideConfiguration(c -> c.addExecutionInterceptor(new RequestTimeouts(Duration.ofMillis(100)))
                    .retryPolicy(software.amazon.awssdk.core.retry.RetryPolicy.none())).build()) {
            client.putObject(PutObjectRequest.builder().bucket("bucket").key("key").build(),
                software.amazon.awssdk.core.sync.RequestBody.fromString("healthy upload"));
            try {
                client.listBuckets();
                throw new AssertionError("SDK ignored administrative deadline installed by interceptor");
            } catch (software.amazon.awssdk.core.exception.ApiCallAttemptTimeoutException expected) {}
        }
    }

    private static void byteFrameBoundaries() throws Exception {
        var frames = new InputFrames(new ByteArrayInputStream(
            "12345678\n123456789\nok\néééé\nééééé\nlast".getBytes(StandardCharsets.UTF_8)), 8);
        check(frames.read().equals("12345678"), "Exact byte limit accepted");
        try { frames.read(); throw new AssertionError("Oversized ASCII accepted"); }
        catch (InputFrames.TooLargeException expected) {}
        check(frames.read().equals("ok"), "Oversized frame discarded through newline");
        check(frames.read().equals("éééé"), "Exact UTF-8 byte limit accepted");
        try { frames.read(); throw new AssertionError("UTF-8 limited by characters rather than bytes"); }
        catch (InputFrames.TooLargeException expected) {}
        check(frames.read().equals("last") && frames.read() == null, "Unterminated final frame and EOF");
        frames = new InputFrames(new ByteArrayInputStream("123456789".getBytes(StandardCharsets.UTF_8)), 8);
        try { frames.read(); throw new AssertionError("Oversized EOF frame accepted"); }
        catch (InputFrames.TooLargeException expected) {}
        check(frames.read() == null, "Oversized EOF frame discarded");
    }

    private static void oversizedFrameIsStructuredAndResynchronizes() throws Exception {
        check(InputFrames.MAX_BYTES == 64 * 1024 * 1024, "Production frame limit is 64 MiB");
        // Generate the oversized input without retaining a second 64 MiB copy in this fixture.
        InputStream oversized = new InputStream() {
            int remaining = InputFrames.MAX_BYTES + 1;
            @Override public int read() { return remaining-- > 0 ? 'x' : -1; }
            @Override public int read(byte[] bytes, int offset, int length) {
                if (remaining <= 0) return -1;
                int count = Math.min(length, remaining);
                java.util.Arrays.fill(bytes, offset, offset + count, (byte) 'x');
                remaining -= count;
                return count;
            }
        };
        var input = new SequenceInputStream(oversized, new ByteArrayInputStream(
            "\n{\"requestId\":\"after-large\",\"method\":\"health\"}\n".getBytes(StandardCharsets.UTF_8)));
        InputStream savedInput = System.in;
        PrintStream savedOutput = System.out;
        var output = new ByteArrayOutputStream();
        try {
            System.setIn(input);
            System.setOut(new PrintStream(output, true, StandardCharsets.UTF_8));
            Main.main(new String[0]);
        } finally { System.setIn(savedInput); System.setOut(savedOutput); }
        var lines = output.toString(StandardCharsets.UTF_8).lines().toList();
        check(lines.size() == 2, "One frame error followed by next request response");
        var error = JSON.readTree(lines.getFirst());
        check(!error.path("ok").asBoolean() && error.path("requestId").isNull()
            && error.path("error").path("code").asText().equals("invalid_request"), "Structured oversized frame error");
        var next = JSON.readTree(lines.getLast());
        check(next.path("ok").asBoolean() && next.path("requestId").asText().equals("after-large"), "Reader resynchronizes after large input");
    }

    @SuppressWarnings("unchecked")
    private static void overloadPreservesControlPath() throws Exception {
        var pool = Main.newRequestPool();
        var controlPool = Main.newControlPool();
        CountDownLatch started = new CountDownLatch(pool.getCorePoolSize()), release = new CountDownLatch(1);
        PrintStream savedOutput = System.out;
        var output = new ByteArrayOutputStream();
        var controlsField = Main.class.getDeclaredField("TRANSFER_REGISTRY");
        controlsField.setAccessible(true);
        var registry = (java.util.Map<String, Object>) controlsField.get(null);
        var controlClass = Class.forName("com.example.s3browser.Main$JobControl");
        var constructor = controlClass.getDeclaredConstructor();
        constructor.setAccessible(true);
        registry.put("limits-fixture", constructor.newInstance());
        try {
            for (int index = 0; index < pool.getCorePoolSize(); index++) pool.execute(() -> {
                started.countDown();
                try { release.await(); } catch (InterruptedException expected) { Thread.currentThread().interrupt(); }
            });
            check(started.await(2, TimeUnit.SECONDS), "All eight request workers held open");
            System.setOut(new PrintStream(output, true, StandardCharsets.UTF_8));
            for (int index = 0; index < Main.REQUEST_QUEUE_SIZE; index++)
                Main.dispatchRequest(pool, controlPool, "{\"requestId\":\"queued-" + index + "\",\"method\":\"health\"}");
            Main.dispatchRequest(pool, controlPool, "{\"requestId\":\"overflow\",\"method\":\"health\"}");
            var error = JSON.readTree(output.toString(StandardCharsets.UTF_8));
            check(error.path("requestId").asText().equals("overflow") && !error.path("ok").asBoolean()
                && error.path("error").path("code").asText().equals("overloaded"), "Correlated structured overload response");
            output.reset();
            for (String method : new String[] {"pauseTransfer", "resumeTransfer", "cancelTransfer", "cancelToolExecution",
                    "getBenchmarkStatus", "pauseBenchmark", "resumeBenchmark", "stopBenchmark"}) {
                Main.dispatchRequest(pool, controlPool, "{\"requestId\":\"" + method + "\",\"method\":\"" + method
                    + "\",\"params\":{\"jobId\":\"limits-fixture\"}}");
            }
            controlPool.shutdown();
            check(controlPool.awaitTermination(2, TimeUnit.SECONDS), "Independent controls settle while request pool remains saturated");
            var controls = output.toString(StandardCharsets.UTF_8).lines().toList();
            check(controls.size() == 8 && pool.getQueue().size() == Main.REQUEST_QUEUE_SIZE,
                "Controls and status respond while request workers and queue remain full");
            for (String response : controls) check(!JSON.readTree(response).path("error").path("code").asText().equals("overloaded"),
                "Control request never rejected for admission");
            for (int index = 0; index < 3; index++) check(JSON.readTree(controls.get(index)).path("result").path("status").asText()
                .equals(new String[] {"paused", "running", "cancelling"}[index]), "Pause/resume/cancel changes live transfer state");
        } finally {
            registry.remove("limits-fixture");
            pool.getQueue().clear();
            release.countDown();
            BoundedTasks.shutdownAndAwait(pool);
            BoundedTasks.shutdownAndAwait(controlPool);
            System.setOut(savedOutput);
        }
    }
}
