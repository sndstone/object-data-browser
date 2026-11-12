package com.example.s3browser;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.*;

final class ReviewRegressionTest {
    static void run() throws Exception {
        for (String selected : new String[]{null, "null"}) {
            var deletes = new ArrayList<String>();
            var server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
            server.createContext("/", exchange -> {
                exchange.getRequestBody().readAllBytes();
                var headers = exchange.getResponseHeaders();
                headers.add("ETag", "\"copied\"");
                if (exchange.getRequestMethod().equals("HEAD")) {
                    headers.add("Content-Length", "3");
                    headers.add("x-amz-version-id", "discovered-v2");
                    exchange.sendResponseHeaders(200, -1);
                } else if (exchange.getRequestMethod().equals("DELETE")) {
                    deletes.add(exchange.getRequestURI().toString());
                    exchange.sendResponseHeaders(204, -1);
                } else {
                    byte[] body = "<CopyObjectResult><ETag>\"destination\"</ETag></CopyObjectResult>".getBytes(StandardCharsets.UTF_8);
                    exchange.sendResponseHeaders(200, body.length);
                    exchange.getResponseBody().write(body);
                }
                exchange.close();
            });
            server.start();
            try {
                var params = new ObjectMapper().createObjectNode();
                params.putObject("profile").put("endpointType", "awsS3")
                    .put("endpointUrl", "http://127.0.0.1:" + server.getAddress().getPort())
                    .put("region", "us-east-1").put("accessKey", "fixture").put("secretKey", "fixture")
                    .put("pathStyle", true).put("maxAttempts", 1);
                params.put("sourceBucketName", "bucket").put("sourceKey", " report ")
                    .put("destinationBucketName", "bucket").put("destinationKey", "renamed");
                if (selected != null) params.put("sourceVersionId", selected);
                var move = Main.class.getDeclaredMethod("moveObject", com.fasterxml.jackson.databind.JsonNode.class);
                move.setAccessible(true);
                move.invoke(null, params);
                if (deletes.size() != 1 || !deletes.getFirst().startsWith("/bucket/%20report%20"))
                    throw new AssertionError("Move deleted the wrong key: " + deletes);
                if (selected == null && deletes.getFirst().contains("versionId="))
                    throw new AssertionError("Ordinary move permanently deleted a discovered version");
                if (selected != null && !deletes.getFirst().contains("versionId=null"))
                    throw new AssertionError("Explicit null version was lost");
            } finally { server.stop(0); }
        }
    }
}
