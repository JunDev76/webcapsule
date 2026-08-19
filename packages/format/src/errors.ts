export enum WebCapsuleErrorCode {
  InvalidJsonValue = "INVALID_JSON_VALUE",
  DuplicateJsonKey = "DUPLICATE_JSON_KEY",
  InvalidManifest = "INVALID_MANIFEST",
  InvalidUpdateIndex = "INVALID_UPDATE_INDEX",
  InvalidTimestamp = "INVALID_TIMESTAMP",
  InvalidPolicy = "INVALID_POLICY",
  InvalidUrl = "INVALID_URL",
  InvalidSignature = "INVALID_SIGNATURE",
  InvalidOrder = "INVALID_ORDER",
  UnsupportedFormatVersion = "UNSUPPORTED_FORMAT_VERSION",
  InvalidCapsuleId = "INVALID_CAPSULE_ID",
  InvalidKeyId = "INVALID_KEY_ID",
  InvalidVersion = "INVALID_VERSION",
  InvalidHash = "INVALID_HASH",
  InvalidMediaType = "INVALID_MEDIA_TYPE",
  InvalidPath = "INVALID_PATH",
  DuplicatePath = "DUPLICATE_PATH",
  CaseCollision = "CASE_COLLISION",
  UnicodeCollision = "UNICODE_COLLISION",
  LimitExceeded = "LIMIT_EXCEEDED",

  OutputExists = "OUTPUT_EXISTS",
  KeyGenerationFailed = "KEY_GENERATION_FAILED",
  InvalidArgument = "INVALID_ARGUMENT",
  InvalidInput = "INVALID_INPUT",
  InvalidPrivateKey = "INVALID_PRIVATE_KEY",
  InvalidPublicKey = "INVALID_PUBLIC_KEY",
  BuildFailed = "BUILD_FAILED",
  ArchiveInvalid = "ARCHIVE_INVALID",
  InvalidArchiveProfile = "INVALID_ARCHIVE_PROFILE",
  SignatureMismatch = "SIGNATURE_MISMATCH",
  HashMismatch = "HASH_MISMATCH",
  IdMismatch = "ID_MISMATCH",
  KeyIdMismatch = "KEY_ID_MISMATCH",
  RuntimeIncompatible = "RUNTIME_INCOMPATIBLE",

  BundledSourceInvalid = "BUNDLED_SOURCE_INVALID",
  BundledCapsuleUnavailable = "BUNDLED_CAPSULE_UNAVAILABLE",
  StorageIoFailed = "STORAGE_IO_FAILED",
  AtomicPublishUnsupported = "ATOMIC_PUBLISH_UNSUPPORTED",
  StorageInvariantViolation = "STORAGE_INVARIANT_VIOLATION",
  UnsafeStorageLayout = "UNSAFE_STORAGE_LAYOUT",
  RegistryInvalid = "REGISTRY_INVALID",
  RegistryRecoveryFailed = "REGISTRY_RECOVERY_FAILED",
  VersionRecordInvalid = "VERSION_RECORD_INVALID",
  BlobMissing = "BLOB_MISSING",
  InstallFailed = "INSTALL_FAILED",
  LockFailed = "LOCK_FAILED",
  NoRunnableVersion = "NO_RUNNABLE_VERSION",
  SessionMismatch = "SESSION_MISMATCH",
  ResourceDenied = "RESOURCE_DENIED",
  EntryLoadFailed = "ENTRY_LOAD_FAILED",
  ReadyMessageInvalid = "READY_MESSAGE_INVALID",
  ReadyTimeout = "READY_TIMEOUT",
  StabilizationFailed = "STABILIZATION_FAILED",
  NetworkFailed = "NETWORK_FAILED",
  NetworkTimeout = "NETWORK_TIMEOUT",
  HttpStatusInvalid = "HTTP_STATUS_INVALID",
  ContentLengthMismatch = "CONTENT_LENGTH_MISMATCH",
  UpdateInProgress = "UPDATE_IN_PROGRESS",
  UpdateTrialInProgress = "UPDATE_TRIAL_IN_PROGRESS",
  UpdateStateChanged = "UPDATE_STATE_CHANGED",
}

export class WebCapsuleFormatError extends Error {
  readonly code: WebCapsuleErrorCode;

  constructor(code: WebCapsuleErrorCode, message: string) {
    super(message);
    this.name = "WebCapsuleFormatError";
    this.code = code;
  }
}
