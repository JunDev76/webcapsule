import { readFile, writeFile } from "node:fs/promises";

export interface ZipRecord {
  readonly central: number;
  readonly local: number;
  readonly name: Buffer;
  readonly centralName: number;
  readonly localName: number;
  readonly compressedData: number;
  readonly compressedSize: number;
}

function findEocd(bytes: Buffer): number {
  for (
    let offset = bytes.length - 22;
    offset >= Math.max(0, bytes.length - 65_557);
    offset--
  )
    if (bytes.readUInt32LE(offset) === 0x06054b50) return offset;
  throw new Error("EOCD not found");
}

export function records(bytes: Buffer): ZipRecord[] {
  const eocd = findEocd(bytes);
  const count = bytes.readUInt16LE(eocd + 10);
  let central = bytes.readUInt32LE(eocd + 16);
  const result: ZipRecord[] = [];
  for (let index = 0; index < count; index++) {
    if (bytes.readUInt32LE(central) !== 0x02014b50)
      throw new Error("central header not found");
    const nameLength = bytes.readUInt16LE(central + 28);
    const extraLength = bytes.readUInt16LE(central + 30);
    const commentLength = bytes.readUInt16LE(central + 32);
    const local = bytes.readUInt32LE(central + 42);
    if (bytes.readUInt32LE(local) !== 0x04034b50)
      throw new Error("local header not found");
    const localNameLength = bytes.readUInt16LE(local + 26);
    const localExtraLength = bytes.readUInt16LE(local + 28);
    result.push({
      central,
      local,
      name: Buffer.from(
        bytes.subarray(central + 46, central + 46 + nameLength),
      ),
      centralName: central + 46,
      localName: local + 30,
      compressedData: local + 30 + localNameLength + localExtraLength,
      compressedSize: bytes.readUInt32LE(central + 20),
    });
    central += 46 + nameLength + extraLength + commentLength;
  }
  return result;
}

export function replaceName(
  bytes: Buffer,
  index: number,
  name: Buffer,
  local = true,
): void {
  const record = records(bytes)[index]!;
  if (name.length !== record.name.length)
    throw new Error("replacement name must preserve length");
  name.copy(bytes, record.centralName);
  if (local) name.copy(bytes, record.localName);
}

export function set16(
  bytes: Buffer,
  index: number,
  area: "central" | "local",
  relative: number,
  value: number,
): void {
  const record = records(bytes)[index]!;
  bytes.writeUInt16LE(value, record[area] + relative);
}

export function set32(
  bytes: Buffer,
  index: number,
  area: "central" | "local",
  relative: number,
  value: number,
): void {
  const record = records(bytes)[index]!;
  bytes.writeUInt32LE(value >>> 0, record[area] + relative);
}

export function setArchiveComment(bytes: Buffer): Buffer {
  const eocd = findEocd(bytes);
  const output = Buffer.concat([bytes, Buffer.from("x")]);
  output.writeUInt16LE(1, eocd + 20);
  return output;
}

export function setEntryComment(bytes: Buffer, index: number): Buffer {
  const record = records(bytes)[index]!;
  const nameLength = bytes.readUInt16LE(record.central + 28);
  const extraLength = bytes.readUInt16LE(record.central + 30);
  const insert = record.central + 46 + nameLength + extraLength;
  const output = Buffer.concat([
    bytes.subarray(0, insert),
    Buffer.from("x"),
    bytes.subarray(insert),
  ]);
  output.writeUInt16LE(1, record.central + 32);
  const eocd = findEocd(output);
  output.writeUInt32LE(output.readUInt32LE(eocd + 12) + 1, eocd + 12);
  return output;
}

export async function mutateFile(
  path: string,
  mutate: (bytes: Buffer) => Buffer | void,
): Promise<void> {
  const bytes = Buffer.from(await readFile(path));
  const result = mutate(bytes);
  await writeFile(path, result ?? bytes);
}
