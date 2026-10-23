// Пароль в байтах вне строк JS: затирается fill(0) и после использования, и по явному wipe(). Не печатается.
"use strict";

class SecretBuffer {
  constructor(text) { this.bytes = Buffer.from(text, "utf8"); }
  get length() { return this.bytes.length; }
  wipe() { this.bytes.fill(0); }
  get isWiped() { return this.bytes.every((b) => b === 0); }
  toString() { return "[секрет]"; }
  toJSON() { return "[секрет]"; }
  [Symbol.for("nodejs.util.inspect.custom")]() { return "[секрет]"; }
}

module.exports = { SecretBuffer };
