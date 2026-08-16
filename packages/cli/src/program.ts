import { readFile } from "node:fs/promises";

import { Command } from "commander";

import { buildCapsule } from "./build.js";
import { WebCapsuleCliError, WebCapsuleCliErrorCode } from "./errors.js";
import { generateKeys } from "./keygen.js";
import { inspectCapsule } from "./inspect.js";
import { createUpdateIndex } from "./update-index.js";
import { verifyCapsule } from "./verify.js";

export interface ProgramOutput {
  readonly write: (text: string) => void;
}

export function createProgram(output: ProgramOutput): Command {
  const program = new Command();

  program.enablePositionalOptions();

  program
    .name("webcapsule")
    .description("Build and verify WebCapsule artifacts")
    .version("0.0.0");

  program
    .command("build")
    .description("Build a deterministic signed capsule")
    .argument("<input-directory>", "input content directory")
    .requiredOption("--id <capsule-id>", "capsule identifier")
    .requiredOption("--version <semver>", "capsule version")
    .requiredOption("--entry <path>", "entry document path")
    .requiredOption(
      "--minimum-runtime-version <semver>",
      "minimum compatible runtime version",
    )
    .requiredOption("--key-id <id>", "signing key identifier")
    .requiredOption("--private-key <pkcs8-pem>", "Ed25519 private key path")
    .requiredOption("--out <capsule-path>", "output capsule path")
    .option("--created-at <timestamp>", "strict UTC build timestamp")
    .action(
      async (
        inputDirectory: string,
        options: {
          id: string;
          version: string;
          entry: string;
          minimumRuntimeVersion: string;
          keyId: string;
          privateKey: string;
          out: string;
          createdAt?: string;
        },
      ) => {
        const sourceDateEpoch = process.env.SOURCE_DATE_EPOCH;
        const manifest = await buildCapsule({
          inputDirectory,
          ...options,
          ...(sourceDateEpoch === undefined ? {} : { sourceDateEpoch }),
        });
        output.write(`Built ${options.out}\n`);
        output.write(`${manifest.capsuleId}@${manifest.version}\n`);
      },
    );

  program
    .command("verify")
    .description("Verify a capsule and every content byte")
    .argument("<capsule>", "capsule path")
    .requiredOption("--public-key <spki-pem>", "Ed25519 public key path")
    .option("--expected-id <id>", "required capsule identifier")
    .option("--expected-key-id <id>", "required signing key identifier")
    .option("--runtime-version <semver>", "runtime compatibility version")
    .option("--json", "write stable JSON")
    .action(
      async (
        capsule: string,
        options: {
          publicKey: string;
          expectedId?: string;
          expectedKeyId?: string;
          runtimeVersion?: string;
          json?: boolean;
        },
      ) => {
        const publicKey = await readFile(options.publicKey, "utf8").catch(
          (cause: unknown) => {
            throw new WebCapsuleCliError(
              WebCapsuleCliErrorCode.InvalidPublicKey,
              `Cannot read public key: ${options.publicKey}`,
              { cause },
            );
          },
        );
        const result = await verifyCapsule(capsule, {
          publicKey,
          ...(options.expectedId === undefined
            ? {}
            : { expectedId: options.expectedId }),
          ...(options.expectedKeyId === undefined
            ? {}
            : { expectedKeyId: options.expectedKeyId }),
          ...(options.runtimeVersion === undefined
            ? {}
            : { runtimeVersion: options.runtimeVersion }),
        });
        if (options.json)
          output.write(`${JSON.stringify({ verified: true, ...result })}\n`);
        else output.write(`Verified ${result.capsuleId}@${result.version}\n`);
      },
    );

  program
    .command("inspect")
    .description("Inspect capsule metadata without establishing trust")
    .argument("<capsule>", "capsule path")
    .option("--json", "write stable JSON")
    .action(async (capsule: string, options: { json?: boolean }) => {
      const result = await inspectCapsule(capsule);
      if (options.json) output.write(`${JSON.stringify(result)}\n`);
      else {
        output.write("Unverified capsule metadata\n");
        output.write(
          `${result.capsuleId}@${result.version} (${result.fileCount} files, ${result.declaredBytes} bytes)\n`,
        );
      }
    });

  program
    .command("index")
    .description("Create a signed update index")
    .requiredOption("--id <capsule-id>", "capsule identifier")
    .requiredOption("--channel <channel>", "update channel")
    .requiredOption("--key-id <id>", "signing key identifier")
    .requiredOption("--private-key <pkcs8-pem>", "Ed25519 private key path")
    .requiredOption(
      "--release <descriptor.json>",
      "strict release descriptor (repeatable)",
      (value: string, previous: string[]) => [...previous, value],
      [],
    )
    .requiredOption("--out <index.json>", "output index path")
    .action(
      async (options: {
        id: string;
        channel: string;
        keyId: string;
        privateKey: string;
        release: string[];
        out: string;
      }) => {
        const result = await createUpdateIndex({
          id: options.id,
          channel: options.channel,
          keyId: options.keyId,
          privateKey: options.privateKey,
          releases: options.release,
          out: options.out,
        });
        output.write(`Created ${result.outputPath}\n`);
        output.write(
          `${result.capsuleId} ${result.channel} ${result.releaseCount} releases\n`,
        );
      },
    );

  program
    .command("keygen")
    .description("Generate an Ed25519 signing key pair")
    .requiredOption("--out <directory>", "output directory")
    .action(async (options: { out: string }) => {
      const result = await generateKeys(options.out);
      output.write(`Fingerprint: ${result.fingerprint}\n`);
      output.write(`Private key: ${result.privateKeyPath}\n`);
      output.write(`Public key: ${result.publicKeyPath}\n`);
    });

  return program;
}
