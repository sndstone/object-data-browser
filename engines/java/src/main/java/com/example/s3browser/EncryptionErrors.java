package com.example.s3browser;

import software.amazon.awssdk.core.interceptor.*;
import software.amazon.awssdk.services.s3.model.*;
import java.util.Locale;

/** Adds context only after the SDK's normal retries; never changes a request or its mode. */
final class EncryptionErrors implements ExecutionInterceptor {
    static final class Hint extends RuntimeException {
        final String hint;
        Hint(String hint) { super("Object encryption: " + hint); this.hint = hint; }
    }

    @Override public Throwable modifyException(Context.FailedExecution context, ExecutionAttributes attributes) {
        if (!(context.exception() instanceof S3Exception error)) return context.exception();
        boolean read = context.request() instanceof HeadObjectRequest || context.request() instanceof GetObjectRequest;
        boolean customer = context.httpRequest().map(r -> r.firstMatchingHeader("x-amz-server-side-encryption-customer-key").isPresent()).orElse(false);
        String hint = hint(error, read, customer);
        if (hint != null) error.addSuppressed(new Hint(hint));
        return error;
    }

    static String hint(S3Exception error, boolean read, boolean customer) {
        String code = error.awsErrorDetails() == null ? "" : String.valueOf(error.awsErrorDetails().errorCode());
        String message = error.awsErrorDetails() == null ? "" : String.valueOf(error.awsErrorDetails().errorMessage());
        String text = (code + " " + message).toLowerCase(Locale.ROOT);
        boolean kms = text.contains("kms.") || text.contains("kms:") || text.contains("kms key");
        if (kms && (text.contains("accessdenied") || text.contains("access denied") || text.contains("not authorized"))) return "kms_access_denied";
        if (kms && (text.contains("disabled") || text.contains("notfound") || text.contains("not found") || text.contains("unavailable") || text.contains("invalidstate"))) return "kms_key_unavailable";
        boolean ssec = text.contains("sse-c") || text.contains("customer") || text.contains("server-side-encryption-customer");
        if (ssec && (text.contains("blocked") || text.contains("disabled") || text.contains("not allowed"))) return "sse_c_blocked";
        if (ssec && (text.contains("mismatch") || text.contains("does not match") || text.contains("incorrect key"))) return "sse_c_key_mismatch";
        // A HEAD has no body, so the SDK reports no code and only the status text.
        boolean bodiless = code.isEmpty() || code.equals("null");
        if (read && !customer && error.statusCode() == 400 && (ssec || bodiless || message.isBlank()
                || message.equals("null") || code.equals("BadRequest"))) return "sse_c_key_required";
        if (text.contains("encryption") && text.contains("policy") && (text.contains("require") || text.contains("must"))) return "encryption_required_by_policy";
        if ((ssec || kms || text.contains("encryption")) && (text.contains("notimplemented") || text.contains("not supported"))) return "unsupported_by_endpoint";
        return null;
    }
}
