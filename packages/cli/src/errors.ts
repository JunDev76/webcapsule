import { WebCapsuleErrorCode } from "@webcapsule/format";

export const WebCapsuleCliErrorCode = {
  OutputExists: WebCapsuleErrorCode.OutputExists,
  KeyGenerationFailed: WebCapsuleErrorCode.KeyGenerationFailed,
  InvalidArgument: WebCapsuleErrorCode.InvalidArgument,
  InvalidTimestamp: WebCapsuleErrorCode.InvalidTimestamp,
  InvalidInput: WebCapsuleErrorCode.InvalidInput,
  InvalidPrivateKey: WebCapsuleErrorCode.InvalidPrivateKey,
  InvalidPublicKey: WebCapsuleErrorCode.InvalidPublicKey,
  LimitExceeded: WebCapsuleErrorCode.LimitExceeded,
  BuildFailed: WebCapsuleErrorCode.BuildFailed,
  ArchiveInvalid: WebCapsuleErrorCode.ArchiveInvalid,
  InvalidArchiveProfile: WebCapsuleErrorCode.InvalidArchiveProfile,
  SignatureMismatch: WebCapsuleErrorCode.SignatureMismatch,
  HashMismatch: WebCapsuleErrorCode.HashMismatch,
  IdMismatch: WebCapsuleErrorCode.IdMismatch,
  KeyIdMismatch: WebCapsuleErrorCode.KeyIdMismatch,
  RuntimeIncompatible: WebCapsuleErrorCode.RuntimeIncompatible,
} as const;

export type WebCapsuleCliErrorCode = WebCapsuleErrorCode;

export class WebCapsuleCliError extends Error {
  readonly code: WebCapsuleErrorCode;

  constructor(
    code: WebCapsuleErrorCode,
    message: string,
    options?: ErrorOptions,
  ) {
    super(message, options);
    this.name = "WebCapsuleCliError";
    this.code = code;
  }
}
