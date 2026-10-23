import Foundation

/// Управляющие слова RTF, которые понимает `RTFReader`. Остальные просто пропускаются (в исходнике они остаются).
enum RTFWord: String, CaseIterable {
    // Назначения (первое слово группы).
    case fonttbl, colortbl, header, headerl, headerr, headerf, footer, footerl, footerr, footerf
    case field, fldinst, fldrslt, pict, shp, shpinst, shprslt, shppict, object, do_ = "do", pntext, listtext
    case sp, sn, sv, upr, ud, panose, falt
    // Документ.
    case ansi, ansicpg, deff, deftab, paperw, paperh, margl, margr, margt, margb, facingp, landscape
    // Раздел.
    case sectd, sect, pgwsxn, pghsxn, marglsxn, margrsxn, margtsxn, margbsxn, lndscpsxn, titlepg, headery, footery
    case sbknone, sbkpage, sbkodd, sbkeven, sbkcol
    // Абзац.
    case pard, par, ql, qc, qr, qj, qd, li, ri, fi, lin, rin, sb, sa, sl, slmult
    case tx, tb, tqr, tqc, tqdec, tldot, tlhyph, tlul, tlth, tleq, tlmdot
    case intbl, keepn, pagebb, s, cbpat, contextualspace, ls, ilvl
    case brdrt, brdrb, brdrl, brdrr, box, brdrw, brdrcf, brdrs, brdrth, brdrdb, brdrdot, brdrdash, brdrnone, brdrnil, brdrsh
    // Символ.
    case plain, f, fs, b, i, ul, uld, uldb, ulw, ulth, uldash, uldashd, uldashdd, ulwave, ulhwave, ululdbwave, ulthd, ulthdash
    case ulnone, strike, striked, cf, cb, highlight, chcbpat, v, super_ = "super", sub, nosupersub, up, dn, caps, scaps
    // Особые символы.
    case tab, line, page, cell, row, nestcell, nestrow, itap, uc, u, bin
    case emdash, endash, lquote, rquote, ldblquote, rdblquote, bullet, emspace, enspace, qmspace, zwj, zwnj, ltrmark, rtlmark, chpgn
    // Таблица.
    case trowd, cellx, clvmgf, clvmrg, clmgf, clmrg, clbrdrt, clbrdrb, clbrdrl, clbrdrr, clcbpat, clvertalt, clvertalc, clvertalb
    case trgaph, trleft, trrh, trhdr, trpaddt, trpaddb, trbrdrt, trbrdrb, trbrdrl, trbrdrr, trbrdrh, trbrdrv
    case trql, trqc, trqr, trpaddl, trpaddr, trpaddfl, trpaddfr, clpadt, clpadr, clpadft, clpadfr
    // Рисунок.
    case pngblip, jpegblip, wmetafile, emfblip, macpict, dibitmap, wbitmap, pmmetafile, picw, pich, picwgoal, pichgoal, picscalex, picscaley
    // Фигуры и объекты рисования.
    case shpleft, shpright, shptop, shpbottom, shpwr, shpfblwtxt, shpbxpage, shpbxmargin, shpbxcolumn, shpbypage, shpbymargin, shpbypara
    case dpline, dprect, dpellipse, dptxbx, dppolyline, dppolygon, dparc, dpcallout, dpgroup
    case dpx, dpy, dpxsize, dpysize
    // Таблица шрифтов и цветов.
    case fnil, froman, fswiss, fmodern, fscript, fdecor, ftech, fbidi, fcharset, cpg, red, green, blue

    static let byKey: [RTFDollarScanner.WordKey: RTFWord] = Dictionary(uniqueKeysWithValues: allCases.map {
        (RTFDollarScanner.WordKey($0.rawValue), $0)
    })

    /// Группы, текст которых на странице не виден: пропускаются целиком, не разбираясь.
    static let skippedDestinations: Set<RTFDollarScanner.WordKey> = Set([
        "stylesheet", "info", "rsidtbl", "generator", "datastore", "themedata",
        "colorschememapping", "latentstyles", "xmlnstbl", "mmathPr", "pgdsctbl", "revtbl", "filetbl", "userprops",
        "docvar", "template", "nonshppict", "footnote", "bkmkstart", "bkmkend", "pn", "pnseclvl", "pntxta", "pntxtb",
        "ffdata", "formfield", "nonesttables", "xe", "tc", "tcn", "annotation", "atnid", "atnauthor",
        "atrfstart", "atrfend", "atndate", "objdata", "objclass", "objname", "result", "blipuid", "picprop", "shptxt",
        "dptxbxtext", "oldcprops", "oldpprops", "oldsprops", "oldtprops", "defchp", "defpap", "fchars", "lchars",
        "wgrffmtfilter", "private", "comment", "doccomm", "title", "subject", "author", "operator", "keywords",
        "leveltext", "levelnumbers", "listname", "listpicture", "background", "ftnsep", "ftnsepc", "aftnsep", "aftnsepc",
        "factoidname", "xmlopen", "xmlclose", "xmlattrname", "xmlattrvalue", "mmath", "passwordhash", "protusertbl",
        "rsidroot", "ebcstart", "ebcend", "themelang", "pgptbl", "listoverride", "list", "colorschememapping",
    ].map { RTFDollarScanner.WordKey($0) })
}
