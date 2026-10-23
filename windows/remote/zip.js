// Минимальное чтение и запись ZIP (хватает для .xlsx): центральный каталог, методы stored и deflate. Без Zip64 и шифрования;
// размеры ограничены, чтобы «бомба» не съела память. 1:1 с Mac (`ZipArchive.swift`, `ZipWriter.swift`).
"use strict";

const zlib = require("node:zlib");
const { ConnectionsError } = require("./models");

const MAX_ENTRY_SIZE = 128 << 20;
const MAX_ENTRIES = 10_000;
const corrupt = (text) => new ConnectionsError("corrupt", text);

class ZipArchive {
  constructor(data) {
    this.data = data;
    this.entries = new Map();
    const eocd = findEndOfDirectory(data);
    if (eocd < 0) throw corrupt("Не ZIP-архив");
    const count = u16(data, eocd + 10);
    const dirOffset = u32(data, eocd + 16);
    if (count > MAX_ENTRIES && count !== 0xFFFF) throw corrupt("Слишком много файлов в архиве");
    if (count === 0xFFFF || dirOffset === 0xFFFFFFFF) throw corrupt("Zip64 не поддерживается");
    let pos = dirOffset;
    for (let i = 0; i < count; i++) {
      if (u32(data, pos) !== 0x02014b50) throw corrupt("Повреждён каталог архива");
      const flags = u16(data, pos + 8), method = u16(data, pos + 10);
      const compressedSize = u32(data, pos + 20), uncompressedSize = u32(data, pos + 24);
      const nameLen = u16(data, pos + 28), extraLen = u16(data, pos + 30), commentLen = u16(data, pos + 32);
      const localOffset = u32(data, pos + 42);
      if (pos + 46 + nameLen > data.length) throw corrupt("Повреждён каталог архива");
      const name = data.toString("utf8", pos + 46, pos + 46 + nameLen);
      this.entries.set(name, { name, method, flags, compressedSize, uncompressedSize, localOffset });
      pos += 46 + nameLen + extraLen + commentLen;
    }
  }

  // Содержимое файла архива (Buffer); null — такого файла нет.
  contents(name) {
    const e = this.entries.get(name);
    if (!e) return null;
    if (e.flags & 1) throw corrupt("Файл защищён паролем");
    if (e.uncompressedSize > MAX_ENTRY_SIZE) throw new ConnectionsError("tooLarge");
    if (u32(this.data, e.localOffset) !== 0x04034b50) throw corrupt("Повреждён заголовок файла в архиве");
    const start = e.localOffset + 30 + u16(this.data, e.localOffset + 26) + u16(this.data, e.localOffset + 28);
    if (start < 0 || start + e.compressedSize > this.data.length) throw corrupt("Архив обрезан");
    const packed = this.data.subarray(start, start + e.compressedSize);
    if (e.method === 0) return Buffer.from(packed);
    if (e.method === 8) {
      if (e.uncompressedSize === 0) return Buffer.alloc(0);
      let out;
      try { out = zlib.inflateRawSync(packed, { maxOutputLength: e.uncompressedSize + 1 }); }
      catch (_) { throw corrupt("Не удалось распаковать данные"); }
      if (out.length !== e.uncompressedSize) throw corrupt("Не удалось распаковать данные");
      return out;
    }
    throw corrupt(`Метод сжатия ${e.method} не поддерживается`);
  }
}

function findEndOfDirectory(data) {
  if (data.length < 22) return -1;
  const lowest = Math.max(0, data.length - 22 - 0xFFFF);
  for (let i = data.length - 22; i >= lowest; i--) if (data.readUInt32LE(i) === 0x06054b50) return i;
  return -1;
}
function u16(d, at) { if (at < 0 || at + 2 > d.length) throw corrupt("Архив обрезан"); return d.readUInt16LE(at); }
function u32(d, at) { if (at < 0 || at + 4 > d.length) throw corrupt("Архив обрезан"); return d.readUInt32LE(at); }

// ---- запись (шаблон «Создать шаблон» и фикстуры тестов) ----

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; table[n] = c >>> 0; }
  return table;
})();
function crc32(buffer) {
  let c = 0xFFFFFFFF;
  for (let i = 0; i < buffer.length; i++) c = CRC_TABLE[(c ^ buffer[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}

class ZipWriter {
  constructor() { this.files = []; }
  add(name, content, { compress = true } = {}) { this.files.push({ name, data: Buffer.isBuffer(content) ? content : Buffer.from(content, "utf8"), compress }); }
  finish() {
    const chunks = [], central = [];
    let offset = 0;
    for (const f of this.files) {
      const crc = crc32(f.data);
      const packed = f.compress ? zlib.deflateRawSync(f.data) : f.data;
      const method = f.compress ? 8 : 0;
      const name = Buffer.from(f.name, "utf8");
      const local = Buffer.alloc(30);
      local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(0x0800, 6); local.writeUInt16LE(method, 8);
      local.writeUInt32LE(crc, 14); local.writeUInt32LE(packed.length, 18); local.writeUInt32LE(f.data.length, 22); local.writeUInt16LE(name.length, 26);
      chunks.push(local, name, packed);
      const dir = Buffer.alloc(46);
      dir.writeUInt32LE(0x02014b50, 0); dir.writeUInt16LE(20, 4); dir.writeUInt16LE(20, 6); dir.writeUInt16LE(0x0800, 8); dir.writeUInt16LE(method, 10);
      dir.writeUInt32LE(crc, 16); dir.writeUInt32LE(packed.length, 20); dir.writeUInt32LE(f.data.length, 24); dir.writeUInt16LE(name.length, 28);
      dir.writeUInt32LE(offset, 42);
      central.push(dir, name);
      offset += 30 + name.length + packed.length;
    }
    const dirSize = central.reduce((n, b) => n + b.length, 0);
    const end = Buffer.alloc(22);
    end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(this.files.length, 8); end.writeUInt16LE(this.files.length, 10);
    end.writeUInt32LE(dirSize, 12); end.writeUInt32LE(offset, 16);
    return Buffer.concat([...chunks, ...central, end]);
  }
}

module.exports = { ZipArchive, ZipWriter, crc32 };
