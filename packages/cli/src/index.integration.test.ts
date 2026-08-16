import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

const execute = promisify(execFile);
const packageDirectory = resolve(import.meta.dirname, "..");
const executable = join(packageDirectory, "dist/index.js");
const directories: string[] = [];

beforeAll(async () => {
  await execute("pnpm", ["build"], { cwd: packageDirectory });
});

afterAll(async () => {
  await Promise.all(
    directories.map((path) => rm(path, { recursive: true, force: true })),
  );
});

async function outputDirectory(): Promise<string> {
  const parent = await mkdtemp(join(tmpdir(), "webcapsule-cli-"));
  directories.push(parent);
  return join(parent, "keys");
}

describe("webcapsule build", () => {
  it("builds through the executable and reports stable errors", async () => {
    const parent = await mkdtemp(join(tmpdir(), "webcapsule-cli-build-"));
    directories.push(parent);
    const input = join(parent, "input");
    const keys = join(parent, "keys");
    await mkdir(input);
    await writeFile(join(input, "index.html"), "hello");
    await execute(executable, ["keygen", "--out", keys]);
    const output = join(parent, "app.capsule");
    const arguments_ = [
      "build",
      input,
      "--id",
      "com.example.app",
      "--version",
      "1.0.0",
      "--entry",
      "index.html",
      "--minimum-runtime-version",
      "1.0.0",
      "--key-id",
      "release",
      "--private-key",
      join(keys, "private.pem"),
      "--out",
      output,
      "--created-at",
      "2026-08-16T10:00:02Z",
    ];
    const result = await execute(executable, arguments_);
    expect(result.stderr).toBe("");
    expect(result.stdout).toBe(`Built ${output}\ncom.example.app@1.0.0\n`);
    expect((await readFile(output)).length).toBeGreaterThan(0);

    try {
      await execute(executable, arguments_);
      throw new Error("expected build to fail");
    } catch (error: unknown) {
      expect(error).toBeInstanceOf(Error);
      const failure = error as Error & { code?: number; stderr?: string };
      expect(failure.code).toBe(1);
      expect(failure.stderr).toContain("OUTPUT_EXISTS:");
    }
  });
});

describe("webcapsule stable file errors", () => {
  it("reports a missing public key without a raw stack", async () => {
    try {
      await execute(executable, [
        "verify",
        "missing.capsule",
        "--public-key",
        "missing-public.pem",
      ]);
      throw new Error("expected verify to fail");
    } catch (error: unknown) {
      const result = error as Error & { code?: number; stderr?: string };
      expect(result.code).toBe(1);
      expect(result.stderr).toBe(
        "INVALID_PUBLIC_KEY: Cannot read public key: missing-public.pem\n",
      );
      expect(result.stderr).not.toContain(" at ");
    }
  });

  it("reports a missing release descriptor without a raw stack", async () => {
    const directory = await outputDirectory();
    await execute(executable, ["keygen", "--out", directory]);
    try {
      await execute(executable, [
        "index",
        "--id",
        "com.example.app",
        "--channel",
        "stable",
        "--key-id",
        "release",
        "--private-key",
        join(directory, "private.pem"),
        "--release",
        join(directory, "missing-release.json"),
        "--out",
        join(directory, "index.json"),
      ]);
      throw new Error("expected index to fail");
    } catch (error: unknown) {
      const result = error as Error & { code?: number; stderr?: string };
      expect(result.code).toBe(1);
      expect(result.stderr).toMatch(/^INVALID_INPUT: /);
      expect(result.stderr).not.toContain(" at ");
    }
  });
});

describe("webcapsule keygen", () => {
  it("runs the built executable and reports only fingerprint and paths", async () => {
    const directory = await outputDirectory();
    const { stdout, stderr } = await execute(executable, [
      "keygen",
      "--out",
      directory,
    ]);

    expect(stderr).toBe("");
    expect(stdout).toMatch(/^Fingerprint: [0-9a-f]{64}\n/);
    expect(stdout).toContain(
      `Private key: ${join(directory, "private.pem")}\n`,
    );
    expect(stdout).toContain(`Public key: ${join(directory, "public.pem")}\n`);
    expect(stdout).not.toContain("BEGIN");
    await expect(
      readFile(join(directory, "private.pem"), "utf8"),
    ).resolves.toContain("BEGIN PRIVATE KEY");
  });

  it("fails with a commander usage error when --out is missing", async () => {
    try {
      await execute(executable, ["keygen"]);
      throw new Error("expected keygen to fail");
    } catch (error: unknown) {
      expect(error).toBeInstanceOf(Error);
      const result = error as Error & { code?: number; stderr?: string };
      expect(result.code).toBe(1);
      expect(result.stderr).toContain(
        "required option '--out <directory>' not specified",
      );
    }
  });
});
