#!/usr/bin/env python3
"""Генератор демо-файлов .frm и expected.json для приёмки текстового редактора.

Только выдуманные данные. Запуск: python3 -I make_fixtures.py (из любой папки).
Эталонная реализация здесь НЕ зависит от кода редактора.

Правило значения: символы после `$` до пробельного (пробел, \\t, \\r, \\n),
одного из `\\ { } $ ;` или конца файла. Значение может быть пустым.
Смещения — в Unicode-скалярах декодированного текста (в фикстурах только BMP,
значит совпадают с UTF-16 единицами NSString). CRLF считается двумя символами.
"""
import hashlib
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
SKIP_N = 3
WS = " \t\r\n"
# Правило 1.7.1 (окончательное): значение — до пробельного символа (пробел, TAB, CR, LF) или следующего $;
# \ { } ; и прочие видимые символы входят.
STOP = WS + "$"


def header(cp="1252"):
    return (
        "{\\rtf1\\adeflang1025\\ansi\\ansicpg%s\\uc1\\adeff0\\deff0\\stshfdbch0"
        "\\stshfloch0\\stshfhich0\\stshfbi0\\deflang1033\\deflangfe1033"
        "{\\fonttbl{\\f0\\froman\\fcharset0\\fprq2 Times New Roman;}"
        "{\\f1\\fswiss\\fcharset0\\fprq2 Arial;}"
        "{\\f2\\fmodern\\fcharset0\\fprq1 Courier New;}}"
        "{\\colortbl;\\red0\\green0\\blue0;\\red255\\green0\\blue0;}"
        "{\\info{\\title Demo form}{\\author Demo Author}}"
        "\\paperw11906\\paperh16838\\margl1134\\margr1134\\viewkind1\\f1\\fs20" % cp
    )


def build(body, eol="\n", cp="1252", tail="}"):
    """Склеить RTF: заголовок + тело (строки через \\n) + хвост. EOL подменяется."""
    text = header(cp) + "\n" + body + tail
    assert "$" not in header(cp)
    return text.replace("\n", eol)


def scan(text):
    """Эталонное правило: [(offset, value)] по порядку."""
    out = []
    n = len(text)
    for i, ch in enumerate(text):
        if ch != "$":
            continue
        j = i + 1
        while j < n and text[j] not in STOP:
            j += 1
        out.append((i, text[i + 1 : j]))
    return out


def line_col(text, off):
    """1-based строка и столбец; разделители CRLF | LF | CR."""
    line, col, i = 1, 1, 0
    while i < off:
        c = text[i]
        if c == "\r" and i + 1 < len(text) and text[i + 1] == "\n":
            if i + 1 >= off:  # смещение указывает внутрь CRLF — не бывает для '$'
                break
            i += 2
            line, col = line + 1, 1
            continue
        if c in "\r\n":
            line, col = line + 1, 1
        else:
            col += 1
        i += 1
    return line, col


def strip(text, occs, which):
    """Убрать значения у occs[k] для k из which, '$' оставить."""
    res, pos = [], 0
    for k, (off, val) in enumerate(occs):
        if k in which:
            res.append(text[pos : off + 1])
            pos = off + 1 + len(val)
    res.append(text[pos:])
    return "".join(res)


def detect_eol(data):
    crlf = data.count(b"\r\n")
    lf = data.count(b"\n") - crlf
    cr = data.count(b"\r") - crlf
    kinds = [k for k, c in (("CRLF", crlf), ("LF", lf), ("CR", cr)) if c]
    return kinds[0] if len(kinds) == 1 else ("mixed:" + "+".join(kinds) if kinds else "none")


def sha(b):
    return hashlib.sha256(b).hexdigest()


# --- содержимое случаев --------------------------------------------------

CASES = []  # (имя, байты, кодек, bom, eol, описание)


def add(name, text, codec, eol, desc, bom=False):
    data = text.replace("\n", eol).encode(codec) if text is not None else None
    if bom and data is not None:
        data = b"\xef\xbb\xbf" + data
    CASES.append((name, data, codec, bom, eol, desc))


add("01-three-dollars.frm",
    build("\\pard Name: $FIRST \\par\nCity: $CITY\\par\nZip: $ZIP91000\\par\n"),
    "cp1252", "\r\n", "Ровно 3 знака $: при пропуске 3 подсвеченных нет.")

add("02-four-dollars.frm",
    build("\\pard $A1 \\par\n$B2\\par\n$C3;\n$D4{}\\par\n"),
    "cp1252", "\r\n", "4 знака $: при пропуске 3 подсвечен только четвёртый.")

add("03-zero-dollars.frm",
    build("\\pard Plain form without any markers \\par\nSecond line\\par\n"),
    "cp1252", "\r\n", "Нет ни одного $.")

add("04-dollar-at-eof.frm",
    build("\\pard $A \\par\n$B \\par\n$C \\par\n$D \\par\n", tail="}\n$"),
    "cp1252", "\n", "Файл заканчивается на '$' (пустое значение в конце).")

add("04b-value-at-eof.frm",
    build("\\pard $A \\par\n$B \\par\n$C \\par\n", tail="}\n$tailvalue"),
    "cp1252", "\n", "Файл заканчивается значением без перевода строки.")

add("05-double-dollar.frm",
    build("\\pard $$X Y\\par\n$$$ end\\par\n$a$b$c \\par\n"),
    "cp1252", "\r\n", "$$ и $$$: значение обрывается следующим $. Цепочки $a$b$c.")

add("06-terminators.frm",
    build("\\pard v1:$AAA\\par v2:{$BBB} v3:$CCC;v4:$DDD v5:$EEE\nv6:$FFF\tv7:$GGG\\b0 v8:$HHH}\n"),
    "cp1252", "\n",
    "Завершители значения: \\par, }, ;, пробел, LF, TAB, обратная косая, закрывающая скобка.")

add("07-empty-values.frm",
    build("\\pard e1:$ e2:$\\par e3:${x} e4:$; e5:$}e6:$\r\ne7:$\\'e9\n"),
    "cp1252", "\n", "Пустые значения перед пробелом, \\par, {, ;, }, CR+LF, \\'xx.")

add("08-long-line.frm", None, "cp1252", "\r\n",
    "Строка >10 000 символов с $ в позициях ~9990, ~10005 и ~20000, плюс 4-й в конце.")

add("09-crlf.frm",
    build("\\pard Line one $one \\par\nLine two $two \\par\n\nLine four $four\\par\n$five\n"),
    "cp1252", "\r\n", "Чистый CRLF, пустая строка в середине.")

add("10-lf.frm",
    build("\\pard Line one $one \\par\nLine two $two \\par\n\nLine four $four\\par\n$five\n"),
    "cp1252", "\n", "Чистый LF; то же содержимое, что и в 09.")

add("10b-cr-only.frm",
    build("\\pard Line one $one \\par\nLine two $two \\par\n\nLine four $four\\par\n$five\n"),
    "cp1252", "\r", "Старый Mac: только CR.")

add("11-cp1252-high-bytes.frm",
    build("\\pard Preis: $EUR\u20ac12 \\par\nStra\u00dfe: $M\u00fcller\\par\n"
          "Zitat: \u201e$quote\u201c \\par\n\u201e\u201c $x\u00fcb;\n"
          "Raw: $\u00dfa\u00dfb \\par\nEsc: $a\\'e9b \\par\n"),
    "cp1252", "\r\n",
    "Байты 0x80-0xFF cp1252: €(80) ü(FC) ß(DF) „(84) “(93) ”(94); значения с не-ASCII.")

add("12-utf8-bom.frm",
    build("\\pard UTF-8 BOM: $\u00fcber $\u0436\u0443\u043a \\par\n$\u20acuro \\par\n$last\n"),
    "utf-8", "\r\n", "UTF-8 с BOM (EF BB BF); BOM не входит в смещения.", bom=True)

add("12b-utf8-nobom.frm",
    build("\\pard UTF-8 no BOM: $\u00fcber $\u0436\u0443\u043a \\par\n$\u20acuro \\par\n$last\n"),
    "utf-8", "\n", "Валидный UTF-8 без BOM при \\ansicpg1252 — автоопределение должно выбрать UTF-8.")

add("13-cp1251-cyrillic.frm",
    build("\\pard \u0424\u0418\u041e: $\u0418\u0432\u0430\u043d\u043e\u0432 \\par\n"
          "\u0413\u043e\u0440\u043e\u0434: $\u041a\u0438\u0457\u0432;\n"
          "\u0412\u0430\u043b\u044e\u0442\u0430: $\u0433\u0440\u043d\\par\n"
          "$\u044f\u0449\u0438\u043a \u2116 5 \\par\n", cp="1251"),
    "cp1251", "\r\n", "\\ansicpg1251, кириллица в байтах 0xC0-0xFF; в 4-м значении 'ящик'.")

add("14-value-chars.frm",
    build("\\pard $a.b-c,d:e/f \\par\n$1234567890 \\par\n$x_y(z)[w]<q>!? \\par\n$#%&*+=@^~|`'\" \\par\n"),
    "cp1252", "\n", "Значение с пунктуацией: всё, кроме пробельных и \\ { } $ ; — часть значения.")


def long_line():
    filler = "lorem ipsum dolor sit amet "
    parts = ["\\pard "]
    def pad(target):
        cur = sum(len(p) for p in parts)
        s = (filler * (target // len(filler) + 2))[: target - cur]
        parts.append(s)
    pad(9990)
    parts.append("$near1 ")
    pad(10005)
    parts.append("$over10k ")
    pad(20000)
    parts.append("$deep20k ")
    pad(25000)
    parts.append("$fourth")
    parts.append(" \\par\n")
    return "".join(parts)


# --- сборка ------------------------------------------------------------

def main():
    files = {}
    for name, data, codec, bom, eol, desc in CASES:
        if data is None:
            data = build(long_line()).replace("\n", eol).encode(codec)
        path = os.path.join(HERE, name)
        with open(path, "wb") as f:
            f.write(data)
        raw = data[3:] if bom else data
        text = raw.decode(codec)
        occs = scan(text)
        n = len(occs)
        hi_skip = list(range(SKIP_N, n))
        hi_all = list(range(n))
        txt_skip = strip(text, occs, set(hi_skip))
        txt_all = strip(text, occs, set(hi_all))

        def enc(t):
            b = t.encode(codec)
            return (b"\xef\xbb\xbf" + b) if bom else b

        entry = {
            "description": desc,
            "bytes_sha256": sha(data),
            "size_bytes": len(data),
            "encoding": {"cp1252": "windows-1252", "cp1251": "windows-1251",
                         "utf-8": "utf-8-bom" if bom else "utf-8"}[codec],
            "eol": detect_eol(data),
            "text_length": len(text),
            "line_count": len(re.split(r"\r\n|\r|\n", text)),
            "dollar_count": n,
            "occurrences": [
                {"index": k, "offset": off, "line": line_col(text, off)[0],
                 "column": line_col(text, off)[1], "value": val,
                 "skipped_by_default": k < SKIP_N}
                for k, (off, val) in enumerate(occs)
            ],
            "highlighted_skip3": hi_skip,
            "dimmed_skip3": list(range(min(SKIP_N, n))),
            "highlighted_all": hi_all,
            "strip_skip3_text": txt_skip,
            "strip_all_text": txt_all,
            "strip_skip3_bytes_sha256": sha(enc(txt_skip)),
            "strip_all_bytes_sha256": sha(enc(txt_all)),
            "rescan_after_strip_skip3": [v for _, v in scan(txt_skip)],
            "rescan_after_strip_all": [v for _, v in scan(txt_all)],
        }
        if len(text) < 3000:
            entry["strip_single_text"] = {
                str(k): strip(text, occs, {k}) for k in range(n)
            }
        files[name] = entry

    doc = {
        "rule": "значение = символы после '$' до пробельного (пробел, TAB, CR, LF), одного из \\ { } $ ; или конца файла; может быть пустым",
        "offset_unit": "Unicode-скаляры декодированного текста (BMP-only, = UTF-16 единицы); CRLF = 2 символа; BOM не считается",
        "line_column": "1-based; разделители CRLF | LF | CR",
        "skip_default_n": SKIP_N,
        "strip_semantics": "удалить значения у подсвеченных, '$' оставить; байты пересобраны в той же кодировке, с тем же EOL и BOM",
        "strip_single_note": "strip_single_text[k] — результат «Убрать значение» у одного вхождения k (только для файлов <3000 символов)",
        "files": files,
    }
    with open(os.path.join(HERE, "expected.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=True, indent=1, sort_keys=True)
        f.write("\n")

    # самопроверка вторым алгоритмом (regex) по сырым байтам с диска
    rx = re.compile(r"\$([^ \t\r\n$]*)")
    for name, e in files.items():
        data = open(os.path.join(HERE, name), "rb").read()
        assert sha(data) == e["bytes_sha256"], name
        codec = {"windows-1252": "cp1252", "windows-1251": "cp1251",
                 "utf-8": "utf-8", "utf-8-bom": "utf-8-sig"}[e["encoding"]]
        text = data.decode(codec)
        got = [(m.start(), m.group(1)) for m in rx.finditer(text)]
        exp = [(o["offset"], o["value"]) for o in e["occurrences"]]
        assert got == exp, (name, got, exp)
    print("OK: %d файлов, expected.json записан, сверка regex пройдена" % len(files))


if __name__ == "__main__":
    main()
