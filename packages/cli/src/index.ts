#!/usr/bin/env node

import { WebCapsuleFormatError } from "@webcapsule/format";

import { WebCapsuleCliError } from "./errors.js";
import { createProgram } from "./program.js";

const program = createProgram({
  write(text) {
    process.stdout.write(text);
  },
});

try {
  await program.parseAsync(process.argv);
} catch (error) {
  if (
    error instanceof WebCapsuleCliError ||
    error instanceof WebCapsuleFormatError
  ) {
    process.stderr.write(`${error.code}: ${error.message}\n`);
    process.exitCode = 1;
  } else {
    throw error;
  }
}
