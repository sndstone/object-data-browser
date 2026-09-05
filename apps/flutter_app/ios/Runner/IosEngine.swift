import AWSS3
import AWSSDKIdentity
import Flutter
import Foundation
import UIKit

/// Native iOS bridge for the platform-neutral engine contract.
///
/// iOS cannot ship the desktop sidecars, so S3 operations run in-process with
/// the official AWS SDK for Swift. All callbacks return property-list values
/// suitable for Flutter's StandardMethodCodec.
final class IosEngine {
  private static let channelName = "s3_browser_crossplat/ios_engine"
  private let channel: FlutterMethodChannel
  private var transfers: [String: TransferState] = [:]
  private var backgroundPausedTransfers: Set<String> = []

  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(didEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(didBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listEngines":
      result([
        descriptor(id: "go", label: "Go (iOS)", language: "go"),
        descriptor(id: "rust", label: "Rust (iOS)", language: "rust"),
      ])
    case "dispatch":
      let args = call.arguments as? [String: Any] ?? [:]
      let engineID = args["engineId"] as? String ?? "ios"
      let method = args["method"] as? String ?? "unknown"
      let params = args["params"] as? [String: Any] ?? [:]
      Task {
        do {
          let payload = try await self.dispatch(
            engineID: engineID,
            method: method,
            params: params
          )
          await MainActor.run { result(payload) }
        } catch let failure as EngineFailure {
          await MainActor.run { result(["error": failure.map]) }
        } catch {
          let failure = self.mapFailure(error)
          await MainActor.run { result(["error": failure.map]) }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func dispatch(
    engineID: String,
    method: String,
    params: [String: Any]
  ) async throws -> [String: Any] {
    switch method {
    case "health": return health(engineID: engineID)
    case "getCapabilities": return capabilities()
    case "testProfile": return try await testProfile(params)
    case "listBuckets": return try await listBuckets(params)
    case "createBucket": return try await createBucket(params)
    case "deleteBucket": return try await deleteBucket(params)
    case "listObjects": return try await listObjects(params)
    case "listObjectVersions": return try await listObjectVersions(params)
    case "getObjectDetails": return try await getObjectDetails(params)
    case "getBucketAdminState": return try await bucketAdminState(params)
    case "setBucketVersioning": return try await setBucketVersioning(params)
    case "putBucketLifecycle": return try await putBucketLifecycle(params)
    case "deleteBucketLifecycle": return try await deleteBucketLifecycle(params)
    case "putBucketPolicy": return try await putBucketPolicy(params)
    case "deleteBucketPolicy": return try await deleteBucketPolicy(params)
    case "putBucketCors": return try await putBucketCors(params)
    case "deleteBucketCors": return try await deleteBucketCors(params)
    case "putBucketTagging": return try await putBucketTagging(params)
    case "deleteBucketTagging": return try await deleteBucketTagging(params)
    case "createFolder": return try await createFolder(params)
    case "copyObject": return try await copyObject(params, deleteSource: false)
    case "moveObject": return try await copyObject(params, deleteSource: true)
    case "deleteObjects": return try await deleteObjects(params)
    case "deleteObjectVersions": return try await deleteObjectVersions(params)
    case "startUpload": return try await startUpload(params)
    case "startDownload": return try await startDownload(params)
    case "pauseTransfer": return try transferAction(params, action: .pause)
    case "resumeTransfer": return try transferAction(params, action: .resume)
    case "cancelTransfer": return try transferAction(params, action: .cancel)
    case "generatePresignedUrl": return try await presignedURL(params)
    case "runPutTestData": return try await runPutTestData(params)
    case "runDeleteAll": return try await runDeleteAll(params)
    case "cancelToolExecution": return cancelTool(params)
    case "putBucketEncryption", "deleteBucketEncryption":
      throw EngineFailure(
        code: "unsupported_feature",
        message: "\(method) is not available in the first iOS release."
      )
    case "startBenchmark", "getBenchmarkStatus", "pauseBenchmark",
      "resumeBenchmark", "stopBenchmark", "exportBenchmarkResults":
      throw EngineFailure(
        code: "unsupported_feature",
        message: "Benchmark mode is not available on iOS."
      )
    default:
      throw EngineFailure(
        code: "unsupported_feature",
        message: "iOS adapter method \(method) is not implemented."
      )
    }
  }

  private func descriptor(id: String, label: String, language: String) -> [String: Any] {
    [
      "id": id,
      "label": label,
      "language": language,
      "version": "2.2.5",
      "available": true,
      "notes": "iOS adapter backed by the official AWS SDK for Swift.",
    ]
  }

  private func health(engineID: String) -> [String: Any] {
    [
      "engine": engineID,
      "version": "2.2.5",
      "available": true,
      "adapter": "ios-aws-swift",
    ]
  }

  private func capabilities() -> [String: Any] {
    ["items": [
      capability("bucket.browse", "Browse buckets", true),
      capability("object.browse", "Browse objects", true),
      capability("object.versions", "Version inspection", true),
      capability("object.debug", "Events & debug inspection", true),
      capability("object.presign", "Presigned URL generation", true),
      capability("bucket.admin_mutation", "Bucket admin write actions", true,
                 "Versioning, lifecycle, policy, CORS, and tagging are available in iOS v1."),
      capability("object.copy_move", "Copy, move, delete, and folder actions", true),
      capability("transfers", "Transfer actions", true),
      capability("benchmark", "Integrated benchmark mode", false,
                 "Benchmark is deferred for the first iOS release."),
      capability("ios.local_network", "Local network endpoints", true,
                 "Local S3-compatible services are allowed by the iOS target."),
    ]]
  }

  private func capability(
    _ key: String,
    _ label: String,
    _ supported: Bool,
    _ reason: String? = nil
  ) -> [String: Any] {
    var value: [String: Any] = [
      "key": key,
      "label": label,
      "state": supported ? "supported" : "unsupported",
    ]
    if let reason { value["reason"] = reason }
    return value
  }

  private func testProfile(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let output = try await client(profile).listBuckets(input: ListBucketsInput())
    return [
      "ok": true,
      "bucketCount": output.buckets?.count ?? 0,
      "endpoint": URL(string: profile.endpoint)?.host ?? profile.endpoint,
    ]
  }

  private func listBuckets(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let service = try client(profile)
    let output = try await service.listBuckets(input: ListBucketsInput())
    var items: [[String: Any]] = []
    for bucket in output.buckets ?? [] {
      guard let name = bucket.name else { continue }
      let versioning = try? await service.getBucketVersioning(
        input: GetBucketVersioningInput(bucket: name)
      )
      items.append([
        "name": name,
        "region": bucket.bucketRegion ?? profile.region,
        "objectCountHint": 0,
        "versioningEnabled": versioning?.status == .enabled,
        "createdAt": iso(bucket.creationDate),
      ])
    }
    return ["items": items]
  }

  private func createBucket(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let name = try required(params, "bucketName", "Bucket name is required.")
    let enableVersioning = params["enableVersioning"] as? Bool ?? false
    let objectLock = params["enableObjectLock"] as? Bool ?? false
    let service = try client(profile)
    let location = profile.region == "us-east-1"
      ? nil
      : S3ClientTypes.BucketLocationConstraint(rawValue: profile.region)
    _ = try await service.createBucket(input: CreateBucketInput(
      bucket: name,
      createBucketConfiguration: location.map {
        S3ClientTypes.CreateBucketConfiguration(locationConstraint: $0)
      },
      objectLockEnabledForBucket: objectLock
    ))
    if enableVersioning {
      _ = try await service.putBucketVersioning(input: PutBucketVersioningInput(
        bucket: name,
        versioningConfiguration: S3ClientTypes.VersioningConfiguration(status: .enabled)
      ))
    }
    return [
      "name": name,
      "region": profile.region,
      "objectCountHint": 0,
      "versioningEnabled": enableVersioning,
      "createdAt": iso(Date()),
    ]
  }

  private func deleteBucket(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    _ = try await client(profile).deleteBucket(input: DeleteBucketInput(bucket: bucket))
    return [:]
  }

  private func listObjects(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let prefix = params["prefix"] as? String ?? ""
    let flat = params["flat"] as? Bool ?? false
    let cursor = params["cursor"] as? [String: Any]
    let continuation = cursor?["value"] as? String
    let output = try await client(profile).listObjectsV2(input: ListObjectsV2Input(
      bucket: bucket,
      continuationToken: continuation,
      delimiter: flat ? nil : "/",
      maxKeys: 1000,
      prefix: prefix
    ))
    var items: [[String: Any]] = []
    for commonPrefix in output.commonPrefixes ?? [] {
      guard let key = commonPrefix.prefix else { continue }
      let name = key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
      items.append(objectMap(
        key: key,
        name: name.isEmpty ? key : name,
        size: 0,
        storageClass: "FOLDER",
        modified: Date(),
        folder: true,
        etag: nil
      ))
    }
    for object in output.contents ?? [] {
      guard let key = object.key, flat || key != prefix else { continue }
      let name = key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
      items.append(objectMap(
        key: key,
        name: name.isEmpty ? key : name,
        size: object.size ?? 0,
        storageClass: object.storageClass?.rawValue ?? "STANDARD",
        modified: object.lastModified,
        folder: false,
        etag: object.eTag?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      ))
    }
    items.sort {
      let leftFolder = $0["isFolder"] as? Bool ?? false
      let rightFolder = $1["isFolder"] as? Bool ?? false
      if leftFolder != rightFolder { return leftFolder }
      return ($0["key"] as? String ?? "").localizedCaseInsensitiveCompare(
        $1["key"] as? String ?? ""
      ) == .orderedAscending
    }
    return [
      "items": items,
      "nextCursor": [
        "value": (output.nextContinuationToken as Any?) ?? NSNull(),
        "hasMore": output.isTruncated ?? false,
      ],
    ]
  }

  private func objectMap(
    key: String,
    name: String,
    size: Int,
    storageClass: String,
    modified: Date?,
    folder: Bool,
    etag: String?
  ) -> [String: Any] {
    [
      "key": key,
      "name": name,
      "size": size,
      "storageClass": storageClass,
      "modifiedAt": iso(modified),
      "isFolder": folder,
      "etag": etag ?? NSNull(),
      "metadataCount": 0,
    ]
  }

  private func listObjectVersions(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let key = params["key"] as? String
    let options = params["options"] as? [String: Any] ?? [:]
    let filter = options["filterValue"] as? String ?? ""
    let filterMode = options["filterMode"] as? String ?? "prefix"
    let prefix = !(key ?? "").isEmpty ? key : (filterMode == "prefix" ? filter : "")
    let showVersions = options["showVersions"] as? Bool ?? true
    let showMarkers = options["showDeleteMarkers"] as? Bool ?? true
    let output = try await client(profile).listObjectVersions(
      input: ListObjectVersionsInput(bucket: bucket, maxKeys: 1000, prefix: prefix)
    )
    var items: [[String: Any]] = []
    if showVersions {
      for version in output.versions ?? [] {
        guard let objectKey = version.key, key == nil || objectKey == key else { continue }
        items.append(versionMap(
          key: objectKey,
          versionID: version.versionId,
          modified: version.lastModified,
          latest: version.isLatest ?? false,
          marker: false,
          size: version.size ?? 0,
          storageClass: version.storageClass?.rawValue ?? "STANDARD"
        ))
      }
    }
    if showMarkers {
      for marker in output.deleteMarkers ?? [] {
        guard let objectKey = marker.key, key == nil || objectKey == key else { continue }
        items.append(versionMap(
          key: objectKey,
          versionID: marker.versionId,
          modified: marker.lastModified,
          latest: marker.isLatest ?? false,
          marker: true,
          size: 0,
          storageClass: "DELETE_MARKER"
        ))
      }
    }
    items.sort { ($0["modifiedAt"] as? String ?? "") > ($1["modifiedAt"] as? String ?? "") }
    let markerCount = items.filter { $0["deleteMarker"] as? Bool == true }.count
    return [
      "items": items,
      "cursor": ["value": NSNull(), "hasMore": output.isTruncated ?? false],
      "totalCount": items.count,
      "versionCount": items.count - markerCount,
      "deleteMarkerCount": markerCount,
    ]
  }

  private func versionMap(
    key: String,
    versionID: String?,
    modified: Date?,
    latest: Bool,
    marker: Bool,
    size: Int,
    storageClass: String
  ) -> [String: Any] {
    [
      "key": key,
      "versionId": versionID ?? "",
      "modifiedAt": iso(modified),
      "latest": latest,
      "deleteMarker": marker,
      "size": size,
      "storageClass": storageClass,
    ]
  }

  private func getObjectDetails(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let key = try required(params, "key", "Object key is required.")
    let service = try client(profile)
    let started = Date()
    let head = try await service.headObject(input: HeadObjectInput(bucket: bucket, key: key))
    let tags = try? await service.getObjectTagging(
      input: GetObjectTaggingInput(bucket: bucket, key: key)
    )
    var headers: [String: String] = ["Content-Length": String(head.contentLength ?? 0)]
    if let value = head.eTag { headers["ETag"] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    if let value = head.contentType { headers["Content-Type"] = value }
    if let value = head.lastModified { headers["Last-Modified"] = iso(value) }
    if let value = head.cacheControl { headers["Cache-Control"] = value }
    if let value = head.contentEncoding { headers["Content-Encoding"] = value }
    if let value = head.storageClass { headers["Storage-Class"] = value.rawValue }
    var tagMap: [String: String] = [:]
    for tag in tags?.tagSet ?? [] {
      if let key = tag.key, let value = tag.value { tagMap[key] = value }
    }
    let latency = Int(Date().timeIntervalSince(started) * 1000)
    return [
      "key": key,
      "metadata": head.metadata ?? [:],
      "headers": headers,
      "tags": tagMap,
      "debugEvents": [[
        "timestamp": iso(Date()),
        "level": "INFO",
        "message": "Loaded metadata and \(tagMap.count) tag(s) for \(key).",
      ]],
      "apiCalls": [[
        "timestamp": iso(Date()),
        "operation": "HeadObject",
        "status": "ok",
        "latencyMs": latency,
      ]],
      "debugLogExcerpt": [
        "Resolved endpoint \(profile.endpoint).",
        "Completed HEAD and tagging diagnostics for \(bucket)/\(key).",
      ],
      "rawDiagnostics": [
        "bucketName": bucket,
        "engineState": "healthy",
        "engineAdapter": "ios-aws-swift",
      ],
    ]
  }

  private func bucketAdminState(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let service = try client(profile)
    let versioning = try? await service.getBucketVersioning(
      input: GetBucketVersioningInput(bucket: bucket)
    )
    let policy = try? await service.getBucketPolicy(input: GetBucketPolicyInput(bucket: bucket))
    let cors = try? await service.getBucketCors(input: GetBucketCorsInput(bucket: bucket))
    let lifecycle = try? await service.getBucketLifecycleConfiguration(
      input: GetBucketLifecycleConfigurationInput(bucket: bucket)
    )
    let tagging = try? await service.getBucketTagging(input: GetBucketTaggingInput(bucket: bucket))
    var tags: [String: String] = [:]
    for tag in tagging?.tagSet ?? [] {
      if let key = tag.key, let value = tag.value { tags[key] = value }
    }
    let lifecycleRules = (lifecycle?.rules ?? []).map(lifecycleRuleMap)
    let corsRules = (cors?.corsRules ?? []).map(corsRuleMap)
    let status = versioning?.status?.rawValue ?? "Disabled"
    return [
      "bucketName": bucket,
      "versioningEnabled": versioning?.status == .enabled,
      "versioningStatus": status,
      "objectLockEnabled": false,
      "lifecycleEnabled": !(lifecycle?.rules ?? []).isEmpty,
      "policyAttached": policy?.policy != nil,
      "corsEnabled": !(cors?.corsRules ?? []).isEmpty,
      "encryptionEnabled": false,
      "encryptionSummary": "Not configured",
      "tags": tags,
      "lifecycleRules": lifecycleRules,
      "policyJson": policy?.policy ?? "{}",
      "corsJson": prettyJSON(corsRules, fallback: "[]"),
      "lifecycleJson": prettyJSON(
        ["Rules": (lifecycle?.rules ?? []).map(lifecycleRuleJSON)],
        fallback: "{\n  \"Rules\": []\n}"
      ),
      "encryptionJson": "{}",
      "apiCalls": [],
    ]
  }

  private func setBucketVersioning(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let enabled = params["enabled"] as? Bool ?? false
    _ = try await client(profile).putBucketVersioning(input: PutBucketVersioningInput(
      bucket: bucket,
      versioningConfiguration: S3ClientTypes.VersioningConfiguration(
        status: enabled ? .enabled : .suspended
      )
    ))
    return try await bucketAdminState(params)
  }

  private func putBucketLifecycle(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let json = try required(params, "lifecycleJson", "Lifecycle JSON is required.")
    let rules = try parseLifecycleRules(json)
    _ = try await client(profile).putBucketLifecycleConfiguration(
      input: PutBucketLifecycleConfigurationInput(
        bucket: bucket,
        lifecycleConfiguration: S3ClientTypes.BucketLifecycleConfiguration(rules: rules)
      )
    )
    return try await bucketAdminState(params)
  }

  private func deleteBucketLifecycle(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    _ = try await client(profile).deleteBucketLifecycle(
      input: DeleteBucketLifecycleInput(bucket: bucket)
    )
    return try await bucketAdminState(params)
  }

  private func putBucketPolicy(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let policy = try required(params, "policyJson", "Policy JSON is required.")
    _ = try await client(profile).putBucketPolicy(
      input: PutBucketPolicyInput(bucket: bucket, policy: policy)
    )
    return try await bucketAdminState(params)
  }

  private func deleteBucketPolicy(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    _ = try await client(profile).deleteBucketPolicy(input: DeleteBucketPolicyInput(bucket: bucket))
    return try await bucketAdminState(params)
  }

  private func putBucketCors(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let json = try required(params, "corsJson", "CORS JSON is required.")
    let rules = try parseCorsRules(json)
    _ = try await client(profile).putBucketCors(input: PutBucketCorsInput(
      bucket: bucket,
      corsConfiguration: S3ClientTypes.CORSConfiguration(corsRules: rules)
    ))
    return try await bucketAdminState(params)
  }

  private func deleteBucketCors(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    _ = try await client(profile).deleteBucketCors(input: DeleteBucketCorsInput(bucket: bucket))
    return try await bucketAdminState(params)
  }

  private func putBucketTagging(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let values = params["tags"] as? [String: Any] ?? [:]
    let tags = values.map { S3ClientTypes.Tag(key: $0.key, value: String(describing: $0.value)) }
    _ = try await client(profile).putBucketTagging(input: PutBucketTaggingInput(
      bucket: bucket,
      tagging: S3ClientTypes.Tagging(tagSet: tags)
    ))
    return try await bucketAdminState(params)
  }

  private func deleteBucketTagging(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    _ = try await client(profile).deleteBucketTagging(input: DeleteBucketTaggingInput(bucket: bucket))
    return try await bucketAdminState(params)
  }

  private func createFolder(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let key = try required(params, "key", "Object key is required.")
    _ = try await client(profile).putObject(input: PutObjectInput(
      body: .data(Data()),
      bucket: bucket,
      contentLength: 0,
      key: key
    ))
    return [:]
  }

  private func copyObject(
    _ params: [String: Any],
    deleteSource: Bool
  ) async throws -> [String: Any] {
    let profile = try profile(params)
    let sourceBucket = try required(params, "sourceBucketName", "Source bucket is required.")
    let sourceKey = try required(params, "sourceKey", "Source key is required.")
    let destinationBucket = try required(params, "destinationBucketName", "Destination bucket is required.")
    let destinationKey = try required(params, "destinationKey", "Destination key is required.")
    let service = try client(profile)
    let source = "\(sourceBucket)/\(sourceKey)"
      .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "\(sourceBucket)/\(sourceKey)"
    _ = try await service.copyObject(input: CopyObjectInput(
      bucket: destinationBucket,
      copySource: source,
      key: destinationKey
    ))
    if deleteSource {
      _ = try await service.deleteObject(input: DeleteObjectInput(
        bucket: sourceBucket,
        key: sourceKey
      ))
    }
    return batchResult(success: 1)
  }

  private func deleteObjects(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let keys = params["keys"] as? [String] ?? []
    let service = try client(profile)
    for key in keys {
      _ = try await service.deleteObject(input: DeleteObjectInput(bucket: bucket, key: key))
    }
    return batchResult(success: keys.count)
  }

  private func deleteObjectVersions(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let versions = params["versions"] as? [[String: Any]] ?? []
    let service = try client(profile)
    for version in versions {
      guard let key = version["key"] as? String else { continue }
      _ = try await service.deleteObject(input: DeleteObjectInput(
        bucket: bucket,
        key: key,
        versionId: version["versionId"] as? String
      ))
    }
    return batchResult(success: versions.count)
  }

  private func batchResult(success: Int) -> [String: Any] {
    ["successCount": success, "failureCount": 0, "failures": []]
  }

  private func startUpload(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let prefix = params["prefix"] as? String ?? ""
    let paths = params["filePaths"] as? [String] ?? []
    guard !paths.isEmpty else { throw EngineFailure(code: "invalid_config", message: "Pick at least one file to upload.") }
    let keyByPath = params["objectKeyByPath"] as? [String: String] ?? [:]
    let threshold = clampedPartMiB(params["multipartThresholdMiB"] as? Int ?? 32)
    let chunk = clampedPartMiB(params["multipartChunkMiB"] as? Int ?? 8)
    let sizes = try paths.map { try fileSize($0) }
    guard sizes.allSatisfy({ $0 <= 50_000 * 1_073_741_824 }) else {
      throw EngineFailure(code: "invalid_config", message: "S3 objects cannot exceed 50,000 GiB.")
    }
    let total = sizes.reduce(0, +)
    let job = TransferState(
      id: "upload-\(milliseconds())",
      label: "Upload \(paths.count) file(s) to \(bucket)",
      direction: "upload",
      totalBytes: total,
      strategyLabel: transferStrategy(total: total, thresholdMiB: threshold),
      currentItem: paths.first,
      itemCount: paths.count,
      partSizeBytes: total >= threshold * 1_048_576 ? chunk * 1_048_576 : nil
    )
    transfers[job.id] = job
    let service = try client(profile)
    for (index, path) in paths.enumerated() {
      guard job.status != "cancelled" else { break }
      let name = keyByPath[path] ?? URL(fileURLWithPath: path).lastPathComponent
      let key = join(prefix: prefix, name: name)
      let uploaded = try await uploadFile(
        service: service,
        path: path,
        bucket: bucket,
        key: key,
        multipartThresholdBytes: threshold * 1_048_576,
        partSizeBytes: chunk * 1_048_576,
        job: job
      )
      guard uploaded else { break }
      job.itemsCompleted = index + 1
      job.currentItem = key
      job.outputLines.append("Uploaded \(name) to \(key).")
    }
    job.completeIfActive()
    return job.map
  }

  private func uploadFile(
    service: S3Client,
    path: String,
    bucket: String,
    key: String,
    multipartThresholdBytes: Int,
    partSizeBytes: Int,
    job: TransferState
  ) async throws -> Bool {
    let size = try fileSize(path)
    if size < multipartThresholdBytes {
      try await waitUntilRunnable(job)
      guard job.status != "cancelled" else { return false }
      let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
      _ = try await service.putObject(input: PutObjectInput(
        body: .data(data),
        bucket: bucket,
        contentLength: data.count,
        key: key
      ))
      job.bytesTransferred += data.count
      return true
    }

    let partCount = max(1, (size + partSizeBytes - 1) / partSizeBytes)
    guard partCount <= 10_000 else {
      throw EngineFailure(
        code: "invalid_config",
        message: "The selected part size would exceed S3's 10,000-part limit."
      )
    }
    let initiated = try await service.createMultipartUpload(
      input: CreateMultipartUploadInput(bucket: bucket, key: key)
    )
    guard let uploadID = initiated.uploadId else {
      throw EngineFailure(code: "unknown", message: "S3 did not return a multipart upload id.")
    }
    do {
      let completed = try await withThrowingTaskGroup(of: UploadedPart.self) { group in
        let workerCount = partWorkerCount(partCount: partCount, partSizeBytes: partSizeBytes)
        var nextPart = workerCount + 1
        var uploaded: [UploadedPart] = []
        for partNumber in 1...workerCount {
          addUploadPartTask(
            to: &group,
            service: service,
            path: path,
            size: size,
            partSizeBytes: partSizeBytes,
            bucket: bucket,
            key: key,
            uploadID: uploadID,
            partNumber: partNumber
          )
        }
        while let part = try await group.next() {
          uploaded.append(part)
          job.bytesTransferred += part.byteCount
          if nextPart <= partCount {
            try await waitUntilRunnable(job)
            guard job.status != "cancelled" else {
              group.cancelAll()
              throw TransferCancelled()
            }
            addUploadPartTask(
              to: &group,
              service: service,
              path: path,
              size: size,
              partSizeBytes: partSizeBytes,
              bucket: bucket,
              key: key,
              uploadID: uploadID,
              partNumber: nextPart
            )
            nextPart += 1
          }
        }
        return uploaded
          .sorted { $0.partNumber < $1.partNumber }
          .map { S3ClientTypes.CompletedPart(eTag: $0.etag, partNumber: $0.partNumber) }
      }
      _ = try await service.completeMultipartUpload(input: CompleteMultipartUploadInput(
        bucket: bucket,
        key: key,
        mpuObjectSize: size,
        multipartUpload: S3ClientTypes.CompletedMultipartUpload(parts: completed),
        uploadId: uploadID
      ))
      return true
    } catch is TransferCancelled {
      _ = try? await service.abortMultipartUpload(input: AbortMultipartUploadInput(
        bucket: bucket, key: key, uploadId: uploadID
      ))
      return false
    } catch {
      _ = try? await service.abortMultipartUpload(input: AbortMultipartUploadInput(
        bucket: bucket, key: key, uploadId: uploadID
      ))
      throw error
    }
  }

  private func startDownload(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let keys = params["keys"] as? [String] ?? []
    let destination = try required(params, "destinationPath", "Destination path is required.")
    guard !keys.isEmpty else { throw EngineFailure(code: "invalid_config", message: "Pick at least one object to download.") }
    let threshold = clampedPartMiB(params["multipartThresholdMiB"] as? Int ?? 32)
    let chunk = clampedPartMiB(params["multipartChunkMiB"] as? Int ?? 8)
    let service = try client(profile)
    var total = 0
    var sizes: [String: Int] = [:]
    for key in keys {
      let head = try await service.headObject(input: HeadObjectInput(bucket: bucket, key: key))
      let size = head.contentLength ?? 0
      sizes[key] = size
      total += size
    }
    let job = TransferState(
      id: "download-\(milliseconds())",
      label: "Download \(keys.count) object(s)",
      direction: "download",
      totalBytes: total,
      strategyLabel: transferStrategy(total: total, thresholdMiB: threshold),
      currentItem: keys.first,
      itemCount: keys.count,
      partSizeBytes: total >= threshold * 1_048_576 ? chunk * 1_048_576 : nil
    )
    transfers[job.id] = job
    try FileManager.default.createDirectory(
      atPath: destination,
      withIntermediateDirectories: true
    )
    for (index, key) in keys.enumerated() {
      guard job.status != "cancelled" else { break }
      let fileName = URL(fileURLWithPath: key).lastPathComponent
      let url = uniqueDestination(directory: destination, fileName: fileName)
      let downloaded = try await downloadObject(
        service: service,
        bucket: bucket,
        key: key,
        size: sizes[key] ?? 0,
        destination: url,
        multipartThresholdBytes: threshold * 1_048_576,
        partSizeBytes: chunk * 1_048_576,
        job: job
      )
      guard downloaded else { break }
      job.itemsCompleted = index + 1
      job.currentItem = key
      job.outputLines.append("Downloaded \(key) to \(url.path).")
    }
    job.completeIfActive()
    return job.map
  }

  private func addUploadPartTask(
    to group: inout ThrowingTaskGroup<UploadedPart, Error>,
    service: S3Client,
    path: String,
    size: Int,
    partSizeBytes: Int,
    bucket: String,
    key: String,
    uploadID: String,
    partNumber: Int
  ) {
    group.addTask {
      let offset = (partNumber - 1) * partSizeBytes
      let length = min(partSizeBytes, size - offset)
      let data = try Self.readFilePart(path: path, offset: offset, length: length)
      let output = try await service.uploadPart(input: UploadPartInput(
        body: .data(data),
        bucket: bucket,
        contentLength: data.count,
        key: key,
        partNumber: partNumber,
        uploadId: uploadID
      ))
      guard let etag = output.eTag else {
        throw EngineFailure(
          code: "unknown",
          message: "S3 returned no ETag for upload part \(partNumber)."
        )
      }
      return UploadedPart(partNumber: partNumber, etag: etag, byteCount: data.count)
    }
  }

  private func downloadObject(
    service: S3Client,
    bucket: String,
    key: String,
    size: Int,
    destination: URL,
    multipartThresholdBytes: Int,
    partSizeBytes: Int,
    job: TransferState
  ) async throws -> Bool {
    try await waitUntilRunnable(job)
    guard job.status != "cancelled" else { return false }
    if size < multipartThresholdBytes {
      let output = try await service.getObject(input: GetObjectInput(bucket: bucket, key: key))
      guard let data = try await output.body?.readData() else {
        throw EngineFailure(code: "unknown", message: "S3 returned no data for \(key).")
      }
      guard job.status != "cancelled" else { return false }
      try data.write(to: destination, options: .atomic)
      job.bytesTransferred += data.count
      return true
    }

    let partCount = max(1, (size + partSizeBytes - 1) / partSizeBytes)
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let handle = try FileHandle(forWritingTo: destination)
    do {
      try handle.truncate(atOffset: UInt64(size))
      try await withThrowingTaskGroup(of: DownloadedPart.self) { group in
        let workerCount = partWorkerCount(partCount: partCount, partSizeBytes: partSizeBytes)
        var nextPart = workerCount + 1
        for partNumber in 1...workerCount {
          addDownloadPartTask(
            to: &group,
            service: service,
            bucket: bucket,
            key: key,
            size: size,
            partSizeBytes: partSizeBytes,
            partNumber: partNumber
          )
        }
        while let part = try await group.next() {
          try handle.seek(toOffset: UInt64(part.offset))
          handle.write(part.data)
          job.bytesTransferred += part.data.count
          if nextPart <= partCount {
            try await waitUntilRunnable(job)
            guard job.status != "cancelled" else {
              group.cancelAll()
              throw TransferCancelled()
            }
            addDownloadPartTask(
              to: &group,
              service: service,
              bucket: bucket,
              key: key,
              size: size,
              partSizeBytes: partSizeBytes,
              partNumber: nextPart
            )
            nextPart += 1
          }
        }
      }
      try handle.close()
      return true
    } catch is TransferCancelled {
      try? handle.close()
      try? FileManager.default.removeItem(at: destination)
      return false
    } catch {
      try? handle.close()
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  private func addDownloadPartTask(
    to group: inout ThrowingTaskGroup<DownloadedPart, Error>,
    service: S3Client,
    bucket: String,
    key: String,
    size: Int,
    partSizeBytes: Int,
    partNumber: Int
  ) {
    group.addTask {
      let offset = (partNumber - 1) * partSizeBytes
      let length = min(partSizeBytes, size - offset)
      let end = offset + length - 1
      let output = try await service.getObject(input: GetObjectInput(
        bucket: bucket,
        key: key,
        range: "bytes=\(offset)-\(end)"
      ))
      guard let data = try await output.body?.readData() else {
        throw EngineFailure(
          code: "unknown",
          message: "S3 returned no data for range \(offset)-\(end) of \(key)."
        )
      }
      return DownloadedPart(offset: offset, data: data)
    }
  }

  private func transferAction(
    _ params: [String: Any],
    action: TransferAction
  ) throws -> [String: Any] {
    let id = try required(params, "jobId", "Transfer job id is required.")
    guard let job = transfers[id] else {
      throw EngineFailure(code: "invalid_config", message: "Transfer job was not found.")
    }
    switch action {
    case .pause where job.status == "running":
      job.status = "paused"
      job.outputLines.append("Transfer paused.")
    case .resume where job.status == "paused":
      job.status = "running"
      job.outputLines.append("Transfer resumed.")
    case .cancel where job.status != "completed":
      job.status = "cancelled"
      job.outputLines.append("Transfer cancelled.")
    default: break
    }
    return job.map
  }

  private func presignedURL(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let bucket = try required(params, "bucketName", "Bucket name is required.")
    let key = try required(params, "key", "Object key is required.")
    let seconds = params["expirationSeconds"] as? Int ?? 900
    let request = try await client(profile).presignedRequestForGetObject(
      input: GetObjectInput(bucket: bucket, key: key),
      expiration: TimeInterval(seconds)
    )
    guard let url = request.url else {
      throw EngineFailure(code: "unknown", message: "Could not generate a presigned URL.")
    }
    return ["url": url.absoluteString]
  }

  private func runPutTestData(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let config = params["config"] as? [String: Any] ?? [:]
    let bucket = try required(config, "bucketName", "Bucket name is required.")
    let prefix = config["prefix"] as? String ?? "seed/"
    let size = max(0, config["objectSizeBytes"] as? Int ?? 1024)
    let versions = max(1, config["versions"] as? Int ?? 1)
    let count = max(1, config["objectCount"] as? Int ?? 1)
    let service = try client(profile)
    var lines: [String] = []
    for objectIndex in 0..<count {
      for versionIndex in 0..<versions {
        let key = "\(prefix.hasSuffix("/") ? prefix : prefix + "/")sample-\(objectIndex + 1)-v\(versionIndex + 1).bin"
        let bytes = Data((0..<size).map { UInt8(($0 + objectIndex + versionIndex) % 255) })
        _ = try await service.putObject(input: PutObjectInput(
          body: .data(bytes), bucket: bucket, contentLength: bytes.count, key: key
        ))
        lines.append("Uploaded \(key) (\(bytes.count) bytes).")
      }
    }
    return toolState(
      label: "put-testdata",
      status: "Uploaded \(count * versions) object version(s) into \(bucket).",
      lines: lines,
      exitCode: 0
    )
  }

  private func runDeleteAll(_ params: [String: Any]) async throws -> [String: Any] {
    let profile = try profile(params)
    let config = params["config"] as? [String: Any] ?? [:]
    let bucket = try required(config, "bucketName", "Bucket name is required.")
    let service = try client(profile)
    var deleted = 0
    var continuation: String?
    repeat {
      let output = try await service.listObjectsV2(input: ListObjectsV2Input(
        bucket: bucket,
        continuationToken: continuation,
        maxKeys: config["listMaxKeys"] as? Int ?? 1000
      ))
      for object in output.contents ?? [] {
        guard let key = object.key else { continue }
        _ = try await service.deleteObject(input: DeleteObjectInput(bucket: bucket, key: key))
        deleted += 1
      }
      continuation = output.isTruncated == true ? output.nextContinuationToken : nil
    } while continuation != nil
    return toolState(
      label: "delete-all",
      status: "Deleted \(deleted) object entry(s) from \(bucket).",
      lines: ["Deleted \(deleted) current object(s)."],
      exitCode: 0
    )
  }

  private func cancelTool(_ params: [String: Any]) -> [String: Any] {
    let id = params["jobId"] as? String ?? "tool"
    return toolState(
      label: id,
      status: "Cancelled tool execution \(id).",
      lines: ["Tool execution cancellation is best-effort on iOS."],
      exitCode: 130
    )
  }

  private func toolState(
    label: String,
    status: String,
    lines: [String],
    exitCode: Int
  ) -> [String: Any] {
    [
      "label": label,
      "running": false,
      "lastStatus": status,
      "jobId": "tool-\(label)-\(milliseconds())",
      "cancellable": false,
      "outputLines": lines,
      "exitCode": exitCode,
    ]
  }

  private func parseLifecycleRules(_ json: String) throws -> [S3ClientTypes.LifecycleRule] {
    guard let data = json.data(using: .utf8),
          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw EngineFailure(code: "invalid_config", message: "Lifecycle JSON must be an object.")
    }
    let values = root["Rules"] as? [[String: Any]] ?? []
    return values.enumerated().map { index, value in
      let expirationValue = value["Expiration"] as? [String: Any]
      let expirationDays = integer(expirationValue?["Days"] ?? value["ExpirationDays"])
      let deleteMarker = (expirationValue?["ExpiredObjectDeleteMarker"] as? Bool)
        ?? (value["DeleteExpiredObjectDeleteMarkers"] as? Bool)
      let expiration = expirationDays != nil || deleteMarker != nil
        ? S3ClientTypes.LifecycleExpiration(
            days: expirationDays,
            expiredObjectDeleteMarker: deleteMarker
          )
        : nil

      let transitions = (value["Transitions"] as? [[String: Any]] ?? []).compactMap {
        transition -> S3ClientTypes.Transition? in
        guard let storage = transition["StorageClass"] as? String else { return nil }
        return S3ClientTypes.Transition(
          days: integer(transition["Days"]),
          storageClass: S3ClientTypes.TransitionStorageClass(rawValue: storage)
        )
      }
      let noncurrentTransitions = (
        value["NoncurrentVersionTransitions"] as? [[String: Any]] ?? []
      ).compactMap { transition -> S3ClientTypes.NoncurrentVersionTransition? in
        guard let storage = transition["StorageClass"] as? String else { return nil }
        return S3ClientTypes.NoncurrentVersionTransition(
          noncurrentDays: integer(transition["NoncurrentDays"] ?? transition["Days"]),
          storageClass: S3ClientTypes.TransitionStorageClass(rawValue: storage)
        )
      }
      let noncurrentExpirationValue = value["NoncurrentVersionExpiration"] as? [String: Any]
      let noncurrentDays = integer(
        noncurrentExpirationValue?["NoncurrentDays"] ?? value["NonCurrentExpirationDays"]
      )
      let abortValue = value["AbortIncompleteMultipartUpload"] as? [String: Any]
      let abortDays = integer(
        abortValue?["DaysAfterInitiation"] ?? value["AbortIncompleteMultipartUploadDays"]
      )
      let prefix = value["Prefix"] as? String ?? value["prefix"] as? String ?? ""
      let status = value["Status"] as? String ?? "Enabled"
      return S3ClientTypes.LifecycleRule(
        abortIncompleteMultipartUpload: abortDays.map {
          S3ClientTypes.AbortIncompleteMultipartUpload(daysAfterInitiation: $0)
        },
        expiration: expiration,
        filter: S3ClientTypes.LifecycleRuleFilter(prefix: prefix),
        id: value["ID"] as? String ?? value["Id"] as? String ?? "rule-\(index + 1)",
        noncurrentVersionExpiration: noncurrentDays.map {
          S3ClientTypes.NoncurrentVersionExpiration(noncurrentDays: $0)
        },
        noncurrentVersionTransitions: noncurrentTransitions.isEmpty ? nil : noncurrentTransitions,
        status: S3ClientTypes.ExpirationStatus(rawValue: status),
        transitions: transitions.isEmpty ? nil : transitions
      )
    }
  }

  private func parseCorsRules(_ json: String) throws -> [S3ClientTypes.CORSRule] {
    guard let data = json.data(using: .utf8),
          let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      throw EngineFailure(code: "invalid_config", message: "CORS JSON must be an array.")
    }
    return values.map { value in
      S3ClientTypes.CORSRule(
        allowedHeaders: stringList(value["AllowedHeaders"]),
        allowedMethods: stringList(value["AllowedMethods"]),
        allowedOrigins: stringList(value["AllowedOrigins"]),
        exposeHeaders: stringList(value["ExposeHeaders"]),
        id: value["ID"] as? String,
        maxAgeSeconds: integer(value["MaxAgeSeconds"])
      )
    }
  }

  private func lifecycleRuleMap(_ rule: S3ClientTypes.LifecycleRule) -> [String: Any] {
    let transition = rule.transitions?.first
    let noncurrentTransition = rule.noncurrentVersionTransitions?.first
    return [
      "id": rule.id ?? "",
      "enabled": rule.status == .enabled,
      "prefix": rule.filter?.prefix ?? "",
      "expirationDays": codec(rule.expiration?.days),
      "deleteExpiredObjectDeleteMarkers": rule.expiration?.expiredObjectDeleteMarker ?? false,
      "transitionStorageClass": codec(transition?.storageClass?.rawValue),
      "transitionDays": codec(transition?.days),
      "nonCurrentExpirationDays": codec(rule.noncurrentVersionExpiration?.noncurrentDays),
      "nonCurrentTransitionStorageClass": codec(noncurrentTransition?.storageClass?.rawValue),
      "nonCurrentTransitionDays": codec(noncurrentTransition?.noncurrentDays),
      "abortIncompleteMultipartUploadDays": codec(
        rule.abortIncompleteMultipartUpload?.daysAfterInitiation
      ),
    ]
  }

  private func lifecycleRuleJSON(_ rule: S3ClientTypes.LifecycleRule) -> [String: Any] {
    var value: [String: Any] = [
      "ID": rule.id ?? "",
      "Status": rule.status?.rawValue ?? "Disabled",
      "Prefix": rule.filter?.prefix ?? "",
    ]
    if let expiration = rule.expiration {
      var item: [String: Any] = [:]
      if let days = expiration.days { item["Days"] = days }
      if let marker = expiration.expiredObjectDeleteMarker {
        item["ExpiredObjectDeleteMarker"] = marker
      }
      if !item.isEmpty { value["Expiration"] = item }
    }
    if let transitions = rule.transitions, !transitions.isEmpty {
      value["Transitions"] = transitions.map {
        ["Days": codec($0.days), "StorageClass": codec($0.storageClass?.rawValue)]
      }
    }
    if let transitions = rule.noncurrentVersionTransitions, !transitions.isEmpty {
      value["NoncurrentVersionTransitions"] = transitions.map {
        [
          "NoncurrentDays": codec($0.noncurrentDays),
          "StorageClass": codec($0.storageClass?.rawValue),
        ]
      }
    }
    if let expiration = rule.noncurrentVersionExpiration {
      value["NoncurrentVersionExpiration"] = [
        "NoncurrentDays": codec(expiration.noncurrentDays),
      ]
    }
    if let abort = rule.abortIncompleteMultipartUpload {
      value["AbortIncompleteMultipartUpload"] = [
        "DaysAfterInitiation": codec(abort.daysAfterInitiation),
      ]
    }
    return value
  }

  private func corsRuleMap(_ rule: S3ClientTypes.CORSRule) -> [String: Any] {
    [
      "ID": rule.id ?? "",
      "AllowedOrigins": rule.allowedOrigins ?? [],
      "AllowedMethods": rule.allowedMethods ?? [],
      "AllowedHeaders": rule.allowedHeaders ?? [],
      "ExposeHeaders": rule.exposeHeaders ?? [],
      "MaxAgeSeconds": rule.maxAgeSeconds ?? 0,
    ]
  }

  private func prettyJSON(_ value: Any, fallback: String) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let string = String(data: data, encoding: .utf8)
    else { return fallback }
    return string
  }

  private func stringList(_ value: Any?) -> [String] {
    (value as? [Any] ?? []).map { String(describing: $0) }
  }

  private func integer(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    return value as? Int
  }

  private func codec<T>(_ value: T?) -> Any {
    (value as Any?) ?? NSNull()
  }

  private func profile(_ params: [String: Any]) throws -> Profile {
    let values = params["profile"] as? [String: Any] ?? [:]
    let endpointType = values["endpointType"] as? String ?? "s3Compatible"
    guard endpointType != "azureBlob" else {
      throw EngineFailure(code: "unsupported_feature", message: "Azure Blob is not supported on iOS.")
    }
    let endpoint = try required(values, "endpointUrl", "Endpoint URL is required.")
    guard let url = URL(string: endpoint), url.scheme != nil else {
      throw EngineFailure(code: "invalid_config", message: "Endpoint URL is invalid.")
    }
    let accessKey = try required(values, "accessKey", "Access key is required.")
    let secretKey = try required(values, "secretKey", "Secret key is required.")
    return Profile(
      endpoint: endpoint,
      region: (values["region"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "us-east-1",
      accessKey: accessKey,
      secretKey: secretKey,
      sessionToken: values["sessionToken"] as? String,
      pathStyle: values["pathStyle"] as? Bool ?? true,
      maxAttempts: values["maxAttempts"] as? Int ?? 5
    )
  }

  private func client(_ profile: Profile) throws -> S3Client {
    let identity = AWSCredentialIdentity(
      accessKey: profile.accessKey,
      secret: profile.secretKey,
      sessionToken: profile.sessionToken
    )
    let resolver = StaticAWSCredentialIdentityResolver(identity)
    let configuration = try S3Client.S3ClientConfig(
      awsCredentialIdentityResolver: resolver,
      maxAttempts: profile.maxAttempts,
      region: profile.region,
      signingRegion: profile.region,
      forcePathStyle: profile.pathStyle,
      endpoint: profile.endpoint
    )
    return S3Client(config: configuration)
  }

  private func required(
    _ values: [String: Any],
    _ key: String,
    _ message: String
  ) throws -> String {
    guard let value = values[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw EngineFailure(code: "invalid_config", message: message)
    }
    return value
  }

  private func fileSize(_ path: String) throws -> Int {
    let values = try FileManager.default.attributesOfItem(atPath: path)
    return (values[.size] as? NSNumber)?.intValue ?? 0
  }

  private static func readFilePart(path: String, offset: Int, length: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    return handle.readData(ofLength: length)
  }

  private func waitUntilRunnable(_ job: TransferState) async throws {
    while job.status == "paused" {
      try await Task.sleep(nanoseconds: 150_000_000)
    }
  }

  private func clampedPartMiB(_ value: Int) -> Int {
    min(5 * 1024, max(5, value))
  }

  private func partWorkerCount(partCount: Int, partSizeBytes: Int) -> Int {
    let memoryBound = max(1, (512 * 1_048_576) / partSizeBytes)
    return min(4, min(partCount, memoryBound))
  }

  private func transferStrategy(total: Int, thresholdMiB: Int) -> String {
    total >= thresholdMiB * 1_048_576 ? "Multipart transfer" : "Single request"
  }

  private func join(prefix: String, name: String) -> String {
    guard !prefix.isEmpty else { return name }
    return prefix.hasSuffix("/") ? prefix + name : prefix + "/" + name
  }

  private func uniqueDestination(directory: String, fileName: String) -> URL {
    let manager = FileManager.default
    let base = URL(fileURLWithPath: directory).appendingPathComponent(fileName)
    guard manager.fileExists(atPath: base.path) else { return base }
    let stem = base.deletingPathExtension().lastPathComponent
    let ext = base.pathExtension
    for index in 1...9999 {
      let candidateName = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent(candidateName)
      if !manager.fileExists(atPath: candidate.path) { return candidate }
    }
    return URL(fileURLWithPath: directory)
      .appendingPathComponent("\(UUID().uuidString)-\(fileName)")
  }

  private func mapFailure(_ error: Error) -> EngineFailure {
    let message = error.localizedDescription
    let lower = message.lowercased()
    if lower.contains("credential") || lower.contains("signature") || lower.contains("forbidden") {
      return EngineFailure(code: "auth_failed", message: message)
    }
    if lower.contains("timed out") || lower.contains("timeout") {
      return EngineFailure(code: "timeout", message: message)
    }
    if lower.contains("ssl") || lower.contains("tls") || lower.contains("certificate") {
      return EngineFailure(code: "tls_error", message: message)
    }
    if lower.contains("throttl") || lower.contains("slowdown") {
      return EngineFailure(code: "throttled", message: message)
    }
    return EngineFailure(code: "unknown", message: message)
  }

  @objc private func didEnterBackground() {
    for transfer in transfers.values where transfer.status == "running" {
      transfer.status = "paused"
      backgroundPausedTransfers.insert(transfer.id)
      transfer.outputLines.append("Paused when iOS moved the app to the background.")
    }
  }

  @objc private func didBecomeActive() {
    let pausedIDs = backgroundPausedTransfers
    backgroundPausedTransfers.removeAll()
    for id in pausedIDs {
      guard let transfer = transfers[id], transfer.status == "paused" else { continue }
      transfer.status = "running"
      transfer.outputLines.append("Resumed when iOS returned to the foreground.")
    }
  }

  private func iso(_ date: Date?) -> String {
    ISO8601DateFormatter().string(from: date ?? Date(timeIntervalSince1970: 0))
  }

  private func milliseconds() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
  }
}

private struct Profile {
  let endpoint: String
  let region: String
  let accessKey: String
  let secretKey: String
  let sessionToken: String?
  let pathStyle: Bool
  let maxAttempts: Int
}

private struct EngineFailure: Error {
  let code: String
  let message: String

  var map: [String: Any] { ["code": code, "message": message] }
}

private enum TransferAction { case pause, resume, cancel }

private struct TransferCancelled: Error {}

private struct UploadedPart: Sendable {
  let partNumber: Int
  let etag: String
  let byteCount: Int
}

private struct DownloadedPart: Sendable {
  let offset: Int
  let data: Data
}

private final class TransferState {
  let id: String
  let label: String
  let direction: String
  var status = "running"
  var bytesTransferred = 0
  let totalBytes: Int
  let strategyLabel: String
  var currentItem: String?
  let itemCount: Int
  var itemsCompleted = 0
  let partSizeBytes: Int?
  var outputLines: [String] = []

  init(
    id: String,
    label: String,
    direction: String,
    totalBytes: Int,
    strategyLabel: String,
    currentItem: String?,
    itemCount: Int,
    partSizeBytes: Int?
  ) {
    self.id = id
    self.label = label
    self.direction = direction
    self.totalBytes = totalBytes
    self.strategyLabel = strategyLabel
    self.currentItem = currentItem
    self.itemCount = itemCount
    self.partSizeBytes = partSizeBytes
    outputLines = ["Started \(label)."]
  }

  func completeIfActive() {
    guard status != "cancelled" else { return }
    status = "completed"
    bytesTransferred = totalBytes
    outputLines.append("Transfer completed.")
  }

  var map: [String: Any] {
    let progress = totalBytes == 0 ? (status == "completed" ? 1.0 : 0.0)
      : min(1.0, Double(bytesTransferred) / Double(totalBytes))
    let partsTotal = partSizeBytes.map { max(1, (totalBytes + $0 - 1) / $0) }
    let partsCompleted = partSizeBytes.map { max(0, (bytesTransferred + $0 - 1) / $0) }
    return [
      "id": id,
      "label": label,
      "direction": direction,
      "progress": progress,
      "status": status,
      "bytesTransferred": bytesTransferred,
      "totalBytes": totalBytes,
      "strategyLabel": strategyLabel,
      "currentItemLabel": currentItem ?? NSNull(),
      "itemCount": itemCount,
      "itemsCompleted": itemsCompleted,
      "partSizeBytes": partSizeBytes ?? NSNull(),
      "partsCompleted": partsCompleted ?? NSNull(),
      "partsTotal": partsTotal ?? NSNull(),
      "canPause": status == "running",
      "canResume": status == "paused",
      "canCancel": status == "running" || status == "paused",
      "outputLines": outputLines,
    ]
  }
}
