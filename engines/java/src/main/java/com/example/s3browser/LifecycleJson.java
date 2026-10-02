package com.example.s3browser;

import com.fasterxml.jackson.databind.JsonNode;
import software.amazon.awssdk.services.s3.model.*;
import java.time.Instant;
import java.util.*;

/** Preserve every modeled lifecycle predicate/action; reject unmodeled fields before writing. */
final class LifecycleJson {
    private static void fields(JsonNode n, String... names) {
        Set<String> allowed = Set.of(names);
        n.fieldNames()
                .forEachRemaining(
                        k -> {
                            if (!allowed.contains(k))
                                throw new IllegalArgumentException(
                                        "Unsupported lifecycle field "
                                                + k
                                                + "; configuration was not changed.");
                        });
    }

    private static Integer integer(JsonNode n, String key) {
        return n.hasNonNull(key) ? n.get(key).intValue() : null;
    }

    private static Long number(JsonNode n, String key) {
        return n.hasNonNull(key) ? n.get(key).longValue() : null;
    }

    private static String text(JsonNode n, String key) {
        return n.hasNonNull(key) ? n.get(key).asText() : null;
    }

    private static Instant date(JsonNode n) {
        return n.isTextual() ? Instant.parse(n.asText()) : null;
    }

    private static Tag tag(JsonNode n) {
        fields(n, "Key", "Value");
        return Tag.builder().key(text(n, "Key")).value(text(n, "Value")).build();
    }

    private static LifecycleRuleFilter filter(JsonNode n) {
        fields(n, "Prefix", "Tag", "And", "ObjectSizeGreaterThan", "ObjectSizeLessThan");
        var b =
                LifecycleRuleFilter.builder()
                        .prefix(text(n, "Prefix"))
                        .objectSizeGreaterThan(number(n, "ObjectSizeGreaterThan"))
                        .objectSizeLessThan(number(n, "ObjectSizeLessThan"));
        if (n.path("Tag").isObject()) b.tag(tag(n.get("Tag")));
        if (n.path("And").isObject()) {
            var a = n.get("And");
            fields(a, "Prefix", "Tags", "ObjectSizeGreaterThan", "ObjectSizeLessThan");
            List<Tag> tags = new ArrayList<>();
            a.path("Tags").forEach(t -> tags.add(tag(t)));
            b.and(
                    LifecycleRuleAndOperator.builder()
                            .prefix(text(a, "Prefix"))
                            .tags(tags)
                            .objectSizeGreaterThan(number(a, "ObjectSizeGreaterThan"))
                            .objectSizeLessThan(number(a, "ObjectSizeLessThan"))
                            .build());
        }
        return b.build();
    }

    static List<LifecycleRule> parse(JsonNode nodes) {
        if (!nodes.isArray())
            throw new IllegalArgumentException("Lifecycle Rules must be an array.");
        List<LifecycleRule> rules = new ArrayList<>();
        for (var n : nodes) {
            fields(
                    n,
                    "ID",
                    "Status",
                    "Prefix",
                    "Filter",
                    "Expiration",
                    "Transitions",
                    "NoncurrentVersionExpiration",
                    "NoncurrentVersionTransitions",
                    "AbortIncompleteMultipartUpload");
            if (!Set.of("Enabled", "Disabled").contains(n.path("Status").asText()))
                throw new IllegalArgumentException("Lifecycle status must be Enabled or Disabled.");
            var b =
                    LifecycleRule.builder()
                            .id(text(n, "ID"))
                            .status(text(n, "Status"))
                            .prefix(text(n, "Prefix"));
            if (n.path("Filter").isObject()) b.filter(filter(n.get("Filter")));
            var e = n.path("Expiration");
            if (e.isObject()) {
                fields(e, "Days", "Date", "ExpiredObjectDeleteMarker");
                b.expiration(
                        LifecycleExpiration.builder()
                                .days(integer(e, "Days"))
                                .date(date(e.path("Date")))
                                .expiredObjectDeleteMarker(
                                        e.hasNonNull("ExpiredObjectDeleteMarker")
                                                ? e.get("ExpiredObjectDeleteMarker").asBoolean()
                                                : null)
                                .build());
            }
            List<Transition> transitions = new ArrayList<>();
            for (var t : n.path("Transitions")) {
                fields(t, "Days", "Date", "StorageClass");
                transitions.add(
                        Transition.builder()
                                .days(integer(t, "Days"))
                                .date(date(t.path("Date")))
                                .storageClass(text(t, "StorageClass"))
                                .build());
            }
            b.transitions(transitions);
            e = n.path("NoncurrentVersionExpiration");
            if (e.isObject()) {
                fields(e, "NoncurrentDays", "NewerNoncurrentVersions");
                b.noncurrentVersionExpiration(
                        NoncurrentVersionExpiration.builder()
                                .noncurrentDays(integer(e, "NoncurrentDays"))
                                .newerNoncurrentVersions(integer(e, "NewerNoncurrentVersions"))
                                .build());
            }
            List<NoncurrentVersionTransition> noncurrent = new ArrayList<>();
            for (var t : n.path("NoncurrentVersionTransitions")) {
                fields(t, "NoncurrentDays", "NewerNoncurrentVersions", "StorageClass");
                noncurrent.add(
                        NoncurrentVersionTransition.builder()
                                .noncurrentDays(integer(t, "NoncurrentDays"))
                                .newerNoncurrentVersions(integer(t, "NewerNoncurrentVersions"))
                                .storageClass(text(t, "StorageClass"))
                                .build());
            }
            b.noncurrentVersionTransitions(noncurrent);
            var a = n.path("AbortIncompleteMultipartUpload");
            if (a.isObject()) {
                fields(a, "DaysAfterInitiation");
                b.abortIncompleteMultipartUpload(
                        AbortIncompleteMultipartUpload.builder()
                                .daysAfterInitiation(integer(a, "DaysAfterInitiation"))
                                .build());
            }
            rules.add(b.build());
        }
        return rules;
    }

    private static Map<String, Object> map(Object... values) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (int i = 0; i < values.length; i += 2)
            if (values[i + 1] != null) m.put((String) values[i], values[i + 1]);
        return m;
    }

    private static String date(Instant i) {
        return i == null ? null : i.toString();
    }

    static Map<String, Object> raw(LifecycleRule r) {
        var f = r.filter();
        var a = f == null ? null : f.and();
        var e = r.expiration();
        var ne = r.noncurrentVersionExpiration();
        return map(
                "ID",
                r.id(),
                "Status",
                r.statusAsString(),
                "Prefix",
                r.prefix(),
                "Filter",
                f == null
                        ? null
                        : map(
                                "Prefix",
                                f.prefix(),
                                "Tag",
                                f.tag() == null
                                        ? null
                                        : map("Key", f.tag().key(), "Value", f.tag().value()),
                                "ObjectSizeGreaterThan",
                                f.objectSizeGreaterThan(),
                                "ObjectSizeLessThan",
                                f.objectSizeLessThan(),
                                "And",
                                a == null
                                        ? null
                                        : map(
                                                "Prefix",
                                                a.prefix(),
                                                "Tags",
                                                a.tags().isEmpty()
                                                        ? null
                                                        : a.tags().stream()
                                                                .map(
                                                                        t ->
                                                                                map(
                                                                                        "Key",
                                                                                        t.key(),
                                                                                        "Value",
                                                                                        t.value()))
                                                                .toList(),
                                                "ObjectSizeGreaterThan",
                                                a.objectSizeGreaterThan(),
                                                "ObjectSizeLessThan",
                                                a.objectSizeLessThan())),
                "Expiration",
                e == null
                        ? null
                        : map(
                                "Days",
                                e.days(),
                                "Date",
                                date(e.date()),
                                "ExpiredObjectDeleteMarker",
                                e.expiredObjectDeleteMarker()),
                "Transitions",
                r.transitions().isEmpty()
                        ? null
                        : r.transitions().stream()
                                .map(
                                        t ->
                                                map(
                                                        "Days",
                                                        t.days(),
                                                        "Date",
                                                        date(t.date()),
                                                        "StorageClass",
                                                        t.storageClassAsString()))
                                .toList(),
                "NoncurrentVersionExpiration",
                ne == null
                        ? null
                        : map(
                                "NoncurrentDays",
                                ne.noncurrentDays(),
                                "NewerNoncurrentVersions",
                                ne.newerNoncurrentVersions()),
                "NoncurrentVersionTransitions",
                r.noncurrentVersionTransitions().isEmpty()
                        ? null
                        : r.noncurrentVersionTransitions().stream()
                                .map(
                                        t ->
                                                map(
                                                        "NoncurrentDays",
                                                        t.noncurrentDays(),
                                                        "NewerNoncurrentVersions",
                                                        t.newerNoncurrentVersions(),
                                                        "StorageClass",
                                                        t.storageClassAsString()))
                                .toList(),
                "AbortIncompleteMultipartUpload",
                r.abortIncompleteMultipartUpload() == null
                        ? null
                        : map(
                                "DaysAfterInitiation",
                                r.abortIncompleteMultipartUpload().daysAfterInitiation()));
    }
}
