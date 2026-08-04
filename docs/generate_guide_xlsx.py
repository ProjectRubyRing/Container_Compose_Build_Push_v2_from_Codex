#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""docs/*_guide.md から Excel 版ガイド (*_guide.xlsx) を生成する。

md ガイドと同じ内容を、Excel で読みやすい 5 シート構成へ組み直して出力する。

    00_目次              … 表紙。対象スクリプト・生成日時・シート索引
    01_スクリプト仕様    … 役割 / できること / 全体構成 / 処理の流れ / 入出力 / 終了コード
    02_パラメータ一覧    … 指定可能なパラメータ (オートフィルタ付き)
    03_既定で有効な動作  … オプションを指定しなくても有効な動作
    04_設定例            … 実行例のコマンドと説明

内容はすべて md ガイドから機械的に抽出する。md を更新したら本スクリプトを
再実行すれば Excel 側も追従する (手書きの二重管理をしない)。

    python3 docs/generate_guide_xlsx.py              # docs/*_guide.md をすべて変換
    python3 docs/generate_guide_xlsx.py docs/build_and_verify_guide.md

xlsx は標準ライブラリだけで組み立てる (openpyxl 等の追加パッケージは不要)。
フォントは全シート Meiryo UI。行高は Excel の自動調整に任せず、内容と列幅から
計算して明示する (自動調整は環境によって働かず、折り返した本文が切れるため)。
"""

import argparse
import datetime
import glob
import math
import os
import re
import sys
import zipfile

# =============================================================================
# Markdown の読み取り
# =============================================================================

TABLE_SEPARATOR_RE = re.compile(r"^\|[\s:|-]+\|$")
HEADING_RE = re.compile(r"^(#{2,4})\s+(.*)$")
FENCE_RE = re.compile(r"^```(\w*)\s*$")
# 「## 4. パラメータ一覧」の "4." のような見出し番号
HEADING_NUMBER_RE = re.compile(r"^([0-9]+(?:[.\-][0-9]+)*)\.?\s+(.*)$")
# 実行例ブロックの「# 1) タイトル」
EXAMPLE_TITLE_RE = re.compile(r"^#\s*([0-9]+(?:-[0-9]+)?)\)\s*(.*)$")


def plain(text):
    """Markdown の装飾を落として、セルへそのまま入れられる文字列にする。

    コード span (`...`) の中身は先に退避しておく。`-XX:*Metaspace*` や `-Dotel.*`
    のように `*` を含む技術的な記法が、強調記法として削られてしまうのを防ぐ。
    """
    if text is None:
        return ""
    text = str(text)
    text = text.replace("<br/>", "\n").replace("<br />", "\n").replace("<br>", "\n")

    protected = []

    def stash(match):
        protected.append(match.group(1))
        return "\x00%d\x00" % (len(protected) - 1)

    text = re.sub(r"`([^`]*)`", stash, text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.replace("\\|", "|")
    text = re.sub(r"\x00(\d+)\x00", lambda m: protected[int(m.group(1))], text)
    return text.strip()


def split_table_row(line):
    """表の 1 行を列へ分割する。セル内のエスケープされた \\| は本文として残す。"""
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|"):
        body = body[:-1]
    body = body.replace("\\|", "\x00")
    return [cell.replace("\x00", "\\|").strip() for cell in body.split("|")]


class Block(object):
    """md 内の 1 かたまり (見出し配下の表・コード・本文)。"""

    __slots__ = ("kind", "section", "subsection", "header", "rows", "lang", "lines")

    def __init__(self, kind, section, subsection):
        self.kind = kind              # "table" / "code" / "text"
        self.section = section        # 直近の "## " 見出し
        self.subsection = subsection  # 直近の "### " 見出し (無ければ "")
        self.header = []              # table: ヘッダ行
        self.rows = []                # table: 本体行
        self.lang = ""                # code: 言語
        self.lines = []               # code/text: 行


def parse_markdown(path):
    """md を Block の並びへ分解する。"""
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.read().split("\n")

    blocks = []
    section = ""
    subsection = ""
    index = 0
    total = len(lines)

    while index < total:
        line = lines[index]

        fence = FENCE_RE.match(line)
        if fence:
            block = Block("code", section, subsection)
            block.lang = fence.group(1)
            index += 1
            while index < total and not lines[index].startswith("```"):
                block.lines.append(lines[index])
                index += 1
            index += 1
            blocks.append(block)
            continue

        heading = HEADING_RE.match(line)
        if heading:
            level = len(heading.group(1))
            title = plain(heading.group(2))
            if level == 2:
                section = title
                subsection = ""
            else:
                subsection = title
            index += 1
            continue

        # 表 (次行が区切り行になっているものだけを表として扱う)
        if line.startswith("|") and index + 1 < total and TABLE_SEPARATOR_RE.match(lines[index + 1].strip()):
            block = Block("table", section, subsection)
            block.header = [plain(cell) for cell in split_table_row(line)]
            index += 2
            while index < total and lines[index].strip().startswith("|"):
                block.rows.append([plain(cell) for cell in split_table_row(lines[index])])
                index += 1
            blocks.append(block)
            continue

        if line.strip():
            block = Block("text", section, subsection)
            while index < total and lines[index].strip() and not lines[index].startswith("|") \
                    and not lines[index].startswith("```") and not HEADING_RE.match(lines[index]):
                block.lines.append(lines[index].rstrip())
                index += 1
            blocks.append(block)
            continue

        index += 1

    return blocks


def section_number(section):
    """"4. パラメータ一覧" → "4"。番号が無ければ ""。"""
    matched = HEADING_NUMBER_RE.match(section)
    return matched.group(1) if matched else ""


def section_title(section):
    """"4. パラメータ一覧" → "パラメータ一覧"。"""
    matched = HEADING_NUMBER_RE.match(section)
    return matched.group(2) if matched else section


def find_sections(blocks, *keywords):
    """見出しにキーワードを含むセクション名を、出現順に返す。"""
    found = []
    for block in blocks:
        if not block.section or block.section in found:
            continue
        title = section_title(block.section)
        if any(keyword in title for keyword in keywords):
            found.append(block.section)
    return found


def text_lines(block):
    """本文ブロックを、箇条書きの階層を保った行の並びにする。"""
    out = []
    for line in block.lines:
        stripped = line.strip()
        if not stripped:
            continue
        indent = len(line) - len(line.lstrip(" "))
        bullet = re.match(r"^[-*]\s+(.*)$", stripped)
        if bullet:
            out.append(("  " * (indent // 2)) + "・" + plain(bullet.group(1)))
            continue
        numbered = re.match(r"^([0-9]+)\.\s+(.*)$", stripped)
        if numbered:
            out.append(("  " * (indent // 2)) + numbered.group(1) + ". " + plain(numbered.group(2)))
            continue
        if stripped.startswith(">"):
            out.append(plain(stripped.lstrip("> ")))
            continue
        out.append(("  " * (indent // 2)) + plain(stripped))
    return out


# =============================================================================
# xlsx 出力 (標準ライブラリのみ)
# =============================================================================

XML_INVALID_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
CELL_LIMIT = 32000

# 行高は内容と列幅から計算する。Meiryo UI 11pt の 1 行は約 15.0pt だが、
# 折り返し計算の誤差で本文が切れないよう余裕を持たせる。
ROW_LINE_HEIGHT = 16.5
ROW_HEIGHT_MIN = 19.5
ROW_HEIGHT_MAX = 409.0
HEADER_ROW_HEIGHT = 30.0
TITLE_ROW_HEIGHT = 36.0

# スタイル番号 (styles.xml の cellXfs の並びと一致させる)
S_PLAIN = 0      # 罫線なしの素の本文
S_TITLE = 1      # 表紙の大見出し
S_HEADER = 2     # 表のヘッダ (濃紺 + 白文字)
S_BODY = 3       # 表の本文
S_LABEL = 4      # 縦持ち表の見出し列 (薄いグレー)
S_SECTION = 5    # シート内のセクション見出し
S_MONO = 6       # コマンド・コード
S_CENTER = 7     # 中央寄せの本文
S_ACCENT = 8     # 強調 (薄い青)
S_NOTE = 9       # 補足 (小さいグレー文字)
S_ON = 10        # 「既定で有効」の印 (薄い緑)
S_KEY = 11       # 表の第 1 列 (オプション名など)

STYLES_XML = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="0"/>
<fonts count="8">
<font><sz val="11"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="18"/><color rgb="FF1F3864"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="13"/><color rgb="FF1F3864"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><sz val="10"/><color rgb="FF1F3864"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="11"/><color rgb="FF1F3864"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><sz val="10"/><color rgb="FF595959"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
<font><b/><sz val="11"/><color rgb="FF006100"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font>
</fonts>
<fills count="8">
<fill><patternFill patternType="none"/></fill>
<fill><patternFill patternType="gray125"/></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FF1F3864"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F2"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFDDEBF7"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFFAFAFA"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFE2EFDA"/><bgColor indexed="64"/></patternFill></fill>
<fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/><bgColor indexed="64"/></patternFill></fill>
</fills>
<borders count="3">
<border><left/><right/><top/><bottom/><diagonal/></border>
<border>
<left style="thin"><color rgb="FFBFBFBF"/></left>
<right style="thin"><color rgb="FFBFBFBF"/></right>
<top style="thin"><color rgb="FFBFBFBF"/></top>
<bottom style="thin"><color rgb="FFBFBFBF"/></bottom>
<diagonal/></border>
<border><left/><right/><top/>
<bottom style="medium"><color rgb="FF1F3864"/></bottom>
<diagonal/></border>
</borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="12">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="1" fillId="0" borderId="2" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="2" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="5" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="center"/></xf>
<xf numFmtId="0" fontId="4" fillId="5" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="0" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="6" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="7" fillId="6" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="top" wrapText="1"/></xf>
<xf numFmtId="0" fontId="5" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
<dxfs count="0"/>
<tableStyles count="0"/>
</styleSheet>
"""


def xml_escape(text):
    text = XML_INVALID_RE.sub("", str(text))
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return text.replace("\"", "&quot;")


def column_name(index):
    """0 起点の列番号を A, B, ... AA へ変換する。"""
    name = ""
    index += 1
    while index > 0:
        index, remainder = divmod(index - 1, 26)
        name = chr(ord("A") + remainder) + name
    return name


def east_asian_wide(char):
    code = ord(char)
    return (
        0x1100 <= code <= 0x115F or 0x2E80 <= code <= 0xA4CF or
        0xAC00 <= code <= 0xD7A3 or 0xF900 <= code <= 0xFAFF or
        0xFE30 <= code <= 0xFE6F or 0xFF00 <= code <= 0xFF60 or
        0xFFE0 <= code <= 0xFFE6 or 0x20000 <= code <= 0x3FFFD
    )


def display_width(text):
    return sum(2 if east_asian_wide(char) else 1 for char in text)


def wrapped_line_count(text, column_width):
    """列幅 (Excel の文字数単位) で折り返したときに必要な行数を求める。"""
    if not text:
        return 1
    usable = max(float(column_width) - 1.0, 4.0)
    total = 0
    for line in str(text).split("\n"):
        width = display_width(line)
        total += 1 if width <= 0 else int(math.ceil(width / usable))
    return max(total, 1)


class Cell(object):
    __slots__ = ("value", "style")

    def __init__(self, value, style=S_PLAIN):
        self.value = value
        self.style = style


class Sheet(object):
    def __init__(self, name, widths=None, freeze_rows=0, autofilter_row=0, autofilter_cols=0):
        self.name = name
        self.widths = widths or []
        self.freeze_rows = freeze_rows
        self.autofilter_row = autofilter_row
        self.autofilter_cols = autofilter_cols
        self.rows = []
        self.merges = []          # (行番号, 開始列, 終了列)
        # 高さの指定は 2 種類に分ける。空行は「ぴったりこの高さ」、本文のある行は
        # 「最低でもこの高さ」。後者を固定値にすると、長い文が既定の高さで切れる。
        self.fixed_heights = {}   # 行番号 -> 高さ (pt) をそのまま使う (空行の余白)
        self.min_heights = {}     # 行番号 -> 最低の高さ (pt)。内容が長ければ広げる

    def add(self, cells):
        self.rows.append(cells)
        return len(self.rows)

    def span(self):
        return max(len(self.widths), 1)

    def add_merged(self, text, style=S_PLAIN, height=None):
        """全列を結合した 1 行を追加する (狭い列で縦長にならないように)。"""
        width = self.span()
        number = self.add([Cell(text, style)] + [Cell("", style) for _ in range(width - 1)])
        self.merges.append((number, 0, width - 1))
        if height is not None:
            self.min_heights[number] = height
        return number

    def add_blank(self, height=6.0):
        number = self.add([Cell("", S_PLAIN)])
        self.fixed_heights[number] = height
        return number

    def add_section(self, text):
        """シート内のセクション見出し (罫線なし・濃紺の太字)。"""
        self.add_blank(9.0)
        return self.add_merged(text, S_SECTION, height=24.0)

    def effective_widths(self, row_number):
        """結合を反映した列ごとの実効幅と、高さ計算から除く列を返す。

        結合セルは Excel の自動調整が効かないため、結合後の幅で折り返し行数を
        求める必要がある。結合の先頭列へ合計幅を寄せ、2 列目以降は除外する。
        A 列から始まらない結合 (B:D など) でも本文が切れないよう、列ごとに扱う。
        """
        widths = [float(width) for width in self.widths]
        skip = set()
        for number, start, end in self.merges:
            if number != row_number:
                continue
            last = min(end + 1, len(widths))
            if start < len(widths):
                widths[start] = sum(widths[index] for index in range(start, last))
            for index in range(start + 1, last):
                skip.add(index)
        return widths, skip


def calculate_row_height(cells, widths, skip=()):
    lines = 1
    for index, cell in enumerate(cells):
        if cell is None or index in skip:
            continue
        width = widths[index] if index < len(widths) else 20
        lines = max(lines, wrapped_line_count(cell.value, width))
    return min(max(lines * ROW_LINE_HEIGHT, ROW_HEIGHT_MIN), ROW_HEIGHT_MAX)


def sheet_xml(sheet):
    out = ["<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
           "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"]
    if sheet.freeze_rows:
        out.append(
            "<sheetViews><sheetView showGridLines=\"0\" workbookViewId=\"0\">"
            "<pane ySplit=\"%d\" topLeftCell=\"A%d\" activePane=\"bottomLeft\" state=\"frozen\"/>"
            "</sheetView></sheetViews>" % (sheet.freeze_rows, sheet.freeze_rows + 1)
        )
    else:
        out.append("<sheetViews><sheetView showGridLines=\"0\" workbookViewId=\"0\"/></sheetViews>")
    out.append("<sheetFormatPr defaultRowHeight=\"%s\"/>" % ROW_HEIGHT_MIN)
    if sheet.widths:
        cols = ["<cols>"]
        for index, width in enumerate(sheet.widths):
            cols.append("<col min=\"%d\" max=\"%d\" width=\"%s\" customWidth=\"1\"/>"
                        % (index + 1, index + 1, width))
        cols.append("</cols>")
        out.append("".join(cols))
    out.append("<sheetData>")
    for row_index, cells in enumerate(sheet.rows, 1):
        if row_index in sheet.fixed_heights:
            height = sheet.fixed_heights[row_index]
        else:
            widths, skip = sheet.effective_widths(row_index)
            height = calculate_row_height(cells, widths, skip)
            floor = sheet.min_heights.get(row_index, 0.0)
            if sheet.freeze_rows and row_index == sheet.freeze_rows:
                floor = max(floor, HEADER_ROW_HEIGHT)
            height = min(max(height, floor), ROW_HEIGHT_MAX)
        parts = ["<row r=\"%d\" ht=\"%.1f\" customHeight=\"1\">" % (row_index, height)]
        for col_index, cell in enumerate(cells):
            if cell is None:
                continue
            ref = "%s%d" % (column_name(col_index), row_index)
            value = "" if cell.value is None else str(cell.value)
            if len(value) > CELL_LIMIT:
                value = value[:CELL_LIMIT] + "\n... (以降は省略)"
            if not value:
                parts.append("<c r=\"%s\" s=\"%d\"/>" % (ref, cell.style))
                continue
            parts.append("<c r=\"%s\" s=\"%d\" t=\"inlineStr\"><is><t xml:space=\"preserve\">%s</t></is></c>"
                         % (ref, cell.style, xml_escape(value)))
        parts.append("</row>")
        out.append("".join(parts))
    out.append("</sheetData>")
    if sheet.autofilter_row and sheet.autofilter_cols:
        out.append("<autoFilter ref=\"A%d:%s%d\"/>"
                   % (sheet.autofilter_row, column_name(sheet.autofilter_cols - 1),
                      max(len(sheet.rows), sheet.autofilter_row)))
    # mergeCells は OOXML のスキーマ上 autoFilter の後に置く。
    if sheet.merges:
        merges = ["<mergeCells count=\"%d\">" % len(sheet.merges)]
        for row_number, start, end in sheet.merges:
            merges.append("<mergeCell ref=\"%s%d:%s%d\"/>"
                          % (column_name(start), row_number, column_name(end), row_number))
        merges.append("</mergeCells>")
        out.append("".join(merges))
    out.append("<pageMargins left=\"0.5\" right=\"0.5\" top=\"0.6\" bottom=\"0.6\" header=\"0.3\" footer=\"0.3\"/>")
    out.append("</worksheet>")
    return "".join(out)


def write_xlsx(path, sheets, title, creator):
    content_types = ["<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
                     "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">",
                     "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>",
                     "<Default Extension=\"xml\" ContentType=\"application/xml\"/>",
                     "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>",
                     "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>",
                     "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>",
                     "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"]
    for index in range(len(sheets)):
        content_types.append("<Override PartName=\"/xl/worksheets/sheet%d.xml\" "
                             "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
                             % (index + 1))
    content_types.append("</Types>")

    root_rels = (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
        "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
        "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>"
        "</Relationships>"
    )

    sheet_entries = "".join(
        "<sheet name=\"%s\" sheetId=\"%d\" r:id=\"rId%d\"/>" % (xml_escape(sheet.name), index + 1, index + 1)
        for index, sheet in enumerate(sheets)
    )
    workbook = (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        "<sheets>%s</sheets></workbook>" % sheet_entries
    )

    workbook_rels = ["<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
                     "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"]
    for index in range(len(sheets)):
        workbook_rels.append(
            "<Relationship Id=\"rId%d\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" "
            "Target=\"worksheets/sheet%d.xml\"/>" % (index + 1, index + 1)
        )
    workbook_rels.append(
        "<Relationship Id=\"rId%d\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" "
        "Target=\"styles.xml\"/>" % (len(sheets) + 1)
    )
    workbook_rels.append("</Relationships>")

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    core = (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
        "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" "
        "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
        "<dc:title>%s</dc:title><dc:creator>%s</dc:creator><cp:lastModifiedBy>%s</cp:lastModifiedBy>"
        "<dcterms:created xsi:type=\"dcterms:W3CDTF\">%s</dcterms:created>"
        "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">%s</dcterms:modified>"
        "</cp:coreProperties>" % (xml_escape(title), xml_escape(creator), xml_escape(creator), now, now)
    )
    app = (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" "
        "xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">"
        "<Application>%s</Application></Properties>" % xml_escape(creator)
    )

    directory = os.path.dirname(os.path.abspath(path))
    if directory and not os.path.isdir(directory):
        os.makedirs(directory)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as book:
        book.writestr("[Content_Types].xml", "".join(content_types))
        book.writestr("_rels/.rels", root_rels)
        book.writestr("docProps/core.xml", core)
        book.writestr("docProps/app.xml", app)
        book.writestr("xl/workbook.xml", workbook)
        book.writestr("xl/_rels/workbook.xml.rels", "".join(workbook_rels))
        book.writestr("xl/styles.xml", STYLES_XML)
        for index, sheet in enumerate(sheets):
            book.writestr("xl/worksheets/sheet%d.xml" % (index + 1), sheet_xml(sheet))


# =============================================================================
# シートの組み立て
# =============================================================================

def header_row(labels):
    return [Cell(label, S_HEADER) for label in labels]


def add_table(sheet, header, rows, key_column=0, center_columns=()):
    """md の表を、ヘッダ + 本文としてシートへ流し込む。"""
    sheet.add(header_row(header))
    for row in rows:
        cells = []
        for index in range(len(header)):
            value = row[index] if index < len(row) else ""
            if index == key_column:
                style = S_KEY
            elif index in center_columns:
                style = S_CENTER
            else:
                style = S_BODY
            cells.append(Cell(value, style))
        sheet.add(cells)


def is_active_default(value):
    """既定値の表記が「指定しなくても効いている値」かどうか。"""
    normalized = value.strip()
    if not normalized:
        return False
    if normalized.startswith("(") and ("なし" in normalized or "未" in normalized):
        return False
    return normalized not in ("false", "—", "-", "(なし)", "(未指定)", "なし")


def build_cover_sheet(meta, sheet_names):
    sheet = Sheet("00_目次", widths=[30, 96])
    sheet.add_merged(meta["title"], S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged("Excel 版ガイド (Meiryo UI) — 元ドキュメントと同じ内容を Excel 用に再構成したものです",
                     S_NOTE, height=20.0)
    sheet.add_blank(10.0)

    sheet.add(header_row(["項目", "内容"]))
    for label, value in [
        ("対象スクリプト", meta["script"]),
        ("元ドキュメント", meta["source"]),
        ("役割", meta["summary"]),
        ("生成日時", meta["generated"]),
        ("生成方法", "python3 docs/generate_guide_xlsx.py (docs/*_guide.md から自動生成)"),
    ]:
        sheet.add([Cell(label, S_LABEL), Cell(value, S_BODY)])

    sheet.add_section("シート構成")
    sheet.add(header_row(["シート", "記載内容"]))
    descriptions = {
        "01_スクリプト仕様": "スクリプトの役割・できること・全体構成・処理の流れ・入出力ファイル・終了コード",
        "02_パラメータ一覧": "指定可能なパラメータの全件。値の形式・既定値・複数指定の可否・説明。オートフィルタで絞り込めます",
        "03_既定で有効な動作": "オプションを何も指定しなくても有効になっている動作と、その既定値",
        "04_設定例": "用途別の実行例。コマンドをそのままコピーして使えます",
    }
    for name in sheet_names:
        if name == "00_目次":
            continue
        sheet.add([Cell(name, S_KEY), Cell(descriptions.get(name, ""), S_BODY)])

    sheet.add_blank(10.0)
    sheet.add_merged("※ 本ブックは docs/*_guide.md から機械的に生成しています。"
                     "内容を直すときは md 側を修正し、generate_guide_xlsx.py を再実行してください。",
                     S_NOTE, height=20.0)
    return sheet


def build_spec_sheet(blocks, meta):
    sheet = Sheet("01_スクリプト仕様", widths=[34, 92])
    sheet.add_merged("スクリプト仕様", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged(meta["script"] + " — " + meta["summary"], S_NOTE, height=20.0)

    def emit_section(keywords, heading):
        sections = find_sections(blocks, *keywords)
        if not sections:
            return
        target = sections[0]
        wrote_heading = False
        for block in blocks:
            if block.section != target:
                continue
            if not wrote_heading:
                sheet.add_section(heading)
                wrote_heading = True
            if block.subsection:
                sheet.add_merged("《" + block.subsection + "》", S_ACCENT)
            if block.kind == "table":
                add_table(sheet, block.header, block.rows)
            elif block.kind == "text":
                lines = text_lines(block)
                if lines:
                    sheet.add_merged("\n".join(lines), S_BODY)
            elif block.kind == "code" and block.lang != "mermaid":
                body = "\n".join(line for line in block.lines if line.strip())
                if body:
                    sheet.add_merged(body, S_MONO)

    emit_section(("役割",), "1. このスクリプトの役割")
    emit_section(("全体構成", "違い"), "2. 全体構成")
    emit_section(("処理の流れ",), "3. 処理の流れ")
    emit_section(("入出力",), "4. 入出力ファイル")
    emit_section(("終了コード",), "5. 終了コード")
    emit_section(("環境変数",), "6. 環境変数")
    return sheet


def collect_parameter_tables(blocks):
    """「オプション」列を持つ表を、パラメータ表として集める。"""
    collected = []
    for block in blocks:
        if block.kind != "table" or not block.header:
            continue
        if block.header[0] != "オプション":
            continue
        collected.append(block)
    return collected


def build_parameter_sheet(blocks, meta):
    sheet = Sheet("02_パラメータ一覧", widths=[26, 30, 22, 20, 8, 78],
                  freeze_rows=4, autofilter_row=4, autofilter_cols=6)
    sheet.add_merged("指定可能なパラメータ", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged("「既定値」が空欄以外のものは、指定しなくてもその値で動作します。"
                     "分類・オプション名で絞り込めます (オートフィルタ)。", S_NOTE, height=20.0)
    sheet.add_blank(6.0)
    sheet.add(header_row(["分類", "オプション", "値の形式", "既定値", "複数/必須", "説明"]))

    tables = collect_parameter_tables(blocks)
    count = 0
    for block in tables:
        category = block.subsection or section_title(block.section)
        header = block.header
        # 列構成が表ごとに違う (値の形式 / 既定値 / 複数 / 必須 の有無) ため名前で引く。
        index_of = {name: position for position, name in enumerate(header)}
        for row in block.rows:
            def cell(name):
                position = index_of.get(name)
                return row[position] if position is not None and position < len(row) else ""

            option = cell("オプション")
            if not option:
                continue
            multiple = cell("複数") or cell("必須")
            description = cell("説明") or cell("効果")
            sheet.add([
                Cell(category, S_KEY),
                Cell(option, S_KEY),
                Cell(cell("値の形式"), S_BODY),
                Cell(cell("既定値"), S_ACCENT if is_active_default(cell("既定値")) else S_BODY),
                Cell(multiple, S_CENTER),
                Cell(description, S_BODY),
            ])
            count += 1

    if not count:
        sheet.add_merged("パラメータ表を検出できませんでした。", S_BODY)
    return sheet


def build_defaults_sheet(blocks, meta):
    sheet = Sheet("03_既定で有効な動作", widths=[30, 26, 26, 78])
    sheet.add_merged("デフォルトで有効となっている動作", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged("オプションを何も指定しない状態で有効になっている動作と、その既定値です。",
                     S_NOTE, height=20.0)

    # (1) 「できること」表で、有効化にオプションが不要と書かれている機能
    feature_rows = []
    for block in blocks:
        if block.kind != "table" or not block.header:
            continue
        if "機能" not in block.header:
            continue
        index_of = {name: position for position, name in enumerate(block.header)}
        enable_key = None
        for name in block.header:
            if "有効化" in name:
                enable_key = name
                break
        if enable_key is None:
            continue
        for row in block.rows:
            feature = row[index_of["機能"]] if index_of["機能"] < len(row) else ""
            enabler = row[index_of[enable_key]] if index_of[enable_key] < len(row) else ""
            if not feature:
                continue
            if "既定" in enabler or "自動" in enabler:
                feature_rows.append((feature, enabler))

    if feature_rows:
        sheet.add_section("オプション指定なしで動作する機能")
        # 2 列の表なので、2 列目をシート右端まで結合して罫線を途切れさせない。
        number = sheet.add(header_row(["機能", "有効になる条件", "", ""]))
        sheet.merges.append((number, 1, 3))
        for feature, enabler in feature_rows:
            number = sheet.add([Cell(feature, S_KEY), Cell(enabler, S_ON),
                                Cell("", S_ON), Cell("", S_ON)])
            sheet.merges.append((number, 1, 3))

    # (2) パラメータ表のうち、既定値が「効いている値」のもの
    default_rows = []
    for block in collect_parameter_tables(blocks):
        category = block.subsection or section_title(block.section)
        index_of = {name: position for position, name in enumerate(block.header)}

        def get(row, name):
            position = index_of.get(name)
            return row[position] if position is not None and position < len(row) else ""

        for row in block.rows:
            option = get(row, "オプション")
            default = get(row, "既定値")
            if not option or not is_active_default(default):
                continue
            default_rows.append((category, option, default, get(row, "説明")))

    if default_rows:
        sheet.add_section("既定値が設定されているパラメータ")
        sheet.add(header_row(["分類", "オプション", "既定値", "その既定値での動作"]))
        for category, option, default, description in default_rows:
            sheet.add([Cell(category, S_KEY), Cell(option, S_KEY),
                       Cell(default, S_ON), Cell(description, S_BODY)])

    # (3) パラメータ表以外で「既定」と明記されている動作。
    #     エラー対処表は「既定」の語を含んでも既定動作の説明ではないため対象外にする
    #     (混ざると既定動作の一覧としての見通しが悪くなる)。
    note_rows = []
    seen = set()
    for block in blocks:
        if block.kind != "table" or not block.header:
            continue
        if block.header[0] == "オプション" or "機能" in block.header:
            continue
        if "エラー" in section_title(block.section):
            continue
        for row in block.rows:
            joined = " / ".join(cell for cell in row if cell)
            if "既定" not in joined:
                continue
            key = joined[:80]
            if key in seen:
                continue
            seen.add(key)
            note_rows.append((block.subsection or section_title(block.section), joined))

    if note_rows:
        sheet.add_section("その他、既定の挙動として説明されている項目")
        number = sheet.add(header_row(["記載箇所", "内容", "", ""]))
        sheet.merges.append((number, 1, 3))
        for where, body in note_rows:
            number = sheet.add([Cell(where, S_KEY), Cell(body, S_BODY), Cell("", S_BODY), Cell("", S_BODY)])
            sheet.merges.append((number, 1, 3))

    if not feature_rows and not default_rows and not note_rows:
        sheet.add_merged("既定で有効な動作を検出できませんでした。", S_BODY)
    return sheet


def iter_examples(blocks):
    """「実行例」セクションのコードブロックを (番号, 用途, コマンド) へ分解する。

    実行例は 1 つのコードフェンスにまとめて書かれており、「# 1) タイトル」の
    コメント行が各例の区切りになっている。
    """
    example_sections = find_sections(blocks, "実行例")
    for block in blocks:
        if block.kind != "code" or block.section not in example_sections:
            continue
        number = ""
        titles = []
        command = []

        for line in block.lines:
            matched = EXAMPLE_TITLE_RE.match(line.strip())
            if matched:
                body = "\n".join(command).strip("\n")
                if body:
                    yield number, "\n".join(titles), body
                number = matched.group(1)
                titles = [matched.group(2)] if matched.group(2) else []
                command = []
                continue
            if line.strip().startswith("#"):
                # 「#     …」のような、直前の見出しに続く補足コメント
                titles.append(line.strip().lstrip("#").strip())
                continue
            if line.strip():
                command.append(line)

        body = "\n".join(command).strip("\n")
        if body:
            yield number, "\n".join(titles), body


def build_examples_sheet(blocks, meta):
    sheet = Sheet("04_設定例", widths=[8, 44, 96])
    sheet.add_merged("設定例", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged("元ドキュメントの実行例です。コマンド列はそのままコピーして使えます。",
                     S_NOTE, height=20.0)
    sheet.add_blank(6.0)
    sheet.add(header_row(["#", "用途", "コマンド"]))

    count = 0
    for number, titles, command in iter_examples(blocks):
        sheet.add([Cell(number, S_CENTER), Cell(titles, S_KEY), Cell(command, S_MONO)])
        count += 1

    if not count:
        sheet.add_merged("実行例を検出できませんでした。", S_BODY)
    return sheet


# =============================================================================
# 3 スクリプト横断リファレンス (scripts_reference.xlsx)
# =============================================================================

# シート名は既存の scripts_reference.xlsx を踏襲する
# (README が "08_JVM_OTel設定" を名指ししているため、参照を壊さない)。
REFERENCE_ORDER = ["build_and_push", "buildx_build_and_push", "build_and_verify"]
REFERENCE_PARAM_SHEETS = {
    "build_and_push": "01_build_and_push",
    "buildx_build_and_push": "02_buildx_build_and_push",
    "build_and_verify": "03_build_and_verify",
}


def guide_key(meta):
    """meta から "build_and_verify" のようなスクリプト名 (拡張子なし) を得る。"""
    return meta["script"][:-3] if meta["script"].endswith(".sh") else meta["script"]


def tables_in(blocks, section_keywords=(), first_header=None, subsection_keywords=()):
    """条件に合う表ブロックを返す。"""
    found = []
    for block in blocks:
        if block.kind != "table" or not block.header:
            continue
        if section_keywords and not any(k in section_title(block.section) for k in section_keywords):
            continue
        if subsection_keywords and not any(k in block.subsection for k in subsection_keywords):
            continue
        if first_header is not None and block.header[0] != first_header:
            continue
        found.append(block)
    return found


def column_getter(block):
    """表の列を名前で引く関数を返す (ガイドごとに列構成が違うため)。"""
    index_of = {name: position for position, name in enumerate(block.header)}

    def get(row, *names):
        for name in names:
            position = index_of.get(name)
            if position is not None and position < len(row):
                return row[position]
        return ""

    return get


def count_parameters(blocks):
    return sum(len(block.rows) for block in collect_parameter_tables(blocks))


def build_reference_overview(guides):
    sheet = Sheet("00_概要", widths=[24, 40, 40, 40])
    sheet.add_merged("3 スクリプトの比較と使い分け", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged("docs/*_guide.md から自動生成したスクリプト横断リファレンスです。", S_NOTE, height=20.0)

    ordered = [guides[key] for key in REFERENCE_ORDER if key in guides]

    sheet.add_section("スクリプト別の概要")
    sheet.add(header_row(["観点"] + [guide["meta"]["script"] for guide in ordered]))

    def row(label, values, style=S_BODY):
        sheet.add([Cell(label, S_LABEL)] + [Cell(value, style) for value in values])

    row("役割", [guide["meta"]["summary"] for guide in ordered])
    row("元ドキュメント", [guide["meta"]["source"] for guide in ordered])
    row("Excel 版", [os.path.basename(guide["meta"]["source"])[:-3] + ".xlsx" for guide in ordered])
    row("パラメータ数", ["%d 件" % count_parameters(guide["blocks"]) for guide in ordered], S_CENTER)

    exit_counts = []
    for guide in ordered:
        tables = tables_in(guide["blocks"], section_keywords=("終了コード",), first_header="コード")
        exit_counts.append("%d 種類" % sum(len(table.rows) for table in tables))
    row("終了コード", exit_counts, S_CENTER)

    env_counts = []
    for guide in ordered:
        tables = tables_in(guide["blocks"], section_keywords=("環境変数",), first_header="環境変数")
        env_counts.append("%d 件" % sum(len(table.rows) for table in tables))
    row("環境変数", env_counts, S_CENTER)

    # 各ガイドの「前提条件」表を観点ごとに突き合わせる
    prerequisites = {}
    for index, guide in enumerate(ordered):
        for block in tables_in(guide["blocks"], first_header="前提"):
            get = column_getter(block)
            for line in block.rows:
                label = get(line, "前提")
                if not label:
                    continue
                prerequisites.setdefault(label, [""] * len(ordered))[index] = get(line, "内容")
    if prerequisites:
        sheet.add_section("前提条件")
        sheet.add(header_row(["前提"] + [guide["meta"]["script"] for guide in ordered]))
        for label, values in prerequisites.items():
            row(label, values)

    # 「3 スクリプトの使い分け」表 (どのガイドにあっても拾う)
    for guide in ordered:
        blocks = tables_in(guide["blocks"], first_header="目的")
        if not blocks:
            continue
        sheet.add_section("使い分け")
        number = sheet.add(header_row(["目的", "使うスクリプト", "", ""]))
        sheet.merges.append((number, 1, 3))
        get = column_getter(blocks[0])
        for line in blocks[0].rows:
            number = sheet.add([Cell(get(line, "目的"), S_BODY),
                                Cell(get(line, "使うスクリプト"), S_ACCENT),
                                Cell("", S_ACCENT), Cell("", S_ACCENT)])
            sheet.merges.append((number, 1, 3))
        break

    return sheet


def build_reference_parameter_sheet(guide, sheet_name):
    meta = guide["meta"]
    sheet = Sheet(sheet_name, widths=[26, 30, 22, 22, 10, 74],
                  freeze_rows=4, autofilter_row=4, autofilter_cols=6)
    sheet.add_merged("%s パラメータ一覧" % meta["script"], S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged(meta["summary"], S_NOTE, height=20.0)
    sheet.add_blank(6.0)
    sheet.add(header_row(["分類", "オプション", "値の形式", "既定値", "複数/必須", "説明"]))

    for block in collect_parameter_tables(guide["blocks"]):
        category = block.subsection or section_title(block.section)
        get = column_getter(block)
        for line in block.rows:
            option = get(line, "オプション")
            if not option:
                continue
            default = get(line, "既定値")
            sheet.add([
                Cell(category, S_KEY),
                Cell(option, S_KEY),
                Cell(get(line, "値の形式"), S_BODY),
                Cell(default, S_ACCENT if is_active_default(default) else S_BODY),
                Cell(get(line, "複数", "必須"), S_CENTER),
                Cell(get(line, "説明", "効果"), S_BODY),
            ])
    return sheet


def build_reference_flow_sheet(guides):
    sheet = Sheet("04_処理フロー", widths=[26, 8, 30, 62, 34])
    sheet.add_merged("処理の流れ", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged("各スクリプトの処理フェーズです。表の形はガイドごとに異なるため、"
                     "元の見出しと列をそのまま残しています。", S_NOTE, height=20.0)

    for key in REFERENCE_ORDER:
        guide = guides.get(key)
        if guide is None:
            continue
        blocks = [block for block in guide["blocks"]
                  if block.kind == "table" and "処理の流れ" in section_title(block.section)]
        if not blocks:
            continue
        sheet.add_section("■ %s" % guide["meta"]["script"])
        current = None
        for block in blocks:
            if block.subsection and block.subsection != current:
                current = block.subsection
                sheet.add_merged("《" + current + "》", S_ACCENT)
            add_table(sheet, block.header, block.rows,
                      center_columns=(0,) if block.header[0] == "#" else ())
    return sheet


def build_reference_exit_code_sheet(guides):
    sheet = Sheet("05_終了コード", widths=[26, 12, 20, 92], freeze_rows=4,
                  autofilter_row=4, autofilter_cols=4)
    sheet.add_merged("終了コード一覧", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged("スクリプト別の終了コードと、その発生条件です。", S_NOTE, height=20.0)
    sheet.add_blank(6.0)
    sheet.add(header_row(["スクリプト", "終了コード", "意味", "主な発生条件"]))

    for key in REFERENCE_ORDER:
        guide = guides.get(key)
        if guide is None:
            continue
        for block in tables_in(guide["blocks"], section_keywords=("終了コード",), first_header="コード"):
            get = column_getter(block)
            for line in block.rows:
                sheet.add([Cell(guide["meta"]["script"], S_KEY),
                           Cell(get(line, "コード"), S_CENTER),
                           Cell(get(line, "意味"), S_BODY),
                           Cell(get(line, "主な発生条件"), S_BODY)])
    return sheet


def build_reference_env_sheet(guides):
    sheet = Sheet("06_環境変数", widths=[26, 34, 14, 26, 74], freeze_rows=4,
                  autofilter_row=4, autofilter_cols=5)
    sheet.add_merged("環境変数一覧", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged("スクリプトが入力として参照する環境変数と、自身で設定する環境変数です。",
                     S_NOTE, height=20.0)
    sheet.add_blank(6.0)
    sheet.add(header_row(["スクリプト", "環境変数", "区分", "対応オプション", "説明"]))

    for key in REFERENCE_ORDER:
        guide = guides.get(key)
        if guide is None:
            continue
        for block in tables_in(guide["blocks"], section_keywords=("環境変数",), first_header="環境変数"):
            # 「7.2 スクリプトが設定する環境変数」など、見出しから区分を決める
            label = block.subsection or section_title(block.section)
            kind = "出力" if "設定する" in label else "入力"
            get = column_getter(block)
            for line in block.rows:
                sheet.add([Cell(guide["meta"]["script"], S_KEY),
                           Cell(get(line, "環境変数"), S_KEY),
                           Cell(kind, S_CENTER),
                           Cell(get(line, "対応オプション"), S_BODY),
                           Cell(get(line, "説明"), S_BODY)])
    return sheet


def build_reference_example_sheet(guides):
    sheet = Sheet("07_実行例", widths=[26, 8, 40, 88], freeze_rows=4,
                  autofilter_row=4, autofilter_cols=4)
    sheet.add_merged("シナリオ別の実行例", S_TITLE, height=TITLE_ROW_HEIGHT)
    sheet.add_merged("コマンド列はそのままコピーして使えます。", S_NOTE, height=20.0)
    sheet.add_blank(6.0)
    sheet.add(header_row(["スクリプト", "#", "シナリオ", "コマンド例"]))

    for key in REFERENCE_ORDER:
        guide = guides.get(key)
        if guide is None:
            continue
        for number, titles, command in iter_examples(guide["blocks"]):
            sheet.add([Cell(guide["meta"]["script"], S_KEY),
                       Cell(number, S_CENTER),
                       Cell(titles, S_BODY),
                       Cell(command, S_MONO)])
    return sheet


def build_reference_jvm_otel_sheet(guides):
    sheet = Sheet("08_JVM_OTel設定", widths=[30, 96, 46])
    sheet.add_merged("JVM パラメータの分類と OpenTelemetry 設定の検出条件", S_TITLE,
                     height=TITLE_ROW_HEIGHT)
    sheet.add_merged("build_and_verify.sh がコンテナ内で検出・分類する条件です。",
                     S_NOTE, height=20.0)

    guide = guides.get("build_and_verify")
    if guide is None:
        sheet.add_merged("build_and_verify_guide.md が見つからないため出力できません。", S_BODY)
        return sheet

    wrote = False
    for block in guide["blocks"]:
        if block.kind != "table":
            continue
        if "JVM" not in block.subsection and "OpenTelemetry" not in block.subsection:
            continue
        sheet.add_section("《" + block.subsection + "》")
        add_table(sheet, block.header, block.rows)
        wrote = True
    if not wrote:
        sheet.add_merged("JVM / OpenTelemetry の分類表を検出できませんでした。", S_BODY)
    return sheet


def build_reference_workbook(guides, out_path):
    sheets = [build_reference_overview(guides)]
    for key in REFERENCE_ORDER:
        guide = guides.get(key)
        if guide is not None:
            sheets.append(build_reference_parameter_sheet(guide, REFERENCE_PARAM_SHEETS[key]))
    sheets.append(build_reference_flow_sheet(guides))
    sheets.append(build_reference_exit_code_sheet(guides))
    sheets.append(build_reference_env_sheet(guides))
    sheets.append(build_reference_example_sheet(guides))
    sheets.append(build_reference_jvm_otel_sheet(guides))
    write_xlsx(out_path, sheets, "コンテナビルド・プッシュ スクリプト リファレンス",
               "generate_guide_xlsx.py")
    return sheets


# =============================================================================
# エントリポイント
# =============================================================================

def guide_meta(path, blocks):
    """表紙に載せるメタ情報を md から拾う。"""
    base = os.path.basename(path)
    script = base[:-len("_guide.md")] + ".sh" if base.endswith("_guide.md") else base

    title = ""
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("# "):
                title = plain(line[2:])
                break
    if not title:
        title = script + " ガイド"

    summary = ""
    for block in blocks:
        if block.kind == "text" and "役割" in section_title(block.section):
            lines = text_lines(block)
            if lines:
                summary = lines[0]
                break
    if not summary:
        summary = script + " の詳細ガイド"

    return {
        "title": title,
        "script": script,
        "source": "docs/" + base,
        "summary": summary,
        "generated": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }


def convert(md_path, out_path=None):
    blocks = parse_markdown(md_path)
    meta = guide_meta(md_path, blocks)

    sheets = [
        build_spec_sheet(blocks, meta),
        build_parameter_sheet(blocks, meta),
        build_defaults_sheet(blocks, meta),
        build_examples_sheet(blocks, meta),
    ]
    cover = build_cover_sheet(meta, ["00_目次"] + [sheet.name for sheet in sheets])
    sheets.insert(0, cover)

    if out_path is None:
        out_path = os.path.splitext(md_path)[0] + ".xlsx"
    write_xlsx(out_path, sheets, meta["title"], "generate_guide_xlsx.py")
    return out_path, sheets


def main(argv):
    parser = argparse.ArgumentParser(
        description="docs/*_guide.md から Excel 版ガイド (*_guide.xlsx) を生成する")
    parser.add_argument("sources", nargs="*",
                        help="変換する md ファイル (省略時は docs/*_guide.md をすべて変換)")
    parser.add_argument("--out-dir", default=None,
                        help="出力先ディレクトリ (省略時は md と同じ場所)")
    parser.add_argument("--no-reference", action="store_true",
                        help="3 スクリプト横断の scripts_reference.xlsx を生成しない")
    parser.add_argument("--reference-only", action="store_true",
                        help="scripts_reference.xlsx だけを生成する")
    args = parser.parse_args(argv)

    docs_dir = os.path.dirname(os.path.abspath(__file__))
    sources = args.sources
    all_guides = not sources
    if not sources:
        sources = sorted(glob.glob(os.path.join(docs_dir, "*_guide.md")))
    if not sources:
        print("変換対象の md が見つかりません。", file=sys.stderr)
        return 1

    out_dir = args.out_dir or docs_dir
    guides = {}
    for md_path in sources:
        if not os.path.isfile(md_path):
            print("見つかりません: %s" % md_path, file=sys.stderr)
            return 1
        blocks = parse_markdown(md_path)
        meta = guide_meta(md_path, blocks)
        guides[guide_key(meta)] = {"meta": meta, "blocks": blocks, "path": md_path}

        if args.reference_only:
            continue
        base = os.path.basename(os.path.splitext(md_path)[0]) + ".xlsx"
        out_path = os.path.join(out_dir, base) if args.out_dir else \
            os.path.splitext(md_path)[0] + ".xlsx"
        written, sheets = convert(md_path, out_path)
        print("生成しました: %s (%d シート, %d 行)"
              % (written, len(sheets), sum(len(sheet.rows) for sheet in sheets)))

    # 横断リファレンスは 3 ガイドが揃っているときだけ生成する
    # (一部だけ指定した実行で、既存のブックを欠けた内容で上書きしないため)。
    if not args.no_reference:
        missing = [key for key in REFERENCE_ORDER if key not in guides]
        if missing and not all_guides:
            print("scripts_reference.xlsx はスキップしました "
                  "(3 ガイドすべての指定が必要。不足: %s)" % ", ".join(missing))
        elif missing:
            print("scripts_reference.xlsx を生成できません (不足: %s)" % ", ".join(missing),
                  file=sys.stderr)
            return 1
        else:
            reference_path = os.path.join(out_dir, "scripts_reference.xlsx")
            sheets = build_reference_workbook(guides, reference_path)
            print("生成しました: %s (%d シート, %d 行)"
                  % (reference_path, len(sheets), sum(len(sheet.rows) for sheet in sheets)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
