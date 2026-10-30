# Демо-формы со списками для E-2 (выдуманный текст, структура — как у форм Word). python3 make_lists.py
def cp(text):
    out = ''
    for ch in text:
        b = ch.encode('cp1251')
        out += ch if b[0] < 0x80 else "\\'%02x" % b[0]
    return out

HEAD = (r"{\rtf1\ansi\ansicpg1251\uc1\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}{\f1\fswiss\fcharset204 Arial;}"
        r"{\f2\fnil\fcharset2 Symbol;}}{\colortbl;\red0\green0\blue0;}" "\r\n")

def level(nfc, text, numbers, li, fi, start=1, follow=0, extra=''):
    t = ''.join("\\'%02x" % c if isinstance(c, int) else cp(c) for c in text)
    length = sum(1 for _ in text)
    n = ''.join("\\'%02x" % x for x in numbers)
    return (r"{\listlevel\levelnfc%d\levelnfcn%d\leveljc0\leveljcn0\levelfollow%d\levelstartat%d\levelspace0\levelindent0"
            r"{\leveltext\leveltemplateid67698703\'%02x%s;}{\levelnumbers%s;}%s\fi%d\li%d\jclisttab\tx%d\lin%d }"
            % (nfc, nfc, follow, start, length, t, n, extra, fi, li, li, li))

MULTI = (level(0, [0, '.'], [1], 360, -360) + level(0, [0, '.', 1, '.'], [1, 3], 792, -432)
         + level(4, [2, ')'], [1], 1224, -504) + ''.join(level(0, [0, '.', 1, '.', 2, '.', 3], [1, 3, 5, 7], 1728 + 360 * k, -648) for k in range(6)))
ROMAN = level(1, [0, '.'], [1], 720, -720) * 9

def bullet_level():
    return (r"{\listlevel\levelnfc23\levelnfcn23\leveljc0\leveljcn0\levelfollow0\levelstartat1\levelspace0\levelindent0"
            r"{\leveltext\leveltemplateid67698689\'01\u-3913 ?;}{\levelnumbers;}\f2\fbias0 \fi-360\li720\jclisttab\tx720\lin720 }")

def lists(defs, overrides):
    table = r"{\*\listtable" + ''.join(r"{\list\listtemplateid1%s\listid%d}" % (body, lid) for lid, body in defs) + "}\r\n"
    over = r"{\*\listoverridetable" + ''.join(overrides) + "}\r\n"
    return table + over

def item(ls, lvl, text, listtext=None, li=None, fi=None, intbl=False):
    li = li if li is not None else [360, 792, 1224][lvl] if lvl < 3 else 1728
    fi = fi if fi is not None else [-360, -432, -504][lvl] if lvl < 3 else -648
    pre = ''
    if listtext is not None:
        pre = r"{\listtext\pard\plain\ltrpar \rtlch\fcs1 \af0 \ltrch\fcs0 \f0\fs24 %s\tab}" % cp(listtext)
    tbl = r"\intbl" if intbl else ''
    return pre + r"\pard\plain \ltrpar\ql \fi%d\li%d\ri0\sa120%s\ls%d\ilvl%d\lin%d \f0\fs24 %s" % (fi, li, tbl, ls, lvl, li, cp(text))

def para(text):
    return r"\pard\plain \ltrpar\ql \li0\ri0\sa120 \f0\fs24 " + cp(text) + r"\par" "\r\n"

# 01: как пишет Word — с готовыми номерами {\listtext}, многоуровневый список.
body = para("Анкета участника конкурса")
body += item(1, 0, "Общие сведения", "1.") + r"\par" "\r\n"
body += item(1, 1, "Фамилия и имя заявителя", "1.1.") + r"\par" "\r\n"
body += item(1, 1, "Дата рождения", "1.2.") + r"\par" "\r\n"
body += item(1, 2, "день и месяц", "a)") + r"\par" "\r\n"
body += item(1, 2, "год", "b)") + r"\par" "\r\n"
body += item(1, 0, "Контакты", "2.") + r"\par" "\r\n"
body += item(1, 1, "Телефон для связи", "2.1.") + r"\par" "\r\n"
body += para("Подпись ____________")
open('01-word-numbered.rtf', 'w', newline='').write(
    HEAD + lists([(101, MULTI)], [r"{\listoverride\listid101\listoverridecount0\ls1}"]) + r"\sectd " + body + "}")

# 02: как пишут генераторы форм — без {\listtext}; маркеры Symbol; два \ls одного списка продолжают нумерацию.
body = para("Порядок подачи документов")
body += item(1, 0, "Заполните заявление полностью") + r"\par" "\r\n"
body += item(1, 0, "Приложите копию паспорта") + r"\par" "\r\n"
body += para("Дополнительно:")
body += item(2, 0, "справка с места работы", li=720, fi=-360) + r"\par" "\r\n"
body += item(2, 0, "две фотографии", li=720, fi=-360) + r"\par" "\r\n"
body += item(3, 0, "Передайте пакет в окно приёма") + r"\par" "\r\n"
body += item(4, 0, "Получите расписку о приёме") + r"\par" "\r\n"
body += para("Конец инструкции")
open('02-generated-no-listtext.rtf', 'w', newline='').write(
    HEAD + lists([(201, MULTI), (202, bullet_level() * 9)],
                 [r"{\listoverride\listid201\listoverridecount0\ls1}", r"{\listoverride\listid202\listoverridecount0\ls2}",
                  r"{\listoverride\listid201\listoverridecount0\ls3}",
                  r"{\listoverride\listid201\listoverridecount1{\lfolevel\listoverridestartat\levelstartat7}\ls4}"])
    + r"\sectd " + body + "}")

# 03: список в ячейках таблицы и римские номера после неё.
row = (r"\trowd \trgaph108\trleft-108\clbrdrt\brdrs\brdrw10 \clbrdrl\brdrs\brdrw10 \clbrdrb\brdrs\brdrw10 \clbrdrr\brdrs\brdrw10 "
       r"\cellx3000\clbrdrt\brdrs\brdrw10 \clbrdrl\brdrs\brdrw10 \clbrdrb\brdrs\brdrw10 \clbrdrr\brdrs\brdrw10 \cellx9000" "\r\n")
body = para("Перечень работ")
body += row + r"\pard\plain\intbl \f0\fs24 " + cp("Этап") + r"\cell " + item(1, 0, "Подготовка площадки", "1.", intbl=True) + r"\par "
body += item(1, 0, "Закупка материалов", "2.", intbl=True) + r"\cell\row" "\r\n"
body += row + r"\pard\plain\intbl \f0\fs24 " + cp("Срок") + r"\cell " + item(1, 0, "Монтаж конструкций", "3.", intbl=True) + r"\cell\row" "\r\n"
body += item(2, 0, "Приёмка работ", "I.", li=720, fi=-720) + r"\par" "\r\n"
body += item(2, 0, "Оплата", "II.", li=720, fi=-720) + r"\par" "\r\n"
open('03-table-roman.rtf', 'w', newline='').write(
    HEAD + lists([(301, MULTI), (302, ROMAN)], [r"{\listoverride\listid301\listoverridecount0\ls1}", r"{\listoverride\listid302\listoverridecount0\ls2}"])
    + r"\sectd " + body + "}")
