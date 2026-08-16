import duplicateKeyValidator from "json-dup-key-validator";

import { WebCapsuleErrorCode, WebCapsuleFormatError } from "./errors.js";

export function parseJsonWithoutDuplicateKeys(text: string): unknown {
  const duplicateError = duplicateKeyValidator.validate(text, false);
  if (duplicateError !== undefined) {
    throw new WebCapsuleFormatError(
      WebCapsuleErrorCode.DuplicateJsonKey,
      duplicateError,
    );
  }

  try {
    return JSON.parse(text) as unknown;
  } catch (error: unknown) {
    throw new WebCapsuleFormatError(
      WebCapsuleErrorCode.InvalidJsonValue,
      error instanceof Error ? error.message : "Invalid JSON",
    );
  }
}
