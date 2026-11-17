package com.example.s3browser;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;

/**
 * Output boundary for diagnostics, provider errors and retained state.
 * Responses and events pass through {@link #clean}: there only sensitive fields and
 * occurrences of active encryption keys and long credentials are redacted.
 */
final class SecretHygiene implements AutoCloseable {
    private static final Map<String, Integer> ACTIVE = new ConcurrentHashMap<>();
    private static final String SECRET = "(?:fileName|fileKey|customerKey|x-amz-(?:copy-source-)?server-side-encryption-customer-key|x-ms-encryption-key|authorization|[^\\s\"':=,]*secret[^\\s\"':=,]*|[^\\s\"':=,]*token[^\\s\"':=,]*)";
    private static final Pattern FIELD = Pattern.compile("(?i)([\"']?" + SECRET + "[\"']?\\s*[:=]\\s*)(\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,}\\]]+)");
    private static final int MIN_SCRUBBED_LENGTH = 16;
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
            if (sensitive(entry.getKey()) && entry.getValue().isTextual() && !entry.getValue().asText().isEmpty()) {
                // An encryption key is always scrubbed. Another credential is scrubbed only
                // when it is long: a short one ("test", "minioadmin") is an ordinary word,
                // and replacing it would rewrite keys, cursors and request IDs that contain it.
                String value = entry.getValue().asText();
                if (keyField(entry.getKey()) || value.length() >= MIN_SCRUBBED_LENGTH) keys.add(value);
            } else collect(entry.getValue());
        });
        else if (node.isArray()) node.forEach(this::collect);
    }

    static boolean sensitive(String field) {
        String lower = field.toLowerCase(Locale.ROOT);
        return lower.equals("filename") || keyField(lower) || lower.contains("authorization")
            || lower.contains("secret") || lower.contains("token") || lower.contains("access-key");
    }

    private static boolean keyField(String field) {
        String lower = field.toLowerCase(Locale.ROOT);
        return lower.equals("filekey") || lower.equals("customerkey") || lower.equals("x-amz-server-side-encryption-customer-key")
            || lower.equals("x-amz-copy-source-server-side-encryption-customer-key") || lower.equals("x-ms-encryption-key");
    }

    /** Diagnostic text: hides active key values and anything written as a sensitive field. */
    static String text(String text) {
        if (text == null) return null;
        return FIELD.matcher(values(text)).replaceAll("$1\"[REDACTED]\"");
    }

    /** Response data: hides active key values only and never rewrites by pattern. */
    private static String values(String text) {
        if (text == null) return null;
        for (String key : ACTIVE.keySet()) text = text.replace(key, "[REDACTED]");
        return text;
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
        return node.isTextual() ? com.fasterxml.jackson.databind.node.TextNode.valueOf(values(node.asText())) : node;
    }

    static Object clean(Object value) {
        if (value instanceof JsonNode node) return clean(node);
        if (value instanceof Map<?, ?> map) {
            Map<String, Object> copy = new LinkedHashMap<>();
            map.forEach((key, item) -> copy.put(String.valueOf(key), sensitive(String.valueOf(key)) ? "[REDACTED]" : clean(item)));
            return copy;
        }
        if (value instanceof Collection<?> list) return list.stream().map(SecretHygiene::clean).toList();
        return value instanceof String text ? values(text) : value;
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
