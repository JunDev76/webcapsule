export const capsuleManifestSchema = {
  $id: "urn:webcapsule:schema:capsule-manifest:v1",
  $schema: "https://json-schema.org/draft/2020-12/schema",
  type: "object",
  additionalProperties: false,
  required: [
    "formatVersion",
    "capsuleId",
    "version",
    "entry",
    "createdAt",
    "minimumRuntimeVersion",
    "keyId",
    "files",
    "policy",
  ],
  properties: {
    formatVersion: { const: 1 },
    capsuleId: { type: "string", minLength: 3, maxLength: 255 },
    version: { type: "string" },
    entry: { type: "string", minLength: 1 },
    createdAt: { type: "string", format: "date-time" },
    minimumRuntimeVersion: { type: "string" },
    keyId: { type: "string", minLength: 1, maxLength: 128 },
    files: {
      type: "array",
      maxItems: 10_000,
      items: {
        type: "object",
        additionalProperties: false,
        required: ["path", "sha256", "size", "mediaType"],
        properties: {
          path: { type: "string", minLength: 1 },
          sha256: { type: "string", pattern: "^[0-9a-f]{64}$" },
          size: { type: "integer", minimum: 0, maximum: 52_428_800 },
          mediaType: { type: "string", minLength: 3 },
        },
      },
    },
    policy: {
      type: "object",
      additionalProperties: false,
      required: ["network", "navigation", "bridgeCapabilities"],
      properties: {
        network: {
          type: "object",
          additionalProperties: false,
          required: ["mode"],
          properties: {
            mode: { enum: ["deny", "allowlist"] },
            origins: {
              type: "array",
              items: { type: "string", format: "uri" },
            },
          },
        },
        navigation: {
          type: "object",
          additionalProperties: false,
          required: ["externalOrigins"],
          properties: {
            externalOrigins: {
              type: "array",
              items: { type: "string", format: "uri" },
            },
          },
        },
        bridgeCapabilities: {
          type: "array",
          items: { type: "string" },
          uniqueItems: true,
        },
      },
    },
  },
} as const;

export const updateIndexSchema = {
  $id: "urn:webcapsule:schema:update-index:v1",
  $schema: "https://json-schema.org/draft/2020-12/schema",
  type: "object",
  additionalProperties: false,
  required: [
    "schemaVersion",
    "capsuleId",
    "channel",
    "releases",
    "keyId",
    "signature",
  ],
  properties: {
    schemaVersion: { const: 1 },
    capsuleId: { type: "string", minLength: 3, maxLength: 255 },
    channel: { type: "string", minLength: 1, maxLength: 64 },
    keyId: { type: "string", minLength: 1, maxLength: 128 },
    signature: { type: "string", minLength: 88, maxLength: 88 },
    releases: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["version", "url", "sha256", "size", "minimumRuntimeVersion"],
        properties: {
          version: { type: "string" },
          url: { type: "string", format: "uri", pattern: "^https://" },
          sha256: { type: "string", pattern: "^[0-9a-f]{64}$" },
          size: { type: "integer", minimum: 0, maximum: 104_857_600 },
          minimumRuntimeVersion: { type: "string" },
        },
      },
    },
  },
} as const;
