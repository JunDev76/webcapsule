export const FORMAT_VERSION = 1 as const;
export const UPDATE_INDEX_SCHEMA_VERSION = 1 as const;

export const MANIFEST_SIGNATURE_DOMAIN = "WEBCAPSULE-MANIFEST-V1\n";
export const UPDATE_INDEX_SIGNATURE_DOMAIN = "WEBCAPSULE-UPDATE-INDEX-V1\n";

export const CAPSULE_LIMITS = {
  archiveBytes: 100 * 1024 * 1024,
  expandedBytes: 250 * 1024 * 1024,
  fileBytes: 50 * 1024 * 1024,
  fileCount: 10_000,
} as const;
