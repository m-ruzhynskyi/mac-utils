# Демо-форма для E-4 (выдуманный текст, структура — как у форм Word). python3 make_e4.py
def cp(text):
    return ''.join(ch if ord(ch) < 0x80 else "\\'%02x" % ch.encode('cp1251')[0] for ch in text)

P = r"\pard\plain \ltrpar\ql \li0\ri0\sa120\widctlpar\wrapdefault\faauto\rin0\lin0 \rtlch\fcs1 \af0 \ltrch\fcs0 \f0\fs22\lang1049 "
doc = (r"{\rtf1\ansi\ansicpg1251\uc1\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}{\f1\fswiss\fcharset204 Arial;}}"
       r"{\colortbl;\red0\green0\blue0;}" "\r\n" r"\paperw11906\paperh16838\margl1134\margr850\margt1134\margb1134\sectd "
       r"{\footer " + P + cp("Страница ") + r"{\field{\*\fldinst {\f0 PAGE }}{\fldrslt {\f0 7}}}" + cp(" из ")
       + r"{\field{\*\fldinst {\f0 NUMPAGES }}{\fldrslt {\f0 9}}}\par }" "\r\n")
doc += P + r"\qc\keepn {\b " + cp("ЗАЯВЛЕНИЕ О ПРИЁМЕ") + r"}\par" "\r\n"
doc += P + cp("Площадь участка 25 м") + r"{\super 2}" + cp(", расход H") + r"{\sub 2}" + cp("O по счётчику.") + r"\par" "\r\n"
doc += cp("Второй абзац без своего кода абзаца наследует свойства первого.") + r"\par" "\r\n"
doc += P + r"{\scaps " + cp("Сведения о заявителе") + r"} " + cp("и ") + r"{\caps " + cp("подпись") + r"}" + r"{\v " + cp(" служебная пометка") + r"}\par" "\r\n"
doc += P + r"\keep " + cp("Абзац, который не разрывается между страницами, с полем: всего страниц ") \
       + r"{\field{\*\fldinst {NUMPAGES}}{\fldrslt {5}}}" + cp(", эта страница ") + r"{\field{\*\fldinst {PAGE}}{\fldrslt {4}}}.\par" "\r\n"
row = r"\trowd \trgaph108\trleft-108\clbrdrt\brdrs\brdrw10 \clbrdrb\brdrs\brdrw10 \cellx4500\clbrdrt\brdrs\brdrw10 \clbrdrb\brdrs\brdrw10 \cellx9000" "\r\n"
doc += row + r"\pard\plain\intbl \f0\fs22 " + cp("Фамилия") + r"\cell " + cp("Иванова") + r"\cell\row" "\r\n"
doc += P + r"\pagebb " + cp("Приложение начинается с новой страницы.") + r"\par" "\r\n"
doc += P + cp("Последний абзац формы.") + r"\par" "\r\n}"
open('01-form-e4.rtf', 'w', newline='').write(doc)
