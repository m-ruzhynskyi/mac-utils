#!/bin/bash
# Генерирует синтетический .frm ~10 МБ с очень длинными строками и 8 знаками $ на строку.
# Файл НЕ хранить в репозитории. Использование: generate-big.sh [путь] [размер_в_байтах]
# По умолчанию: $TMPDIR/big-10mb.frm, 10485760 байт (10 МиБ). Кодировка cp1252/ASCII, EOL = CRLF.
# В stdout — путь файла; в stderr — число строк, число $ и размер (для сверки).
# Чтобы получить ожидаемое: на каждой строке 8 вхождений $vNNNNN, где NNNNN — глобальный номер.
set -euo pipefail

OUT="${1:-${TMPDIR:-/tmp}/big-10mb.frm}"
TARGET="${2:-10485760}"

nice -n 20 awk -v target="$TARGET" '
BEGIN {
  ORS = ""
  hdr = "{\\rtf1\\adeflang1025\\ansi\\ansicpg1252\\uc1\\deff0{\\fonttbl{\\f0\\fswiss\\fcharset0 Arial;}}{\\colortbl;\\red0\\green0\\blue0;}\\viewkind1\\f0\\fs20\r\n"
  print hdr
  size = length(hdr)
  base = "lorem ipsum dolor sit amet "
  seg = ""
  while (length(seg) < 2500) seg = seg base
  seg = substr(seg, 1, 2500)
  lines = 0; n = 0
  while (size < target) {
    line = "\\pard "
    for (k = 0; k < 8; k++) {
      n++
      line = line seg sprintf("$v%05d ", n)
    }
    line = line "\\par\r\n"
    print line
    size += length(line)
    lines++
  }
  tail = "}\r\n"
  print tail
  size += length(tail)
  printf("lines=%d dollars=%d bytes=%d\n", lines + 1, n, size) > "/dev/stderr"
}' > "$OUT"

echo "$OUT"
