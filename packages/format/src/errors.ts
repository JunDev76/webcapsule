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
}

export class WebCapsuleFormatError extends Error {
  readonly code: WebCapsuleErrorCode;

  constructor(code: WebCapsuleErrorCode, message: string) {
    super(message);
    this.name = "WebCapsuleFormatError";
    this.code = code;
  }
}
