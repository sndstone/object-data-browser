package com.example.s3browser;

import software.amazon.awssdk.awscore.AwsRequestOverrideConfiguration;
import software.amazon.awssdk.core.SdkRequest;
import software.amazon.awssdk.core.interceptor.Context;
import software.amazon.awssdk.core.interceptor.ExecutionAttributes;
import software.amazon.awssdk.core.interceptor.ExecutionInterceptor;
import software.amazon.awssdk.services.s3.model.*;
import java.time.Duration;

/** Whole-attempt bounds for administration; HTTP connect/read inactivity bounds for transfers. */
final class RequestTimeouts implements ExecutionInterceptor {
    private final Duration administrativeTimeout;

    RequestTimeouts(Duration administrativeTimeout) {
        this.administrativeTimeout = administrativeTimeout;
    }

    @Override public SdkRequest modifyRequest(Context.ModifyRequest context, ExecutionAttributes attributes) {
        SdkRequest request = context.request();
        if (request instanceof PutObjectRequest || request instanceof UploadPartRequest
                || request instanceof GetObjectRequest || request instanceof CopyObjectRequest
                || request instanceof UploadPartCopyRequest) return request;
        if (!(request instanceof S3Request s3)) return request;
        var overrides = s3.overrideConfiguration().orElseGet(() -> AwsRequestOverrideConfiguration.builder().build());
        if (overrides.apiCallAttemptTimeout().isPresent()) return request;
        // SDK v2.41.29 disallows zero durations. Leave the client timeout unset and attach
        // the administrative bound here, before the SDK creates its attempt timer.
        return s3.toBuilder().overrideConfiguration(overrides.toBuilder()
            .apiCallAttemptTimeout(administrativeTimeout).build()).build();
    }
}
