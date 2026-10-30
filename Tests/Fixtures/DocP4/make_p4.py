# Демо-формы для P-4 (выдуманный текст, структура — как пишет Word). python3 make_p4.py
def cp(text):
    return ''.join(ch if ord(ch) < 0x80 else "\\'%02x" % ch.encode('cp1251')[0] for ch in text)

HEAD = (r"{\rtf1\ansi\ansicpg1251\uc1\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}{\colortbl;\red0\green0\blue0;}" "\r\n"
        r"\paperw11906\paperh16838\margl1134\margr850\margt1134\margb1134\sectd " "\r\n")
B = r"\clbrdrt\brdrs\brdrw10 \clbrdrl\brdrs\brdrw10 \clbrdrb\brdrs\brdrw10 \clbrdrr\brdrs\brdrw10 "
OUTER = r"\trowd \irow0\irowband0\trgaph108\trleft-108\trpaddl108\trpaddr108\trpaddfl3\trpaddfr3 " + B + r"\cellx3000" + B + r"\cellx9800" "\r\n"
INNER = (r"{\*\nesttableprops\trowd \irow0\irowband0\trgaph108\trleft0\trpaddl108\trpaddr108\trpaddfl3\trpaddfr3 " + B + r"\cellx3200"
         + B + r"\cellx6400\nestrow}{\nonesttables" "\r\n" r"\par }")

def nested_row(a, b):
    p = r"\pard\plain \ql \li0\ri0\intbl\itap2 \f0\fs22 "
    return p + cp(a) + r"\nestcell " + p + cp(b) + r"\nestcell " + r"\pard\plain \ql \li0\ri0\intbl\itap2 \f0\fs22 " + INNER + "\r\n"

doc = HEAD + r"\pard\plain \ql \li0\ri0\sa120 \f0\fs22 " + cp("Опись вложений") + r"\par" "\r\n"
doc += OUTER + r"\pard\plain \ql \li0\ri0\intbl\itap1 \f0\fs22 " + cp("Раздел описи") + r"\cell" "\r\n"
doc += r"\pard\plain \ql \li0\ri0\intbl\itap1 \f0\fs22 " + cp("Перечень документов:") + r"\par" "\r\n"
doc += nested_row("Копия договора аренды", "2 листа")
doc += nested_row("Справка о составе семьи", "1 лист")
doc += r"\pard\plain \ql \li0\ri0\intbl\itap1 \f0\fs22 " + cp("Итого приложено три листа.") + r"\cell" "\r\n" + OUTER.replace(r"\trowd", r"\trowd", 1) + r"\row" "\r\n"
doc += r"\pard\plain \ql \li0\ri0\sa120 \f0\fs22 " + cp("Подпись заявителя") + r"\par" "\r\n}"
open('01-nested-table.rtf', 'w', newline='').write(doc)
