package com.example.s3browser;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;

/** Output boundary for diagnostics, provider errors and retained state; never used on wire data. */
final class SecretHygiene implements AutoCloseable {
    private static final Map<String, Integer> ACTIVE = new ConcurrentHashMap<>();
    private static final String SECRET = "(?:fileName|fileKey|customerKey|x-amz-(?:copy-source-)?server-side-encryption-customer-key|x-ms-encryption-key|authorization|[^\\s\"':=,]*secret[^\\s\"':=,]*|[^\\s\"':=,]*token[^\\s\"':=,]*)";
    private static final Pattern FIELD = Pattern.compile("(?i)([\"']?" + SECRET + "[\"']?\\s*[:=]\\s*)(\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,}\\]]+)");
    private final Set<String> keys = new HashSet<>();

    SecretHygiene(JsonNode request) {
        collect(request);
        keys.forEach(key -> ACTIVE.merge(key, 1, Integer::sum));
    }

    private void collect(JsonNode node) {
        if (node.isObject()) node.fields().forEachRemaining(entry -> {
            // fileName is hidden as a field only: its value is an ordinary word
            // and the published destination path contains it.
            if (entry.getKey().equalsIgnoreCase("fileName")) return;
            if (sensitive(entry.getKey()) && entry.getValue().isTextual() && !entry.getValue().asText().isEmpty())
                keys.add(entry.getValue().asText());
            else collect(entry.getValue());
        });
        else if (node.isArray()) node.forEach(this::collect);
    }

    static boolean sensitive(String field) {
        String lower = field.toLowerCase(Locale.ROOT);
        return lower.equals("filename") || lower.equals("filekey") || lower.equals("customerkey") || lower.equals("x-amz-server-side-encryption-customer-key")
            || lower.equals("x-amz-copy-source-server-side-encryption-customer-key")
            || lower.equals("x-ms-encryption-key") || lower.contains("authorization")
            || lower.contains("secret") || lower.contains("token") || lower.contains("access-key");
    }

    static String text(String text) {
        if (text == null) return null;
        for (String key : ACTIVE.keySet()) text = text.replace(key, "[REDACTED]");
        return FIELD.matcher(text).replaceAll("$1\"[REDACTED]\"");
    }

    static JsonNode clean(JsonNode node) {
        if (node.isObject()) {
            ObjectNode copy = ((ObjectNode) node).deepCopy();
            node.fields().forEachRemaining(e -> copy.set(e.getKey(), sensitive(e.getKey())
                ? com.fasterxml.jackson.databind.node.TextNode.valueOf("[REDACTED]") : clean(e.getValue())));
            return copy;
        }
        if (node.isArray()) {
            var copy = com.fasterxml.jackson.databind.node.JsonNodeFactory.instance.arrayNode();
            node.forEach(value -> copy.add(clean(value)));
            return copy;
        }
        return node.isTextual() ? com.fasterxml.jackson.databind.node.TextNode.valueOf(text(node.asText())) : node;
    }

    static Object clean(Object value) {
        if (value instanceof JsonNode node) return clean(node);
        if (value instanceof Map<?, ?> map) {
            Map<String, Object> copy = new LinkedHashMap<>();
            map.forEach((key, item) -> copy.put(String.valueOf(key), sensitive(String.valueOf(key)) ? "[REDACTED]" : clean(item)));
            return copy;
        }
        if (value instanceof Collection<?> list) return list.stream().map(SecretHygiene::clean).toList();
        return value instanceof String text ? text(text) : value;
    }

    // The distribution has no SLF4J logging backend. Also disable the JDK/optional simple
    // logging backends' SDK and HTTP wire categories: header dumps bypass structured logs.
    static void disableWireLogging() {
        for (String category : List.of("software.amazon.awssdk", "org.apache.http", "org.apache.http.wire", "org.apache.http.headers")) {
            java.util.logging.Logger.getLogger(category).setLevel(java.util.logging.Level.OFF);
            System.setProperty("org.slf4j.simpleLogger.log." + category, "off");
            System.setProperty("org.apache.commons.logging.simplelog.log." + category, "off");
        }
    }

    @Override public void close() { keys.forEach(key -> ACTIVE.computeIfPresent(key, (k, count) -> count == 1 ? null : count - 1)); }
}
