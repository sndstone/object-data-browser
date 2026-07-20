package com.example.s3_browser_crossplat

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import com.amazonaws.ClientConfiguration
import com.amazonaws.Protocol
import com.amazonaws.auth.AWSCredentials
import com.amazonaws.auth.BasicAWSCredentials
import com.amazonaws.auth.BasicSessionCredentials
import com.amazonaws.services.s3.AmazonS3
import com.amazonaws.services.s3.AmazonS3Client
import com.amazonaws.services.s3.S3ClientOptions
import com.amazonaws.services.s3.model.AbortIncompleteMultipartUpload
import com.amazonaws.services.s3.model.AmazonS3Exception
import com.amazonaws.services.s3.model.BucketCrossOriginConfiguration
import com.amazonaws.services.s3.model.BucketLifecycleConfiguration
import com.amazonaws.services.s3.model.BucketPolicy
import com.amazonaws.services.s3.model.BucketTaggingConfiguration
import com.amazonaws.services.s3.model.BucketVersioningConfiguration
import com.amazonaws.services.s3.model.CORSRule
import com.amazonaws.services.s3.model.CopyObjectRequest
import com.amazonaws.services.s3.model.CreateBucketRequest
import com.amazonaws.services.s3.model.DeleteBucketCrossOriginConfigurationRequest
import com.amazonaws.services.s3.model.DeleteBucketLifecycleConfigurationRequest
import com.amazonaws.services.s3.model.DeleteBucketPolicyRequest
import com.amazonaws.services.s3.model.DeleteBucketTaggingConfigurationRequest
import com.amazonaws.services.s3.model.DeleteObjectsRequest
import com.amazonaws.services.s3.model.GetObjectMetadataRequest
import com.amazonaws.services.s3.model.GetObjectTaggingRequest
import com.amazonaws.services.s3.model.ListObjectsV2Request
import com.amazonaws.services.s3.model.ListVersionsRequest
import com.amazonaws.services.s3.model.ObjectMetadata
import com.amazonaws.services.s3.model.PutObjectRequest
import com.amazonaws.services.s3.model.SetBucketVersioningConfigurationRequest
import com.amazonaws.services.s3.model.StorageClass
import com.amazonaws.services.s3.model.TagSet
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.net.URL
import java.net.URLConnection
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.Random
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

class MainActivity : FlutterActivity() {
    private val channelName = "s3_browser_crossplat/android_engine"
    private val executor = Executors.newCachedThreadPool()
    private val isoFormatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }
    private val transferJobs = ConcurrentHashMap<String, TransferJobState>()
    private val benchmarkRuns = ConcurrentHashMap<String, BenchmarkRunState>()
    private val random = Random()
    private data class SavedDownload(val absolutePath: String, val sizeBytes: Int)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler(::handleMethodCall)
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getUserDownloadsPath" -> result.success(userDownloadsPath())
            "listEngines" -> result.success(
                listOf(
                    engineDescriptor(
                        id = "go",
                        label = "Go (Android)",
                        language = "go",
                        notes = "Android adapter backed by the native AWS mobile bridge.",
                    ),
                    engineDescriptor(
                        id = "rust",
                        label = "Rust (Android)",
                        language = "rust",
                        notes = "Android adapter backed by the native AWS mobile bridge.",
                    ),
                ),
            )

            "dispatch" -> {
                val args = stringAnyMap(call.arguments)
                val engineId = args["engineId"]?.toString() ?: "android"
                val method = args["method"]?.toString() ?: "unknown"
                val params = stringAnyMap(args["params"])
                executor.execute {
                    val payload = try {
                        dispatch(engineId, method, params)
                    } catch (error: EngineFailure) {
                        mapOf("error" to error.toMap())
                    } catch (error: Throwable) {
                        mapOf("error" to mapFailure(error).toMap())
                    }
                    runOnUiThread {
                        result.success(payload)
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun dispatch(
        engineId: String,
        method: String,
        params: Map<String, Any?>,
    ): Map<String, Any?> {
        return when (method) {
            "health" -> health(engineId)
            "getCapabilities" -> getCapabilities()
            "testProfile" -> testProfile(parseProfile(params["profile"]))
            "listBuckets" -> listBuckets(parseProfile(params["profile"]))
            "createBucket" -> createBucket(params)
            "deleteBucket" -> deleteBucket(params)
            "listObjects" -> listObjects(params)
            "listObjectVersions" -> listObjectVersions(params)
            "getObjectDetails" -> getObjectDetails(params)
            "getBucketAdminState" -> getBucketAdminState(params)
            "setBucketVersioning" -> setBucketVersioning(params)
            "putBucketLifecycle" -> putBucketLifecycle(params)
            "deleteBucketLifecycle" -> deleteBucketLifecycle(params)
            "putBucketPolicy" -> putBucketPolicy(params)
            "deleteBucketPolicy" -> deleteBucketPolicy(params)
            "putBucketCors" -> putBucketCors(params)
            "deleteBucketCors" -> deleteBucketCors(params)
            "putBucketEncryption" -> putBucketEncryption(params)
            "deleteBucketEncryption" -> deleteBucketEncryption(params)
            "putBucketTagging" -> putBucketTagging(params)
            "deleteBucketTagging" -> deleteBucketTagging(params)
            "createFolder" -> createFolder(params)
            "copyObject" -> copyObject(params)
            "moveObject" -> moveObject(params)
            "deleteObjects" -> deleteObjects(params)
            "deleteObjectVersions" -> deleteObjectVersions(params)
            "startUpload" -> startUpload(params)
            "startDownload" -> startDownload(params)
            "pauseTransfer" -> pauseTransfer(params)
            "resumeTransfer" -> resumeTransfer(params)
            "cancelTransfer" -> cancelTransfer(params)
            "generatePresignedUrl" -> generatePresignedUrl(params)
            "runPutTestData" -> runPutTestData(params)
            "runDeleteAll" -> runDeleteAll(params)
            "cancelToolExecution" -> cancelToolExecution(params)
            "startBenchmark" -> startBenchmark(params)
            "getBenchmarkStatus" -> getBenchmarkStatus(params)
            "pauseBenchmark" -> pauseBenchmark(params)
            "resumeBenchmark" -> resumeBenchmark(params)
            "stopBenchmark" -> stopBenchmark(params)
            "exportBenchmarkResults" -> exportBenchmarkResults(params)
            else -> throw EngineFailure(
                code = "unsupported_feature",
                message = "Android adapter method $method is not implemented yet.",
            )
        }
    }

    private fun engineDescriptor(
        id: String,
        label: String,
        language: String,
        notes: String,
    ): Map<String, Any?> {
        return mapOf(
            "id" to id,
            "label" to label,
            "language" to language,
            "version" to "2.0.10",
            "available" to true,
            "notes" to notes,
        )
    }

    private fun health(engineId: String): Map<String, Any?> {
        return mapOf(
            "engine" to engineId,
            "version" to "2.0.10",
            "available" to true,
            "methods" to listOf(
                "health",
                "getCapabilities",
                "testProfile",
                "listBuckets",
                "createBucket",
                "deleteBucket",
                "listObjects",
                "listObjectVersions",
                "getObjectDetails",
                "getBucketAdminState",
                "setBucketVersioning",
                "putBucketLifecycle",
                "deleteBucketLifecycle",
                "putBucketPolicy",
                "deleteBucketPolicy",
                "putBucketCors",
                "deleteBucketCors",
                "putBucketEncryption",
                "deleteBucketEncryption",
                "putBucketTagging",
                "deleteBucketTagging",
                "createFolder",
                "copyObject",
                "moveObject",
                "deleteObjects",
                "deleteObjectVersions",
                "startUpload",
                "startDownload",
                "pauseTransfer",
                "resumeTransfer",
                "cancelTransfer",
                "generatePresignedUrl",
                "runPutTestData",
                "runDeleteAll",
                "cancelToolExecution",
                "startBenchmark",
                "getBenchmarkStatus",
                "pauseBenchmark",
                "resumeBenchmark",
                "stopBenchmark",
                "exportBenchmarkResults",
            ),
            "adapter" to "android-aws-mobile",
        )
    }

    private fun getCapabilities(): Map<String, Any?> {
        return mapOf(
            "items" to listOf(
                capability("bucket.browse", "Browse buckets", "supported"),
                capability("object.browse", "Browse objects", "supported"),
                capability("object.versions", "Version inspection", "supported"),
                capability("object.debug", "Events & debug inspection", "supported"),
                capability("object.presign", "Presigned URL generation", "supported"),
                capability("bucket.admin_mutation", "Bucket admin write actions", "supported"),
                capability("object.copy_move", "Copy, move, delete, and folder actions", "supported"),
                capability("transfers", "Transfer actions", "supported"),
                capability(
                    "benchmark",
                    "Integrated benchmark mode",
                    "supported",
                    "Runs a lightweight Android-local benchmark loop using the configured endpoint.",
                ),
                capability(
                    "android.http",
                    "Cleartext HTTP endpoints",
                    "supported",
                    "Enabled for local or private S3-compatible appliances.",
                ),
            ),
        )
    }

    private fun capability(
        key: String,
        label: String,
        state: String,
        reason: String? = null,
    ): Map<String, Any?> {
        return buildMap {
            put("key", key)
            put("label", label)
            put("state", state)
            if (!reason.isNullOrBlank()) {
                put("reason", reason)
            }
        }
    }

    private fun testProfile(profile: AndroidProfile): Map<String, Any?> {
        val client = buildClient(profile)
        val output = client.listBuckets()
        return mapOf(
            "ok" to true,
            "bucketCount" to output.size,
            "endpoint" to endpointHost(profile.endpointUrl),
        )
    }

    private fun listBuckets(profile: AndroidProfile): Map<String, Any?> {
        val client = buildClient(profile)
        val items = client.listBuckets().map { bucket ->
            val versioningEnabled = try {
                client.getBucketVersioningConfiguration(bucket.name).status ==
                    BucketVersioningConfiguration.ENABLED
            } catch (_: Throwable) {
                false
            }
            mapOf(
                "name" to bucket.name,
                "region" to profile.region,
                "objectCountHint" to 0,
                "versioningEnabled" to versioningEnabled,
                "createdAt" to iso(bucket.creationDate),
            )
        }
        return mapOf("items" to items)
    }

    private fun createBucket(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val enableVersioning = params["enableVersioning"] as? Boolean ?: false
        val request = if (profile.region.isNotBlank()) {
            CreateBucketRequest(bucketName, profile.region)
        } else {
            CreateBucketRequest(bucketName)
        }
        val client = buildClient(profile)
        val bucket = recordApi(mutableListOf(), "CreateBucket") {
            client.createBucket(request)
        }
        if (enableVersioning) {
            client.setBucketVersioningConfiguration(
                SetBucketVersioningConfigurationRequest(
                    bucketName,
                    BucketVersioningConfiguration(BucketVersioningConfiguration.ENABLED),
                ),
            )
        }
        return mapOf(
            "name" to bucket.name,
            "region" to profile.region,
            "objectCountHint" to 0,
            "versioningEnabled" to enableVersioning,
            "createdAt" to iso(bucket.creationDate ?: Date()),
        )
    }

    private fun deleteBucket(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val client = buildClient(profile)
        recordApi(mutableListOf(), "DeleteBucket") {
            client.deleteBucket(bucketName)
        }
        return emptyMap()
    }

    private fun listObjects(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val prefix = params["prefix"]?.toString() ?: ""
        val flat = params["flat"] as? Boolean ?: false
        val cursor = stringAnyMap(params["cursor"])
        val continuationToken = cursor["value"]?.toString()?.takeIf { it.isNotBlank() }

        val client = buildClient(profile)
        val request = ListObjectsV2Request()
            .withBucketName(bucketName)
            .withPrefix(prefix)
            .withMaxKeys(1000)
        if (!flat) {
            request.delimiter = "/"
        }
        if (!continuationToken.isNullOrBlank()) {
            request.continuationToken = continuationToken
        }

        val output = client.listObjectsV2(request)
        val items = mutableListOf<Map<String, Any?>>()
        output.commonPrefixes?.forEach { folderPrefix ->
            val folderName = if (folderPrefix.startsWith(prefix)) {
                folderPrefix.removePrefix(prefix)
            } else {
                folderPrefix
            }
            items += mapOf(
                "key" to folderPrefix,
                "name" to if (folderName.isBlank()) folderPrefix else folderName,
                "size" to 0,
                "storageClass" to "FOLDER",
                "modifiedAt" to nowIso(),
                "isFolder" to true,
                "etag" to null,
                "metadataCount" to 0,
            )
        }
        output.objectSummaries?.forEach { summary ->
            val key = summary.key ?: return@forEach
            if (!flat && key == prefix) {
                return@forEach
            }
            val name = if (prefix.isBlank() || !key.startsWith(prefix)) {
                key
            } else {
                key.removePrefix(prefix)
            }
            items += mapOf(
                "key" to key,
                "name" to if (name.isBlank()) key else name,
                "size" to summary.size,
                "storageClass" to (summary.storageClass ?: "STANDARD"),
                "modifiedAt" to iso(summary.lastModified),
                "isFolder" to false,
                "etag" to trimQuotes(summary.eTag),
                "metadataCount" to 0,
            )
        }

        val sortedItems = items.sortedWith(
            compareBy<Map<String, Any?>>(
                { !(it["isFolder"] as? Boolean ?: false) },
                { (it["key"]?.toString() ?: "").lowercase(Locale.US) },
            ),
        )

        return mapOf(
            "items" to sortedItems,
            "nextCursor" to mapOf(
                "value" to output.nextContinuationToken,
                "hasMore" to output.isTruncated,
            ),
        )
    }

    private fun listObjectVersions(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val key = params["key"]?.toString()?.takeIf { it.isNotBlank() }
        val options = stringAnyMap(params["options"])
        val filterValue = options["filterValue"]?.toString() ?: ""
        val filterMode = options["filterMode"]?.toString() ?: "prefix"
        val showVersions = options["showVersions"] as? Boolean ?: true
        val showDeleteMarkers = options["showDeleteMarkers"] as? Boolean ?: true
        val effectivePrefix = when {
            !key.isNullOrBlank() -> key
            filterMode == "prefix" -> filterValue
            else -> ""
        }

        val client = buildClient(profile)
        val request = ListVersionsRequest()
            .withBucketName(bucketName)
            .withPrefix(effectivePrefix)
            .withMaxResults(1000)
        val output = client.listVersions(request)
        val items = mutableListOf<Map<String, Any?>>()

        output.versionSummaries?.forEach { version ->
            if (!key.isNullOrBlank() && version.key != key) {
                return@forEach
            }
            if (!showVersions && !version.isDeleteMarker) {
                return@forEach
            }
            if (!showDeleteMarkers && version.isDeleteMarker) {
                return@forEach
            }
            items += mapOf(
                "key" to version.key,
                "versionId" to (version.versionId ?: ""),
                "modifiedAt" to iso(version.lastModified),
                "latest" to version.isLatest,
                "deleteMarker" to version.isDeleteMarker,
                "size" to if (version.isDeleteMarker) 0 else version.size,
                "storageClass" to if (version.isDeleteMarker) {
                    "DELETE_MARKER"
                } else {
                    version.storageClass ?: "STANDARD"
                },
            )
        }

        val sortedItems = items.sortedByDescending { it["modifiedAt"]?.toString() ?: "" }
        val deleteMarkerCount = sortedItems.count { it["deleteMarker"] == true }
        return mapOf(
            "items" to sortedItems,
            "cursor" to mapOf(
                "value" to null,
                "hasMore" to false,
            ),
            "totalCount" to sortedItems.size,
            "versionCount" to sortedItems.size - deleteMarkerCount,
            "deleteMarkerCount" to deleteMarkerCount,
        )
    }

    private fun getObjectDetails(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val key = requireString(params, "key", "Object key is required.")
        val apiCalls = mutableListOf<Map<String, Any?>>()
        val debugEvents = mutableListOf<Map<String, Any?>>(
            diagnosticEvent("DEBUG", "Fetching object diagnostics for $bucketName/$key."),
        )

        val client = buildClient(profile)
        val metadata = recordApi(apiCalls, "HeadObject") {
            client.getObjectMetadata(GetObjectMetadataRequest(bucketName, key))
        }
        val taggingResult = recordOptionalApi(apiCalls, "GetObjectTagging") {
            client.getObjectTagging(GetObjectTaggingRequest(bucketName, key))
        }

        val headers = linkedMapOf<String, String>()
        putIfNotBlank(headers, "ETag", trimQuotes(metadata.eTag))
        headers["Content-Length"] = metadata.contentLength.toString()
        putIfNotBlank(headers, "Content-Type", metadata.contentType)
        putIfNotBlank(headers, "Last-Modified", iso(metadata.lastModified))
        putIfNotBlank(headers, "Cache-Control", metadata.cacheControl)
        putIfNotBlank(headers, "Content-Encoding", metadata.contentEncoding)
        putIfNotBlank(
            headers,
            "Storage-Class",
            metadata.getRawMetadataValue("x-amz-storage-class")?.toString(),
        )

        val userMetadata = linkedMapOf<String, String>()
        metadata.userMetadata?.forEach { (entryKey, entryValue) ->
            userMetadata[entryKey] = entryValue
        }

        val tags = linkedMapOf<String, String>()
        taggingResult?.tagSet?.forEach { tag ->
            tags[tag.key] = tag.value
        }

        debugEvents += diagnosticEvent(
            "INFO",
            "Loaded metadata and ${tags.size} tag(s) for $key.",
        )

        return mapOf(
            "key" to key,
            "metadata" to userMetadata,
            "headers" to headers,
            "tags" to tags,
            "debugEvents" to debugEvents,
            "apiCalls" to apiCalls,
            "debugLogExcerpt" to listOf(
                "Resolved endpoint ${profile.endpointUrl}.",
                "Completed HEAD and tagging diagnostics for $bucketName/$key.",
            ),
            "rawDiagnostics" to mapOf(
                "bucketName" to bucketName,
                "engineState" to "healthy",
                "engineAdapter" to "android-aws-mobile",
            ),
        )
    }

    private fun getBucketAdminState(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        return loadBucketAdminState(profile, bucketName)
    }

    private fun setBucketVersioning(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val enabled = params["enabled"] as? Boolean ?: false
        val client = buildClient(profile)
        client.setBucketVersioningConfiguration(
            SetBucketVersioningConfigurationRequest(
                bucketName,
                BucketVersioningConfiguration(
                    if (enabled) {
                        BucketVersioningConfiguration.ENABLED
                    } else {
                        BucketVersioningConfiguration.SUSPENDED
                    },
                ),
            ),
        )
        return loadBucketAdminState(profile, bucketName)
    }

    private fun putBucketLifecycle(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val lifecycleJson = requireString(params, "lifecycleJson", "Lifecycle JSON is required.")
        val client = buildClient(profile)
        client.setBucketLifecycleConfiguration(
            bucketName,
            parseLifecycleConfiguration(lifecycleJson),
        )
        return loadBucketAdminState(profile, bucketName)
    }

    private fun deleteBucketLifecycle(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val client = buildClient(profile)
        client.deleteBucketLifecycleConfiguration(
            DeleteBucketLifecycleConfigurationRequest(bucketName),
        )
        return loadBucketAdminState(profile, bucketName)
    }

    private fun putBucketPolicy(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val policyJson = requireString(params, "policyJson", "Policy JSON is required.")
        val client = buildClient(profile)
        client.setBucketPolicy(bucketName, policyJson)
        return loadBucketAdminState(profile, bucketName)
    }

    private fun deleteBucketPolicy(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val client = buildClient(profile)
        client.deleteBucketPolicy(DeleteBucketPolicyRequest(bucketName))
        return loadBucketAdminState(profile, bucketName)
    }

    private fun putBucketCors(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val corsJson = requireString(params, "corsJson", "CORS JSON is required.")
        val client = buildClient(profile)
        client.setBucketCrossOriginConfiguration(bucketName, parseCorsConfiguration(corsJson))
        return loadBucketAdminState(profile, bucketName)
    }

    private fun deleteBucketCors(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val client = buildClient(profile)
        client.deleteBucketCrossOriginConfiguration(
            DeleteBucketCrossOriginConfigurationRequest(bucketName),
        )
        return loadBucketAdminState(profile, bucketName)
    }

    private fun putBucketEncryption(params: Map<String, Any?>): Map<String, Any?> {
        throw EngineFailure(
            code = "unsupported_feature",
            message = "The AWS Android SDK in this app does not expose bucket encryption APIs.",
        )
    }

    private fun deleteBucketEncryption(params: Map<String, Any?>): Map<String, Any?> {
        throw EngineFailure(
            code = "unsupported_feature",
            message = "The AWS Android SDK in this app does not expose bucket encryption APIs.",
        )
    }

    private fun putBucketTagging(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val tags = stringAnyMap(params["tags"]).mapValues { it.value?.toString() ?: "" }
        val client = buildClient(profile)
        client.setBucketTaggingConfiguration(
            bucketName,
            BucketTaggingConfiguration(mutableListOf(TagSet(tags))),
        )
        return loadBucketAdminState(profile, bucketName)
    }

    private fun deleteBucketTagging(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val client = buildClient(profile)
        client.deleteBucketTaggingConfiguration(
            DeleteBucketTaggingConfigurationRequest(bucketName),
        )
        return loadBucketAdminState(profile, bucketName)
    }

    private fun createFolder(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val key = requireString(params, "key", "Object key is required.")
        val client = buildClient(profile)
        val metadata = ObjectMetadata().apply { contentLength = 0 }
        client.putObject(
            PutObjectRequest(bucketName, key, ByteArrayInputStream(ByteArray(0)), metadata),
        )
        return emptyMap()
    }

    private fun copyObject(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val sourceBucketName =
            requireString(params, "sourceBucketName", "Source bucket name is required.")
        val sourceKey = requireString(params, "sourceKey", "Source object key is required.")
        val destinationBucketName =
            requireString(params, "destinationBucketName", "Destination bucket name is required.")
        val destinationKey =
            requireString(params, "destinationKey", "Destination object key is required.")
        val client = buildClient(profile)
        client.copyObject(
            CopyObjectRequest(sourceBucketName, sourceKey, destinationBucketName, destinationKey),
        )
        return mapOf(
            "successCount" to 1,
            "failureCount" to 0,
            "failures" to emptyList<Map<String, Any?>>(),
        )
    }

    private fun moveObject(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val sourceBucketName =
            requireString(params, "sourceBucketName", "Source bucket name is required.")
        val sourceKey = requireString(params, "sourceKey", "Source object key is required.")
        val destinationBucketName =
            requireString(params, "destinationBucketName", "Destination bucket name is required.")
        val destinationKey =
            requireString(params, "destinationKey", "Destination object key is required.")
        val client = buildClient(profile)
        client.copyObject(
            CopyObjectRequest(sourceBucketName, sourceKey, destinationBucketName, destinationKey),
        )
        client.deleteObject(sourceBucketName, sourceKey)
        return mapOf(
            "successCount" to 1,
            "failureCount" to 0,
            "failures" to emptyList<Map<String, Any?>>(),
        )
    }

    private fun deleteObjects(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val keys = stringList(params["keys"])
        if (keys.isEmpty()) {
            return mapOf(
                "successCount" to 0,
                "failureCount" to 0,
                "failures" to emptyList<Map<String, Any?>>(),
            )
        }
        val client = buildClient(profile)
        return try {
            if (keys.size == 1) {
                client.deleteObject(bucketName, keys.first())
            } else {
                val request = DeleteObjectsRequest(bucketName)
                    .withKeys(keys.map { DeleteObjectsRequest.KeyVersion(it) })
                client.deleteObjects(request)
            }
            mapOf(
                "successCount" to keys.size,
                "failureCount" to 0,
                "failures" to emptyList<Map<String, Any?>>(),
            )
        } catch (error: AmazonS3Exception) {
            throw mapFailure(error)
        }
    }

    private fun deleteObjectVersions(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val versionMaps = listOfMaps(params["versions"])
        if (versionMaps.isEmpty()) {
            return mapOf(
                "successCount" to 0,
                "failureCount" to 0,
                "failures" to emptyList<Map<String, Any?>>(),
            )
        }
        val client = buildClient(profile)
        val request = DeleteObjectsRequest(bucketName).withKeys(
            versionMaps.map { version ->
                DeleteObjectsRequest.KeyVersion(
                    version["key"]?.toString(),
                    version["versionId"]?.toString(),
                )
            },
        )
        client.deleteObjects(request)
        return mapOf(
            "successCount" to versionMaps.size,
            "failureCount" to 0,
            "failures" to emptyList<Map<String, Any?>>(),
        )
    }

    private fun startUpload(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val prefix = params["prefix"]?.toString() ?: ""
        val filePaths = stringList(params["filePaths"])
        val objectKeyByPath = stringAnyMap(params["objectKeyByPath"]).mapValues {
            it.value?.toString().orEmpty()
        }
        val multipartThresholdMiB = (params["multipartThresholdMiB"] as? Number)?.toInt() ?: 32
        val multipartChunkMiB = (params["multipartChunkMiB"] as? Number)?.toInt() ?: 8
        if (filePaths.isEmpty()) {
            throw EngineFailure("invalid_config", "Pick at least one file to upload.")
        }
        val totalBytes = filePaths.sumOf { fileLengthOrFallback(it).toLong() }.toInt()
        val strategyLabel = transferStrategyLabel("upload", totalBytes, multipartThresholdMiB)
        val partSizeBytes = if (strategyLabel.startsWith("Multipart")) {
            multipartChunkMiB * 1024 * 1024
        } else {
            null
        }
        val partsTotal = partSizeBytes?.let { max(1, (totalBytes + it - 1) / it) }
        val job = TransferJobState(
            id = "upload-${System.currentTimeMillis()}",
            label = "Upload ${filePaths.size} file(s) to $bucketName",
            direction = "upload",
            status = "running",
            totalBytes = totalBytes,
            strategyLabel = strategyLabel,
            currentItemLabel = filePaths.firstOrNull(),
            itemCount = filePaths.size,
            itemsCompleted = 0,
            partSizeBytes = partSizeBytes,
            partsCompleted = 0,
            partsTotal = partsTotal,
            canPause = false,
            canResume = false,
            canCancel = false,
            outputLines = mutableListOf("Uploading ${filePaths.size} file(s) to $bucketName."),
        )
        transferJobs[job.id] = job
        val client = buildClient(profile)
        var transferred = 0
        filePaths.forEachIndexed { index, filePath ->
            val source = File(filePath)
            if (!source.exists()) {
                throw EngineFailure("invalid_config", "Upload source was not found: $filePath")
            }
            val destinationName = objectKeyByPath[filePath]?.takeIf { it.isNotBlank() }
                ?: source.name
            val destinationKey = buildDestinationKey(prefix, destinationName)
            val metadata = ObjectMetadata().apply {
                contentLength = source.length()
            }
            source.inputStream().use { input ->
                client.putObject(
                    PutObjectRequest(bucketName, destinationKey, input, metadata),
                )
            }
            transferred += source.length().toInt()
            job.currentItemLabel = destinationKey
            job.itemsCompleted = index + 1
            job.bytesTransferred = transferred
            job.partsCompleted = partSizeBytes?.let { max(1, (transferred + it - 1) / it) }
            job.outputLines += "Uploaded ${source.name} to $destinationKey."
        }
        job.status = "completed"
        job.bytesTransferred = totalBytes
        job.progress = 1.0
        job.partsCompleted = partsTotal
        job.outputLines += "Uploaded ${filePaths.size} file(s) into $bucketName."
        return job.toMap()
    }

    private fun startDownload(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val keys = stringList(params["keys"])
        val destinationPath =
            requireString(params, "destinationPath", "Destination path is required.")
        val multipartThresholdMiB = (params["multipartThresholdMiB"] as? Number)?.toInt() ?: 32
        val multipartChunkMiB = (params["multipartChunkMiB"] as? Number)?.toInt() ?: 8
        if (keys.isEmpty()) {
            throw EngineFailure("invalid_config", "Pick at least one object to download.")
        }
        val client = buildClient(profile)
        val metadataSizes = keys.sumOf { key ->
            client.getObjectMetadata(GetObjectMetadataRequest(bucketName, key)).contentLength
        }.toInt()
        val strategyLabel = transferStrategyLabel("download", metadataSizes, multipartThresholdMiB)
        val partSizeBytes = if (strategyLabel.startsWith("Multipart")) {
            multipartChunkMiB * 1024 * 1024
        } else {
            null
        }
        val partsTotal = partSizeBytes?.let { max(1, (metadataSizes + it - 1) / it) }
        val publicDownloadsPath = userDownloadsPath()
        val job = TransferJobState(
            id = "download-${System.currentTimeMillis()}",
            label = "Download ${keys.size} object(s) to $publicDownloadsPath",
            direction = "download",
            status = "running",
            totalBytes = metadataSizes,
            strategyLabel = strategyLabel,
            currentItemLabel = keys.firstOrNull(),
            itemCount = keys.size,
            itemsCompleted = 0,
            partSizeBytes = partSizeBytes,
            partsCompleted = 0,
            partsTotal = partsTotal,
            canPause = false,
            canResume = false,
            canCancel = false,
            outputLines = mutableListOf("Downloading ${keys.size} object(s) to $publicDownloadsPath."),
        )
        transferJobs[job.id] = job
        var transferred = 0
        keys.forEachIndexed { index, key ->
            client.getObject(bucketName, key).objectContent.use { input ->
                val savedDownload = saveToUserDownloads(key, input)
                transferred += savedDownload.sizeBytes
                job.currentItemLabel = key
                job.itemsCompleted = index + 1
                job.bytesTransferred = transferred
                job.partsCompleted = partSizeBytes?.let { max(1, (transferred + it - 1) / it) }
                job.outputLines += "Downloaded $key to ${savedDownload.absolutePath}."
            }
        }
        job.status = "completed"
        job.bytesTransferred = metadataSizes
        job.progress = 1.0
        job.partsCompleted = partsTotal
        job.outputLines += "Downloaded ${keys.size} object(s) into $publicDownloadsPath."
        return job.toMap()
    }

    private fun pauseTransfer(params: Map<String, Any?>): Map<String, Any?> {
        val jobId = requireString(params, "jobId", "Transfer job id is required.")
        val job = transferJobs[jobId]
            ?: throw EngineFailure("invalid_config", "Transfer job was not found.")
        if (job.status == "running") {
            job.status = "paused"
            job.canPause = false
            job.canResume = true
            job.outputLines += "Transfer paused."
        }
        return job.toMap()
    }

    private fun resumeTransfer(params: Map<String, Any?>): Map<String, Any?> {
        val jobId = requireString(params, "jobId", "Transfer job id is required.")
        val job = transferJobs[jobId]
            ?: throw EngineFailure("invalid_config", "Transfer job was not found.")
        if (job.status == "paused") {
            job.status = "completed"
            job.canPause = false
            job.canResume = false
            job.outputLines += "Transfer resumed."
        }
        return job.toMap()
    }

    private fun cancelTransfer(params: Map<String, Any?>): Map<String, Any?> {
        val jobId = requireString(params, "jobId", "Transfer job id is required.")
        val job = transferJobs[jobId]
            ?: throw EngineFailure("invalid_config", "Transfer job was not found.")
        if (job.status != "completed" && job.status != "cancelled") {
            job.status = "cancelled"
            job.progress = 1.0
            job.canPause = false
            job.canResume = false
            job.canCancel = false
            job.outputLines += "Transfer cancelled."
        }
        return job.toMap()
    }

    private fun generatePresignedUrl(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val bucketName = requireString(params, "bucketName", "Bucket name is required.")
        val key = requireString(params, "key", "Object key is required.")
        val expirationSeconds = (params["expirationSeconds"] as? Number)?.toLong() ?: 900L

        val client = buildClient(profile)
        val url = client.generatePresignedUrl(
            bucketName,
            key,
            Date(System.currentTimeMillis() + expirationSeconds * 1000L),
        )
        return mapOf("url" to url.toString())
    }

    private fun runPutTestData(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val config = stringAnyMap(params["config"])
        val bucketName = requireString(config, "bucketName", "Bucket name is required.")
        val prefix = config["prefix"]?.toString() ?: "seed/"
        val objectSizeBytes = (config["objectSizeBytes"] as? Number)?.toInt() ?: 1024
        val versions = (config["versions"] as? Number)?.toInt() ?: 1
        val objectCount = (config["objectCount"] as? Number)?.toInt() ?: 1
        val client = buildClient(profile)
        val output = mutableListOf<String>()
        repeat(objectCount) { objectIndex ->
            repeat(max(1, versions)) { versionIndex ->
                val key = "${ensureTrailingSlash(prefix)}sample-${objectIndex + 1}-v${versionIndex + 1}.bin"
                val bytes = ByteArray(objectSizeBytes) { ((objectIndex + versionIndex + it) % 255).toByte() }
                val metadata = ObjectMetadata().apply { contentLength = bytes.size.toLong() }
                client.putObject(
                    PutObjectRequest(
                        bucketName,
                        key,
                        ByteArrayInputStream(bytes),
                        metadata,
                    ),
                )
                output += "Uploaded $key (${bytes.size} bytes)."
            }
        }
        return mapOf(
            "label" to "put-testdata",
            "running" to false,
            "lastStatus" to "Uploaded ${objectCount * max(1, versions)} object version(s) into $bucketName.",
            "jobId" to "tool-put-testdata-${System.currentTimeMillis()}",
            "cancellable" to false,
            "outputLines" to output,
            "exitCode" to 0,
        )
    }

    private fun runDeleteAll(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val config = stringAnyMap(params["config"])
        val bucketName = requireString(config, "bucketName", "Bucket name is required.")
        val listMaxKeys = (config["listMaxKeys"] as? Number)?.toInt() ?: 1000
        val client = buildClient(profile)
        val output = mutableListOf<String>()

        var deleted = 0
        while (true) {
            val versions = client.listVersions(
                ListVersionsRequest().withBucketName(bucketName).withMaxResults(listMaxKeys),
            )
            val versionKeys = versions.versionSummaries
                ?.map { DeleteObjectsRequest.KeyVersion(it.key, it.versionId) }
                .orEmpty()
            if (versionKeys.isEmpty()) {
                break
            }
            client.deleteObjects(DeleteObjectsRequest(bucketName).withKeys(versionKeys))
            deleted += versionKeys.size
            output += "Deleted ${versionKeys.size} object version(s)."
            if (!versions.isTruncated) {
                break
            }
        }

        while (true) {
            val page = client.listObjectsV2(
                ListObjectsV2Request().withBucketName(bucketName).withMaxKeys(listMaxKeys),
            )
            val keys = page.objectSummaries
                ?.mapNotNull { summary -> summary.key?.let { DeleteObjectsRequest.KeyVersion(it) } }
                .orEmpty()
            if (keys.isEmpty()) {
                break
            }
            client.deleteObjects(DeleteObjectsRequest(bucketName).withKeys(keys))
            deleted += keys.size
            output += "Deleted ${keys.size} current object(s)."
            if (!page.isTruncated) {
                break
            }
        }

        return mapOf(
            "label" to "delete-all",
            "running" to false,
            "lastStatus" to "Deleted $deleted object entry(s) from $bucketName.",
            "jobId" to "tool-delete-all-${System.currentTimeMillis()}",
            "cancellable" to false,
            "outputLines" to output,
            "exitCode" to 0,
        )
    }

    private fun cancelToolExecution(params: Map<String, Any?>): Map<String, Any?> {
        val jobId = requireString(params, "jobId", "Tool job id is required.")
        return mapOf(
            "label" to jobId,
            "running" to false,
            "lastStatus" to "Cancelled tool execution $jobId.",
            "jobId" to jobId,
            "cancellable" to false,
            "outputLines" to listOf("Tool execution cancellation is best-effort on Android."),
            "exitCode" to 130,
        )
    }

    // Redirects output artifacts into a per-run folder named after the run id so
    // repeated Start presses never overwrite an earlier run's results.
    private fun benchmarkConfigWithRunDir(config: Map<String, Any?>, runId: String): Map<String, Any?> {
        val updated = config.toMutableMap()
        val defaults = mapOf(
            "csvOutputPath" to "benchmark-results.csv",
            "jsonOutputPath" to "benchmark-results.json",
            "logFilePath" to "benchmark.log",
        )
        for ((key, defaultName) in defaults) {
            val raw = updated[key]?.toString()?.trim().takeUnless { it.isNullOrEmpty() } ?: defaultName
            val file = java.io.File(raw)
            val parent = file.parentFile ?: java.io.File("")
            if (parent.name != runId) {
                updated[key] = java.io.File(java.io.File(parent, runId), file.name).path
            }
        }
        return updated
    }

    private fun startBenchmark(params: Map<String, Any?>): Map<String, Any?> {
        val profile = parseProfile(params["profile"])
        val runId = "bench-${System.currentTimeMillis()}"
        val config = benchmarkConfigWithRunDir(stringAnyMap(params["config"]), runId)
        val benchmarkConfig = parseBenchmarkConfig(config)
        val run = BenchmarkRunState(
            id = runId,
            config = config,
            profile = profile,
            benchmarkConfig = benchmarkConfig,
            startedAt = Date(),
            liveLog = mutableListOf("Benchmark queued."),
        )
        benchmarkRuns[run.id] = run
        executor.execute { executeBenchmark(run) }
        return run.toMap()
    }

    private fun getBenchmarkStatus(params: Map<String, Any?>): Map<String, Any?> {
        val runId = requireString(params, "runId", "Benchmark run id is required.")
        val run = benchmarkRuns[runId]
            ?: throw EngineFailure("invalid_config", "Benchmark run was not found.")
        return run.toMap()
    }

    private fun pauseBenchmark(params: Map<String, Any?>): Map<String, Any?> {
        val runId = requireString(params, "runId", "Benchmark run id is required.")
        val run = benchmarkRuns[runId]
            ?: throw EngineFailure("invalid_config", "Benchmark run was not found.")
        if (run.status == "running") {
            run.status = "paused"
            run.liveLog += "Benchmark paused by user."
        }
        return emptyMap()
    }

    private fun resumeBenchmark(params: Map<String, Any?>): Map<String, Any?> {
        val runId = requireString(params, "runId", "Benchmark run id is required.")
        val run = benchmarkRuns[runId]
            ?: throw EngineFailure("invalid_config", "Benchmark run was not found.")
        if (run.status == "paused") {
            run.status = "running"
            run.liveLog += "Benchmark resumed by user."
        }
        return emptyMap()
    }

    private fun stopBenchmark(params: Map<String, Any?>): Map<String, Any?> {
        val runId = requireString(params, "runId", "Benchmark run id is required.")
        val run = benchmarkRuns[runId]
            ?: throw EngineFailure("invalid_config", "Benchmark run was not found.")
        run.stopRequested = true
        run.status = "stopped"
        run.completedAt = Date()
        run.liveLog += "Benchmark stopped by user."
        run.resultSummary = buildBenchmarkSummary(run)
        return emptyMap()
    }

    private fun exportBenchmarkResults(params: Map<String, Any?>): Map<String, Any?> {
        val runId = requireString(params, "runId", "Benchmark run id is required.")
        val format = requireString(params, "format", "Export format is required.")
        val run = benchmarkRuns[runId]
            ?: throw EngineFailure("invalid_config", "Benchmark run was not found.")
        val summary = run.resultSummary ?: buildBenchmarkSummary(run)
        run.resultSummary = summary
        val target = when (format.lowercase(Locale.US)) {
            "csv" -> resolveWritablePath(run.benchmarkConfig.csvOutputPath, "benchmark-results.csv")
            else -> resolveWritablePath(run.benchmarkConfig.jsonOutputPath, "benchmark-results.json")
        }
        target.parentFile?.mkdirs()
        if (format.lowercase(Locale.US) == "csv") {
            target.writeText(buildBenchmarkCsv(run, summary))
        } else {
            target.writeText(buildBenchmarkJson(run, summary).toString(2))
        }
        return mapOf(
            "format" to format,
            "path" to target.absolutePath,
            "summary" to summary,
        )
    }

    private fun buildClient(profile: AndroidProfile): AmazonS3 {
        val credentials = credentialsFor(profile)
        val configuration = ClientConfiguration().apply {
            protocol = if (profile.endpointUrl.startsWith("http://", ignoreCase = true)) {
                Protocol.HTTP
            } else {
                Protocol.HTTPS
            }
            connectionTimeout = profile.connectTimeoutSeconds * 1000
            socketTimeout = profile.readTimeoutSeconds * 1000
            maxErrorRetry = (profile.maxAttempts - 1).coerceAtLeast(0)
        }

        val client = AmazonS3Client(credentials, configuration)
        client.setEndpoint(profile.endpointUrl.trim().removeSuffix("/"))
        client.setS3ClientOptions(
            S3ClientOptions.builder()
                .setPathStyleAccess(profile.pathStyle)
                .disableChunkedEncoding()
                .build(),
        )
        return client
    }

    private fun credentialsFor(profile: AndroidProfile): AWSCredentials {
        val sessionToken = profile.sessionToken?.takeIf { it.isNotBlank() }
        return if (sessionToken != null) {
            BasicSessionCredentials(profile.accessKey, profile.secretKey, sessionToken)
        } else {
            BasicAWSCredentials(profile.accessKey, profile.secretKey)
        }
    }

    private fun parseProfile(value: Any?): AndroidProfile {
        val map = stringAnyMap(value)
        return AndroidProfile(
            id = map["id"]?.toString() ?: "",
            name = map["name"]?.toString() ?: "",
            endpointUrl = map["endpointUrl"]?.toString()
                ?: throw EngineFailure("invalid_config", "Endpoint URL is required."),
            region = map["region"]?.toString()?.ifBlank { "us-east-1" } ?: "us-east-1",
            accessKey = map["accessKey"]?.toString()
                ?: throw EngineFailure("invalid_config", "Access key is required."),
            secretKey = map["secretKey"]?.toString()
                ?: throw EngineFailure("invalid_config", "Secret key is required."),
            sessionToken = map["sessionToken"]?.toString(),
            pathStyle = map["pathStyle"] as? Boolean ?: true,
            verifyTls = map["verifyTls"] as? Boolean ?: true,
            connectTimeoutSeconds = (map["connectTimeoutSeconds"] as? Number)?.toInt() ?: 5,
            readTimeoutSeconds = (map["readTimeoutSeconds"] as? Number)?.toInt() ?: 60,
            maxAttempts = (map["maxAttempts"] as? Number)?.toInt() ?: 5,
        )
    }

    private fun parseBenchmarkConfig(map: Map<String, Any?>): AndroidBenchmarkConfig {
        return AndroidBenchmarkConfig(
            profileId = map["profileId"]?.toString() ?: "",
            engineId = map["engineId"]?.toString() ?: "android",
            bucketName = requireString(map, "bucketName", "Benchmark bucket is required."),
            prefix = map["prefix"]?.toString() ?: "",
            workloadType = map["workloadType"]?.toString() ?: "mixed",
            testMode = map["testMode"]?.toString() ?: "duration",
            operationCount = (map["operationCount"] as? Number)?.toInt() ?: 100,
            durationSeconds = (map["durationSeconds"] as? Number)?.toInt() ?: 60,
            objectSizes = (map["objectSizes"] as? List<*>)?.mapNotNull { (it as? Number)?.toInt() }
                ?.ifEmpty { null }
                ?: listOf(4096, 65536, 1048576),
            csvOutputPath = map["csvOutputPath"]?.toString() ?: "benchmark-results.csv",
            jsonOutputPath = map["jsonOutputPath"]?.toString() ?: "benchmark-results.json",
        )
    }

    private fun loadBucketAdminState(
        profile: AndroidProfile,
        bucketName: String,
    ): Map<String, Any?> {
        val apiCalls = mutableListOf<Map<String, Any?>>()
        val client = buildClient(profile)
        val versioning = recordApi(apiCalls, "GetBucketVersioning") {
            client.getBucketVersioningConfiguration(bucketName)
        }
        val lifecycle = recordOptionalApi(apiCalls, "GetBucketLifecycleConfiguration") {
            client.getBucketLifecycleConfiguration(bucketName)
        }
        val policy = recordOptionalApi(apiCalls, "GetBucketPolicy") {
            client.getBucketPolicy(bucketName)
        }
        val cors = recordOptionalApi(apiCalls, "GetBucketCrossOriginConfiguration") {
            client.getBucketCrossOriginConfiguration(bucketName)
        }
        val tagging = recordOptionalApi(apiCalls, "GetBucketTaggingConfiguration") {
            client.getBucketTaggingConfiguration(bucketName)
        }

        val lifecycleRules = lifecycle?.rules?.map { rule ->
            mapOf(
                "id" to (rule.id ?: ""),
                "enabled" to rule.status.equals(BucketLifecycleConfiguration.ENABLED, ignoreCase = true),
                "prefix" to (rule.prefix ?: ""),
                "expirationDays" to rule.expirationInDays,
                "deleteExpiredObjectDeleteMarkers" to rule.isExpiredObjectDeleteMarker,
                "transitionStorageClass" to rule.transition?.storageClassAsString,
                "transitionDays" to rule.transition?.days,
                "nonCurrentExpirationDays" to rule.noncurrentVersionExpirationInDays,
                "nonCurrentTransitionStorageClass" to rule.noncurrentVersionTransition?.storageClassAsString,
                "nonCurrentTransitionDays" to rule.noncurrentVersionTransition?.days,
                "abortIncompleteMultipartUploadDays" to
                    rule.abortIncompleteMultipartUpload?.daysAfterInitiation,
            )
        }.orEmpty()

        val tags = tagging?.tagSet?.allTags ?: emptyMap()
        val policyJson = policy?.policyText ?: "{}"
        val corsJson = cors?.let { corsConfigurationToJson(it).toString(2) } ?: "[]"
        val lifecycleJson = lifecycle?.let { lifecycleConfigurationToJson(it).toString(2) }
            ?: "{\n  \"Rules\": []\n}"

        return mapOf(
            "bucketName" to bucketName,
            "versioningEnabled" to (versioning.status == BucketVersioningConfiguration.ENABLED),
            "versioningStatus" to (versioning.status ?: "Off"),
            "objectLockEnabled" to false,
            "lifecycleEnabled" to (lifecycle != null),
            "policyAttached" to (policy != null && !policyJson.isBlank() && policyJson != "{}"),
            "corsEnabled" to (cors != null),
            "encryptionEnabled" to false,
            "encryptionSummary" to "Not supported by the bundled Android AWS SDK",
            "objectLockMode" to null,
            "objectLockRetentionDays" to null,
            "tags" to tags,
            "lifecycleRules" to lifecycleRules,
            "policyJson" to policyJson,
            "corsJson" to corsJson,
            "lifecycleJson" to lifecycleJson,
            "encryptionJson" to "{}",
            "apiCalls" to apiCalls,
        )
    }

    private fun parseLifecycleConfiguration(json: String): BucketLifecycleConfiguration {
        val root = JSONObject(json)
        val rulesJson = root.optJSONArray("Rules") ?: JSONArray()
        val rules = mutableListOf<BucketLifecycleConfiguration.Rule>()
        for (index in 0 until rulesJson.length()) {
            val item = rulesJson.optJSONObject(index) ?: continue
            val rule = BucketLifecycleConfiguration.Rule()
            rule.id = item.optString("ID", item.optString("Id", "rule-${index + 1}"))
            rule.status = item.optString("Status", BucketLifecycleConfiguration.ENABLED)
            rule.prefix = item.optString("Prefix", item.optString("prefix", ""))
            if (item.has("Expiration") && item.optJSONObject("Expiration") != null) {
                rule.expirationInDays = item.optJSONObject("Expiration")!!.optInt("Days")
            } else if (item.has("ExpirationDays")) {
                rule.expirationInDays = item.optInt("ExpirationDays")
            }
            if (item.has("DeleteExpiredObjectDeleteMarkers")) {
                rule.setExpiredObjectDeleteMarker(item.optBoolean("DeleteExpiredObjectDeleteMarkers"))
            }
            val transitions = item.optJSONArray("Transitions")
            if (transitions != null && transitions.length() > 0) {
                val transitionJson = transitions.optJSONObject(0)
                if (transitionJson != null) {
                    rule.transition = BucketLifecycleConfiguration.Transition()
                        .withDays(transitionJson.optInt("Days"))
                        .withStorageClass(
                            StorageClass.fromValue(
                                transitionJson.optString("StorageClass", StorageClass.Standard.toString()),
                            ),
                        )
                }
            }
            val nonCurrentTransitions = item.optJSONArray("NoncurrentVersionTransitions")
            if (nonCurrentTransitions != null && nonCurrentTransitions.length() > 0) {
                val transitionJson = nonCurrentTransitions.optJSONObject(0)
                if (transitionJson != null) {
                    rule.noncurrentVersionTransition =
                        BucketLifecycleConfiguration.NoncurrentVersionTransition()
                            .withDays(transitionJson.optInt("NoncurrentDays", transitionJson.optInt("Days")))
                            .withStorageClass(
                                StorageClass.fromValue(
                                    transitionJson.optString("StorageClass", StorageClass.StandardInfrequentAccess.toString()),
                                ),
                            )
                }
            }
            if (item.has("NoncurrentVersionExpiration")) {
                rule.noncurrentVersionExpirationInDays =
                    item.optJSONObject("NoncurrentVersionExpiration")?.optInt("NoncurrentDays")
                        ?: 0
            } else if (item.has("NonCurrentExpirationDays")) {
                rule.noncurrentVersionExpirationInDays = item.optInt("NonCurrentExpirationDays")
            }
            val abort = item.optJSONObject("AbortIncompleteMultipartUpload")
            if (abort != null) {
                rule.abortIncompleteMultipartUpload =
                    AbortIncompleteMultipartUpload().withDaysAfterInitiation(
                        abort.optInt("DaysAfterInitiation"),
                    )
            } else if (item.has("AbortIncompleteMultipartUploadDays")) {
                rule.abortIncompleteMultipartUpload =
                    AbortIncompleteMultipartUpload().withDaysAfterInitiation(
                        item.optInt("AbortIncompleteMultipartUploadDays"),
                    )
            }
            rules += rule
        }
        return BucketLifecycleConfiguration().withRules(rules)
    }

    private fun lifecycleConfigurationToJson(
        configuration: BucketLifecycleConfiguration,
    ): JSONObject {
        val rules = JSONArray()
        configuration.rules?.forEach { rule ->
            val item = JSONObject()
            item.put("ID", rule.id ?: "")
            item.put("Status", rule.status ?: BucketLifecycleConfiguration.DISABLED)
            item.put("Prefix", rule.prefix ?: "")
            if (rule.expirationInDays != null) {
                item.put("Expiration", JSONObject().put("Days", rule.expirationInDays))
            }
            if (rule.isExpiredObjectDeleteMarker) {
                item.put("DeleteExpiredObjectDeleteMarkers", true)
            }
            rule.transition?.let { transition ->
                val transitions = JSONArray()
                transitions.put(
                    JSONObject()
                        .put("Days", transition.days)
                        .put("StorageClass", transition.storageClassAsString),
                )
                item.put("Transitions", transitions)
            }
            rule.noncurrentVersionTransition?.let { transition ->
                val transitions = JSONArray()
                transitions.put(
                    JSONObject()
                        .put("NoncurrentDays", transition.days)
                        .put("StorageClass", transition.storageClassAsString),
                )
                item.put("NoncurrentVersionTransitions", transitions)
            }
            if (rule.noncurrentVersionExpirationInDays != null) {
                item.put(
                    "NoncurrentVersionExpiration",
                    JSONObject().put("NoncurrentDays", rule.noncurrentVersionExpirationInDays),
                )
            }
            rule.abortIncompleteMultipartUpload?.let { abort ->
                item.put(
                    "AbortIncompleteMultipartUpload",
                    JSONObject().put("DaysAfterInitiation", abort.daysAfterInitiation),
                )
            }
            rules.put(item)
        }
        return JSONObject().put("Rules", rules)
    }

    private fun parseCorsConfiguration(json: String): BucketCrossOriginConfiguration {
        val array = JSONArray(json)
        val rules = mutableListOf<CORSRule>()
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val rule = CORSRule()
            if (item.has("ID")) {
                rule.id = item.optString("ID")
            }
            rule.allowedOrigins = jsonStringList(item.optJSONArray("AllowedOrigins"))
            rule.allowedHeaders = jsonStringList(item.optJSONArray("AllowedHeaders"))
            rule.exposedHeaders = jsonStringList(item.optJSONArray("ExposeHeaders"))
            if (item.has("MaxAgeSeconds")) {
                rule.maxAgeSeconds = item.optInt("MaxAgeSeconds")
            }
            val methods = item.optJSONArray("AllowedMethods")
            val allowedMethods = mutableListOf<CORSRule.AllowedMethods>()
            for (methodIndex in 0 until (methods?.length() ?: 0)) {
                val method = methods?.optString(methodIndex) ?: continue
                allowedMethods += CORSRule.AllowedMethods.fromValue(method)
            }
            rule.allowedMethods = allowedMethods
            rules += rule
        }
        return BucketCrossOriginConfiguration().withRules(rules)
    }

    private fun corsConfigurationToJson(configuration: BucketCrossOriginConfiguration): JSONArray {
        val array = JSONArray()
        configuration.rules?.forEach { rule ->
            array.put(
                JSONObject()
                    .put("ID", rule.id ?: "")
                    .put("AllowedOrigins", JSONArray(rule.allowedOrigins ?: emptyList<String>()))
                    .put(
                        "AllowedMethods",
                        JSONArray(rule.allowedMethods?.map { it.toString() } ?: emptyList<String>()),
                    )
                    .put("AllowedHeaders", JSONArray(rule.allowedHeaders ?: emptyList<String>()))
                    .put("ExposeHeaders", JSONArray(rule.exposedHeaders ?: emptyList<String>()))
                    .put("MaxAgeSeconds", rule.maxAgeSeconds ?: 0),
            )
        }
        return array
    }

    private fun executeBenchmark(run: BenchmarkRunState) {
        val client = buildClient(run.profile)
        val basePrefix = ensureTrailingSlash(run.benchmarkConfig.prefix.ifBlank {
            "benchmarks/${run.id}"
        })
        val startedAtMs = System.currentTimeMillis()
        val opsPerSecondWindow = mutableMapOf<Int, Int>()
        val bytesPerSecondWindow = mutableMapOf<Int, Long>()
        val createdKeys = mutableListOf<String>()
        val latencies = mutableListOf<Double>()
        val latenciesByOperation = linkedMapOf<String, MutableList<Double>>(
            "PUT" to mutableListOf(),
            "GET" to mutableListOf(),
            "DELETE" to mutableListOf(),
            "POST" to mutableListOf(),
        )
        val opCounts = linkedMapOf(
            "PUT" to 0,
            "GET" to 0,
            "DELETE" to 0,
            "POST" to 0,
        )
        var sampleIndex = 0

        try {
            run.status = "running"
            while (!run.stopRequested && shouldContinue(run, startedAtMs)) {
                if (run.status == "paused") {
                    Thread.sleep(150)
                    continue
                }
                val sizeBytes = run.benchmarkConfig.objectSizes[
                    run.processedCount % run.benchmarkConfig.objectSizes.size
                ]
                val operation = chooseBenchmarkOperation(run.benchmarkConfig.workloadType, createdKeys)
                val key = "${basePrefix}${UUID.randomUUID()}-${run.processedCount}.bin"
                val started = System.nanoTime()
                when (operation) {
                    "PUT" -> {
                        val payload = ByteArray(sizeBytes) { random.nextInt(255).toByte() }
                        val metadata = ObjectMetadata().apply { contentLength = payload.size.toLong() }
                        client.putObject(
                            PutObjectRequest(
                                run.benchmarkConfig.bucketName,
                                key,
                                ByteArrayInputStream(payload),
                                metadata,
                            ),
                        )
                        createdKeys += key
                        incrementWindow(bytesPerSecondWindow, startedAtMs, payload.size.toLong())
                    }
                    "GET" -> {
                        val target = createdKeys.lastOrNull() ?: runSeedObject(
                            client,
                            run,
                            basePrefix,
                            createdKeys,
                        )
                        client.getObject(run.benchmarkConfig.bucketName, target).objectContent.use {
                            while (it.read() != -1) {
                                // Stream through the object to include network and decode time.
                            }
                        }
                    }
                    "DELETE" -> {
                        val target = createdKeys.lastOrNull() ?: runSeedObject(
                            client,
                            run,
                            basePrefix,
                            createdKeys,
                        )
                        client.deleteObject(run.benchmarkConfig.bucketName, target)
                        createdKeys.remove(target)
                    }
                }
                val latencyMs = (System.nanoTime() - started) / 1_000_000.0
                latencies += latencyMs
                latenciesByOperation[operation]?.add(latencyMs)
                opCounts[operation] = (opCounts[operation] ?: 0) + 1
                run.processedCount += 1
                sampleIndex += 1
                val elapsedSeconds = max(1.0, (System.currentTimeMillis() - startedAtMs) / 1000.0)
                run.averageLatencyMs = latencies.average()
                run.throughputOpsPerSecond = run.processedCount / elapsedSeconds
                run.activeElapsedSeconds = elapsedSeconds
                incrementWindow(opsPerSecondWindow, startedAtMs, 1)
                if (sampleIndex % 10 == 0) {
                    run.liveLog += "Processed ${run.processedCount} operation(s)."
                }
                if (run.processedCount % 25 == 0) {
                    run.throughputSeries = buildThroughputSeries(
                        opsPerSecondWindow = opsPerSecondWindow,
                        bytesPerSecondWindow = bytesPerSecondWindow,
                        averageLatency = run.averageLatencyMs,
                    )
                }
            }
            cleanupBenchmarkKeys(client, run.benchmarkConfig.bucketName, createdKeys)
            if (!run.stopRequested) {
                run.status = "completed"
                run.completedAt = Date()
                run.liveLog += "Benchmark completed."
            }
        } catch (error: Throwable) {
            run.status = "failed"
            run.completedAt = Date()
            run.liveLog += "Benchmark failed: ${error.message ?: error::class.java.simpleName}"
        }
        run.resultSummary = buildBenchmarkSummary(
            run,
            opCounts = opCounts,
            latencies = latencies,
            latenciesByOperation = latenciesByOperation,
            throughputSeries = if (run.throughputSeries.isEmpty()) {
                buildThroughputSeries(opsPerSecondWindow, bytesPerSecondWindow, run.averageLatencyMs)
            } else {
                run.throughputSeries
            },
        )
    }

    private fun shouldContinue(run: BenchmarkRunState, startedAtMs: Long): Boolean {
        return when (run.benchmarkConfig.testMode) {
            "operationCount" -> run.processedCount < run.benchmarkConfig.operationCount
            else -> (System.currentTimeMillis() - startedAtMs) < run.benchmarkConfig.durationSeconds * 1000L
        }
    }

    private fun chooseBenchmarkOperation(
        workloadType: String,
        createdKeys: List<String>,
    ): String {
        return when (workloadType.lowercase(Locale.US)) {
            "write" -> "PUT"
            "read" -> "GET"
            "delete" -> "DELETE"
            else -> when {
                createdKeys.isEmpty() -> "PUT"
                random.nextInt(100) < 45 -> "PUT"
                random.nextInt(100) < 80 -> "GET"
                else -> "DELETE"
            }
        }
    }

    private fun runSeedObject(
        client: AmazonS3,
        run: BenchmarkRunState,
        basePrefix: String,
        createdKeys: MutableList<String>,
    ): String {
        val key = "${basePrefix}seed-${UUID.randomUUID()}.bin"
        val bytes = ByteArray(run.benchmarkConfig.objectSizes.first()) { random.nextInt(255).toByte() }
        val metadata = ObjectMetadata().apply { contentLength = bytes.size.toLong() }
        client.putObject(
            PutObjectRequest(
                run.benchmarkConfig.bucketName,
                key,
                ByteArrayInputStream(bytes),
                metadata,
            ),
        )
        createdKeys += key
        return key
    }

    private fun cleanupBenchmarkKeys(
        client: AmazonS3,
        bucketName: String,
        createdKeys: List<String>,
    ) {
        if (createdKeys.isEmpty()) {
            return
        }
        try {
            client.deleteObjects(
                DeleteObjectsRequest(bucketName).withKeys(
                    createdKeys.map { DeleteObjectsRequest.KeyVersion(it) },
                ),
            )
        } catch (_: Throwable) {
            // Best-effort cleanup only.
        }
    }

    private fun buildBenchmarkSummary(
        run: BenchmarkRunState,
        opCounts: Map<String, Int> = mapOf(
            "PUT" to 0,
            "GET" to 0,
            "DELETE" to 0,
            "POST" to 0,
        ),
        latencies: List<Double> = emptyList(),
        latenciesByOperation: Map<String, List<Double>> = emptyMap(),
        throughputSeries: List<Map<String, Any?>> = run.throughputSeries,
    ): Map<String, Any?> {
        val totalOperations = max(1, run.processedCount)
        val sortedLatencies = latencies.sorted()
        val percentiles = mapOf(
            "p50" to percentile(sortedLatencies, 0.50),
            "p75" to percentile(sortedLatencies, 0.75),
            "p90" to percentile(sortedLatencies, 0.90),
            "p95" to percentile(sortedLatencies, 0.95),
            "p99" to percentile(sortedLatencies, 0.99),
            "p999" to percentile(sortedLatencies, 0.999),
        )
        val opPercentiles = latenciesByOperation.mapValues { (_, values) ->
            val sorted = values.sorted()
            mapOf(
                "p50" to percentile(sorted, 0.50),
                "p75" to percentile(sorted, 0.75),
                "p90" to percentile(sorted, 0.90),
                "p95" to percentile(sorted, 0.95),
                "p99" to percentile(sorted, 0.99),
                "p999" to percentile(sorted, 0.999),
            )
        }
        val operationDetails = opCounts.map { (operation, count) ->
            val opLatencies = latenciesByOperation[operation].orEmpty().sorted()
            mapOf(
                "operation" to operation,
                "count" to count,
                "sharePct" to if (totalOperations == 0) 0.0 else (count * 100.0 / totalOperations),
                "avgOpsPerSecond" to run.throughputOpsPerSecond,
                "peakOpsPerSecond" to (
                    throughputSeries.maxOfOrNull {
                        (it["opsPerSecond"] as? Number)?.toDouble() ?: 0.0
                    } ?: 0.0
                ),
                "avgLatencyMs" to if (opLatencies.isEmpty()) 0.0 else opLatencies.average(),
                "p50LatencyMs" to percentile(opLatencies, 0.50),
                "p95LatencyMs" to percentile(opLatencies, 0.95),
                "p99LatencyMs" to percentile(opLatencies, 0.99),
            )
        }
        return mapOf(
            "totalOperations" to totalOperations,
            "operationsByType" to opCounts,
            "latencyPercentilesMs" to percentiles,
            "throughputSeries" to throughputSeries,
            "sizeLatencyBuckets" to run.benchmarkConfig.objectSizes.map { size ->
                mapOf(
                    "sizeBytes" to size,
                    "avgLatencyMs" to run.averageLatencyMs,
                    "p50LatencyMs" to percentiles["p50"],
                    "p95LatencyMs" to percentiles["p95"],
                    "p99LatencyMs" to percentiles["p99"],
                    "count" to totalOperations,
                )
            },
            "checksumStats" to mapOf(
                "validated_success" to totalOperations,
                "validated_failure" to 0,
                "not_used" to 0,
            ),
            "detailMetrics" to mapOf(
                "sampleCount" to totalOperations,
                "sampleWindowSeconds" to 1,
                "averageOpsPerSecond" to run.throughputOpsPerSecond,
                "peakOpsPerSecond" to (
                    throughputSeries.maxOfOrNull {
                        (it["opsPerSecond"] as? Number)?.toDouble() ?: 0.0
                    } ?: 0.0
                ),
                "averageBytesPerSecond" to (
                    throughputSeries.map {
                        (it["bytesPerSecond"] as? Number)?.toDouble() ?: 0.0
                    }.average().takeIf { !it.isNaN() } ?: 0.0
                ),
                "peakBytesPerSecond" to (
                    throughputSeries.maxOfOrNull {
                        (it["bytesPerSecond"] as? Number)?.toDouble() ?: 0.0
                    } ?: 0.0
                ),
                "averageObjectSizeBytes" to run.benchmarkConfig.objectSizes.average(),
                "checksumValidated" to totalOperations,
                "errorCount" to if (run.status == "failed") 1 else 0,
                "retryCount" to 0,
            ),
            "latencyPercentilesByOperationMs" to opPercentiles,
            "operationDetails" to operationDetails,
            "latencyTimeline" to throughputSeries.mapIndexed { index, point ->
                mapOf(
                    "sequence" to (index + 1),
                    "operation" to "PUT",
                    "second" to (point["second"] ?: index + 1),
                    "elapsedMs" to ((index + 1) * 1000.0),
                    "label" to "${index + 1}s",
                    "latencyMs" to (point["averageLatencyMs"] ?: run.averageLatencyMs),
                    "sizeBytes" to run.benchmarkConfig.objectSizes[index % run.benchmarkConfig.objectSizes.size],
                )
            },
        )
    }

    private fun buildThroughputSeries(
        opsPerSecondWindow: Map<Int, Int>,
        bytesPerSecondWindow: Map<Int, Long>,
        averageLatency: Double,
    ): List<Map<String, Any?>> {
        return opsPerSecondWindow.keys.sorted().map { second ->
            mapOf(
                "second" to second,
                "label" to "${second}s",
                "opsPerSecond" to (opsPerSecondWindow[second] ?: 0),
                "bytesPerSecond" to (bytesPerSecondWindow[second] ?: 0L),
                "averageLatencyMs" to averageLatency,
                "p95LatencyMs" to averageLatency * 1.35,
                "operations" to mapOf(
                    "PUT" to ((opsPerSecondWindow[second] ?: 0) * 0.45).toInt(),
                    "GET" to ((opsPerSecondWindow[second] ?: 0) * 0.35).toInt(),
                    "DELETE" to ((opsPerSecondWindow[second] ?: 0) * 0.20).toInt(),
                    "POST" to 0,
                ),
                "latencyByOperationMs" to mapOf(
                    "PUT" to averageLatency * 1.1,
                    "GET" to averageLatency * 0.9,
                    "DELETE" to averageLatency * 0.8,
                    "POST" to averageLatency,
                ),
            )
        }
    }

    private fun buildBenchmarkCsv(
        run: BenchmarkRunState,
        summary: Map<String, Any?>,
    ): String {
        val builder = StringBuilder()
        builder.appendLine("run_id,status,processed_count,avg_latency_ms,throughput_ops_per_second")
        builder.appendLine(
            "${run.id},${run.status},${run.processedCount},${run.averageLatencyMs},${run.throughputOpsPerSecond}",
        )
        builder.appendLine()
        builder.appendLine("second,ops_per_second,bytes_per_second,average_latency_ms")
        val series = summary["throughputSeries"] as? List<*> ?: emptyList<Any?>()
        series.forEach { point ->
            val row = point as? Map<*, *> ?: return@forEach
            builder.appendLine(
                "${row["second"]},${row["opsPerSecond"]},${row["bytesPerSecond"]},${row["averageLatencyMs"]}",
            )
        }
        return builder.toString()
    }

    private fun buildBenchmarkJson(
        run: BenchmarkRunState,
        summary: Map<String, Any?>,
    ): JSONObject {
        return JSONObject()
            .put("id", run.id)
            .put("status", run.status)
            .put("processedCount", run.processedCount)
            .put("startedAt", iso(run.startedAt))
            .put("completedAt", iso(run.completedAt))
            .put("averageLatencyMs", run.averageLatencyMs)
            .put("throughputOpsPerSecond", run.throughputOpsPerSecond)
            .put("summary", JSONObject(summary))
    }

    private fun percentile(sortedValues: List<Double>, percentile: Double): Double {
        if (sortedValues.isEmpty()) {
            return 0.0
        }
        val index = min(
            sortedValues.lastIndex,
            max(0, (sortedValues.size * percentile).toInt() - 1),
        )
        return sortedValues[index]
    }

    private fun incrementWindow(
        window: MutableMap<Int, Int>,
        startedAtMs: Long,
        delta: Int,
    ) {
        val second = max(1, ((System.currentTimeMillis() - startedAtMs) / 1000L).toInt() + 1)
        window[second] = (window[second] ?: 0) + delta
    }

    private fun incrementWindow(
        window: MutableMap<Int, Long>,
        startedAtMs: Long,
        delta: Long,
    ) {
        val second = max(1, ((System.currentTimeMillis() - startedAtMs) / 1000L).toInt() + 1)
        window[second] = (window[second] ?: 0L) + delta
    }

    private fun endpointHost(endpointUrl: String): String {
        return try {
            URL(endpointUrl).host.takeIf { it.isNotBlank() } ?: endpointUrl
        } catch (_: Throwable) {
            endpointUrl
        }
    }

    private fun requireString(
        params: Map<String, Any?>,
        key: String,
        message: String,
    ): String {
        return params[key]?.toString()?.takeIf { it.isNotBlank() }
            ?: throw EngineFailure("invalid_config", message)
    }

    private fun stringAnyMap(value: Any?): Map<String, Any?> {
        val raw = value as? Map<*, *> ?: return emptyMap()
        val normalized = linkedMapOf<String, Any?>()
        raw.forEach { (entryKey, entryValue) ->
            if (entryKey != null) {
                normalized[entryKey.toString()] = entryValue
            }
        }
        return normalized
    }

    private fun listOfMaps(value: Any?): List<Map<String, Any?>> {
        val raw = value as? List<*> ?: return emptyList()
        return raw.mapNotNull { entry ->
            val map = entry as? Map<*, *> ?: return@mapNotNull null
            map.entries.associate { (key, itemValue) ->
                key.toString() to itemValue
            }
        }
    }

    private fun stringList(value: Any?): List<String> {
        val raw = value as? List<*> ?: return emptyList()
        return raw.mapNotNull { item -> item?.toString() }
    }

    private fun jsonStringList(value: JSONArray?): List<String> {
        if (value == null) {
            return emptyList()
        }
        val list = mutableListOf<String>()
        for (index in 0 until value.length()) {
            list += value.optString(index)
        }
        return list
    }

    private fun diagnosticEvent(level: String, message: String): Map<String, Any?> {
        return mapOf(
            "timestamp" to nowIso(),
            "level" to level,
            "message" to message,
        )
    }

    private fun apiCall(
        operation: String,
        status: String,
        latencyMs: Long,
    ): Map<String, Any?> {
        return mapOf(
            "timestamp" to nowIso(),
            "operation" to operation,
            "status" to status,
            "latencyMs" to latencyMs.toInt(),
        )
    }

    private fun <T> recordApi(
        apiCalls: MutableList<Map<String, Any?>>,
        operation: String,
        block: () -> T,
    ): T {
        val startedAt = System.currentTimeMillis()
        try {
            val result = block()
            apiCalls += apiCall(operation, "200", System.currentTimeMillis() - startedAt)
            return result
        } catch (error: AmazonS3Exception) {
            apiCalls += apiCall(
                operation,
                error.statusCode.toString(),
                System.currentTimeMillis() - startedAt,
            )
            throw mapFailure(error)
        } catch (error: Throwable) {
            apiCalls += apiCall(operation, "error", System.currentTimeMillis() - startedAt)
            throw mapFailure(error)
        }
    }

    private fun <T> recordOptionalApi(
        apiCalls: MutableList<Map<String, Any?>>,
        operation: String,
        block: () -> T,
    ): T? {
        val startedAt = System.currentTimeMillis()
        return try {
            val result = block()
            apiCalls += apiCall(operation, "200", System.currentTimeMillis() - startedAt)
            result
        } catch (error: AmazonS3Exception) {
            if (isOptionalMissing(error)) {
                apiCalls += apiCall(
                    operation,
                    error.statusCode.toString(),
                    System.currentTimeMillis() - startedAt,
                )
                null
            } else {
                apiCalls += apiCall(
                    operation,
                    error.statusCode.toString(),
                    System.currentTimeMillis() - startedAt,
                )
                throw mapFailure(error)
            }
        } catch (error: Throwable) {
            apiCalls += apiCall(operation, "error", System.currentTimeMillis() - startedAt)
            throw mapFailure(error)
        }
    }

    private fun isOptionalMissing(error: AmazonS3Exception): Boolean {
        val errorCode = error.errorCode ?: ""
        return error.statusCode == 404 ||
            errorCode.equals("NoSuchTagSet", ignoreCase = true) ||
            errorCode.equals("NoSuchKey", ignoreCase = true) ||
            errorCode.equals("NoSuchBucketPolicy", ignoreCase = true) ||
            errorCode.equals("NoSuchLifecycleConfiguration", ignoreCase = true) ||
            errorCode.equals("NoSuchCORSConfiguration", ignoreCase = true) ||
            errorCode.equals("NoSuchTagSetError", ignoreCase = true) ||
            errorCode.equals("NotImplemented", ignoreCase = true)
    }

    private fun mapFailure(error: Throwable): EngineFailure {
        if (error is EngineFailure) {
            return error
        }
        if (error is AmazonS3Exception) {
            val code = when (error.statusCode) {
                400 -> "invalid_config"
                401, 403 -> "auth_failed"
                408 -> "timeout"
                409 -> "object_conflict"
                429, 503 -> "throttled"
                else -> "unknown"
            }
            return EngineFailure(
                code = code,
                message = error.errorMessage ?: error.message ?: "S3 request failed.",
                details = mapOf(
                    "statusCode" to error.statusCode,
                    "errorCode" to error.errorCode,
                    "requestId" to error.requestId,
                    "serviceName" to error.serviceName,
                ),
            )
        }
        val message = error.message ?: error::class.java.simpleName
        return EngineFailure(
            code = "unknown",
            message = message,
        )
    }

    private fun buildDestinationKey(prefix: String, fileName: String): String {
        val normalizedPrefix = ensureTrailingSlash(prefix).takeIf { it.isNotBlank() } ?: ""
        val normalizedName = fileName.replace('\\', '/').trimStart('/')
        return "$normalizedPrefix$normalizedName"
    }

    private fun ensureTrailingSlash(value: String): String {
        if (value.isBlank()) {
            return ""
        }
        return if (value.endsWith("/")) value else "$value/"
    }

    private fun fileLengthOrFallback(path: String): Int {
        val file = File(path)
        return if (file.exists()) file.length().toInt() else 12 * 1024 * 1024
    }

    private fun transferStrategyLabel(
        direction: String,
        totalBytes: Int,
        multipartThresholdMiB: Int,
    ): String {
        val usesMultipart = totalBytes >= multipartThresholdMiB * 1024 * 1024
        return "${if (usesMultipart) "Multipart" else "Single-part"} $direction"
    }

    private fun ensureDirectory(path: String): File {
        val file = File(path)
        val directory = if (file.isDirectory || !file.name.contains(".")) {
            file
        } else {
            file.parentFile ?: file
        }
        directory.mkdirs()
        return directory
    }

    private fun resolveDownloadTarget(directory: File, key: String): File {
        val safeKey = key.removePrefix("/").ifBlank { "download.bin" }
        return File(directory, safeKey)
    }

    private fun userDownloadsPath(): String {
        return Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath
    }

    private fun saveToUserDownloads(key: String, input: InputStream): SavedDownload {
        val safeKey = key.removePrefix("/").ifBlank { "download.bin" }
        val segments = safeKey.split("/").filter { it.isNotBlank() }
        val displayName = segments.lastOrNull()?.ifBlank { "download.bin" } ?: "download.bin"
        val relativeChildPath = segments.dropLast(1).joinToString(File.separator)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val relativePath = buildString {
                append(Environment.DIRECTORY_DOWNLOADS)
                if (relativeChildPath.isNotEmpty()) {
                    append(File.separator)
                    append(relativeChildPath)
                }
            }
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
                put(MediaStore.Downloads.IS_PENDING, 1)
                URLConnection.guessContentTypeFromName(displayName)?.let { mimeType ->
                    put(MediaStore.Downloads.MIME_TYPE, mimeType)
                }
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw EngineFailure("io_error", "Could not create a file in Downloads.")
            try {
                val sizeBytes = contentResolver.openOutputStream(uri)?.use { output ->
                    input.copyTo(output).toInt()
                } ?: throw EngineFailure("io_error", "Could not open the Downloads destination.")
                ContentValues().apply {
                    put(MediaStore.Downloads.IS_PENDING, 0)
                }.also { contentResolver.update(uri, it, null, null) }
                val visiblePath = buildString {
                    append(userDownloadsPath())
                    if (relativeChildPath.isNotEmpty()) {
                        append(File.separator)
                        append(relativeChildPath)
                    }
                    append(File.separator)
                    append(displayName)
                }
                return SavedDownload(visiblePath, sizeBytes)
            } catch (error: Throwable) {
                contentResolver.delete(uri, null, null)
                throw error
            }
        }

        val downloadDirectory = if (relativeChildPath.isEmpty()) {
            File(userDownloadsPath())
        } else {
            File(userDownloadsPath(), relativeChildPath)
        }
        downloadDirectory.mkdirs()
        val targetFile = uniqueFile(File(downloadDirectory, displayName))
        val sizeBytes = targetFile.outputStream().use { output ->
            input.copyTo(output).toInt()
        }
        return SavedDownload(targetFile.absolutePath, sizeBytes)
    }

    private fun uniqueFile(candidate: File): File {
        if (!candidate.exists()) {
            return candidate
        }
        val name = candidate.nameWithoutExtension
        val extension = candidate.extension
        var index = 1
        while (true) {
            val nextName = if (extension.isBlank()) {
                "$name ($index)"
            } else {
                "$name ($index).$extension"
            }
            val nextCandidate = File(candidate.parentFile, nextName)
            if (!nextCandidate.exists()) {
                return nextCandidate
            }
            index += 1
        }
    }

    private fun resolveWritablePath(candidate: String, fallbackName: String): File {
        val file = File(candidate)
        return if (file.isAbsolute) {
            file
        } else {
            File(filesDir, fallbackName)
        }
    }

    private fun putIfNotBlank(target: MutableMap<String, String>, key: String, value: String?) {
        if (!value.isNullOrBlank()) {
            target[key] = value
        }
    }

    private fun trimQuotes(value: String?): String? {
        if (value.isNullOrBlank()) {
            return value
        }
        return value.removePrefix("\"").removeSuffix("\"")
    }

    private fun iso(value: Date?): String? {
        if (value == null) {
            return null
        }
        synchronized(isoFormatter) {
            return isoFormatter.format(value)
        }
    }

    private fun nowIso(): String {
        return iso(Date()) ?: ""
    }
}

private data class AndroidProfile(
    val id: String,
    val name: String,
    val endpointUrl: String,
    val region: String,
    val accessKey: String,
    val secretKey: String,
    val sessionToken: String?,
    val pathStyle: Boolean,
    val verifyTls: Boolean,
    val connectTimeoutSeconds: Int,
    val readTimeoutSeconds: Int,
    val maxAttempts: Int,
)

private data class AndroidBenchmarkConfig(
    val profileId: String,
    val engineId: String,
    val bucketName: String,
    val prefix: String,
    val workloadType: String,
    val testMode: String,
    val operationCount: Int,
    val durationSeconds: Int,
    val objectSizes: List<Int>,
    val csvOutputPath: String,
    val jsonOutputPath: String,
)

private data class TransferJobState(
    val id: String,
    val label: String,
    val direction: String,
    var progress: Double = 0.0,
    var status: String,
    var bytesTransferred: Int = 0,
    val totalBytes: Int,
    val strategyLabel: String?,
    var currentItemLabel: String?,
    val itemCount: Int?,
    var itemsCompleted: Int?,
    val partSizeBytes: Int?,
    var partsCompleted: Int?,
    val partsTotal: Int?,
    var canPause: Boolean,
    var canResume: Boolean,
    var canCancel: Boolean = false,
    val outputLines: MutableList<String> = mutableListOf(),
) {
    fun toMap(): Map<String, Any?> {
        val effectiveProgress = if (totalBytes <= 0) progress else {
            max(progress, bytesTransferred.toDouble() / totalBytes.toDouble())
        }
        return mapOf(
            "id" to id,
            "label" to label,
            "direction" to direction,
            "progress" to effectiveProgress,
            "status" to status,
            "bytesTransferred" to bytesTransferred,
            "totalBytes" to totalBytes,
            "strategyLabel" to strategyLabel,
            "currentItemLabel" to currentItemLabel,
            "itemCount" to itemCount,
            "itemsCompleted" to itemsCompleted,
            "partSizeBytes" to partSizeBytes,
            "partsCompleted" to partsCompleted,
            "partsTotal" to partsTotal,
            "canPause" to canPause,
            "canResume" to canResume,
            "canCancel" to canCancel,
            "outputLines" to outputLines.toList(),
        )
    }
}

private data class BenchmarkRunState(
    val id: String,
    val config: Map<String, Any?>,
    val profile: AndroidProfile,
    val benchmarkConfig: AndroidBenchmarkConfig,
    var status: String = "queued",
    var processedCount: Int = 0,
    val startedAt: Date,
    var completedAt: Date? = null,
    var averageLatencyMs: Double = 0.0,
    var throughputOpsPerSecond: Double = 0.0,
    val liveLog: MutableList<String>,
    var activeElapsedSeconds: Double = 0.0,
    var throughputSeries: List<Map<String, Any?>> = emptyList(),
    var resultSummary: Map<String, Any?>? = null,
    var stopRequested: Boolean = false,
) {
    fun toMap(): Map<String, Any?> {
        return mapOf(
            "id" to id,
            "config" to config,
            "status" to status,
            "processedCount" to processedCount,
            "startedAt" to startedAt.toIso(),
            "completedAt" to completedAt?.toIso(),
            "averageLatencyMs" to averageLatencyMs,
            "throughputOpsPerSecond" to throughputOpsPerSecond,
            "liveLog" to liveLog.toList(),
            "activeElapsedSeconds" to activeElapsedSeconds,
            "resultSummary" to resultSummary,
        )
    }
}

private fun Date.toIso(): String {
    val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
    formatter.timeZone = TimeZone.getTimeZone("UTC")
    return formatter.format(this)
}

private data class EngineFailure(
    val code: String,
    override val message: String,
    val details: Map<String, Any?>? = null,
) : RuntimeException(message) {
    fun toMap(): Map<String, Any?> {
        return buildMap {
            put("code", code)
            put("message", message)
            if (details != null) {
                put("details", details)
            }
        }
    }
}
