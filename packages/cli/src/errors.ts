export enum WebCapsuleCliErrorCode {
  OutputExists = "OUTPUT_EXISTS",
  KeyGenerationFailed = "KEY_GENERATION_FAILED",
  InvalidArgument = "INVALID_ARGUMENT",
  InvalidTimestamp = "INVALID_TIMESTAMP",
  InvalidInput = "INVALID_INPUT",
  InvalidPrivateKey = "INVALID_PRIVATE_KEY",
  InvalidPublicKey = "INVALID_PUBLIC_KEY",
  LimitExceeded = "LIMIT_EXCEEDED",
  BuildFailed = "BUILD_FAILED",
  ArchiveInvalid = "ARCHIVE_INVALID",
  InvalidArchiveProfile = "INVALID_ARCHIVE_PROFILE",
  SignatureMismatch = "SIGNATURE_MISMATCH",
  HashMismatch = "HASH_MISMATCH",
  IdMismatch = "ID_MISMATCH",
  KeyIdMismatch = "KEY_ID_MISMATCH",
  RuntimeIncompatible = "RUNTIME_INCOMPATIBLE",
}

export class WebCapsuleCliError extends Error {
  readonly code: WebCapsuleCliErrorCode;

  constructor(
    code: WebCapsuleCliErrorCode,
    message: string,
    options?: ErrorOptions,
  ) {
    super(message, options);
    this.name = "WebCapsuleCliError";
    this.code = code;
  }
}
