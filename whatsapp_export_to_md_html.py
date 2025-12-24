#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
whatsapp_export_to_md_html.py

WhatsApp chat export (plain text) -> Markdown + HTML preview output.

Revision r06 baseline; r07 change:
- Header meta: remove full source path and remove file mtime line
- Show only basename of chat file for "Quelle"
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import html
import os
import re
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# ---------------------------
# Models
# ---------------------------

@dataclass
class Message:
    ts: dt.datetime
    author: str
    text: str


# ---------------------------
# Helpers: text normalize / url
# ---------------------------

def _norm_space(s: str) -> str:
    s = (s or "").replace("\u00a0", " ").strip()
    # remove direction marks that sometimes appear in exports
    s = s.replace("\u200e", "").replace("\u200f", "").replace("\u202a", "").replace("\u202b", "").replace("\u202c", "")
    s = " ".join(s.split())
    return s

_url_re = re.compile(r"(https?://[^\s<>\]]+)", re.IGNORECASE)

def extract_urls(text: str) -> List[str]:
    urls = []
    for m in _url_re.finditer(text or ""):
        u = m.group(1).rstrip(").,;:!?]\"'")
        urls.append(u)
    # unique, stable
    seen = set()
    out = []
    for u in urls:
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out

def is_youtube_url(u: str) -> Optional[str]:
    """Return YouTube video id if url is YouTube, else None."""
    try:
        pu = urllib.parse.urlparse(u)
    except Exception:
        return None

    host = (pu.netloc or "").lower()
    path = pu.path or ""

    # youtu.be/<id>
    if host.endswith("youtu.be"):
        vid = path.strip("/").split("/")[0]
        return vid or None

    # youtube.com/watch?v=<id>
    if "youtube.com" in host or "m.youtube.com" in host:
        qs = urllib.parse.parse_qs(pu.query or "")
        if "v" in qs and qs["v"]:
            return qs["v"][0]
        # /shorts/<id>
        if path.startswith("/shorts/"):
            vid = path.split("/")[2] if len(path.split("/")) >= 3 else ""
            return vid or None

    return None

def safe_filename_stem(stem: str) -> str:
    stem = re.sub(r"[^A-Za-z0-9_\-]+", "_", stem)
    return stem.strip("_") or "WHATSAPP_CHAT"


# ---------------------------
# Parsing WhatsApp exports
# ---------------------------

# Supported formats:
# 1) 2019-04-13 18:59:06 Carolin: Text
# NOTE:
# WhatsApp exports sometimes emit lines like "... Name:" (no space / no text after colon),
# especially for media messages where the attachment marker follows on the next line.
# Therefore we must allow optional whitespace and an empty message text after ":".
_pat_iso = re.compile(r"^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})\s+([^:]+?):\s*(.*)$")

# 2) 13.04.19, 18:59 - Carolin: Text
# 3) 13.04.2019, 18:59:06 - Carolin: Text
_pat_de = re.compile(
    r"^(\d{1,2}\.\d{1,2}\.\d{2,4}),\s+(\d{1,2}:\d{2})(?::(\d{2}))?\s+-\s+([^:]+?):\s*(.*)$"
)

# 4) [13.04.2019, 18:59:06] Carolin: Text
_pat_bracket = re.compile(
    r"^\[(\d{1,2}\.\d{1,2}\.\d{2,4}),\s+(\d{1,2}:\d{2})(?::(\d{2}))?\]\s+([^:]+?):\s*(.*)$"
)
SYSTEM_AUTHOR = "System"

_pat_iso_sys = re.compile(
    r"^(?P<date>\d{4}-\d{2}-\d{2})[ T](?P<time>\d{2}:\d{2}:\d{2})(?:\s+[-–]\s+|\s+)(?P<text>.*)$"
)

_pat_de_sys = re.compile(
    r"^(?P<date>\d{1,2}\.\d{1,2}\.\d{2,4}),\s+(?P<time>\d{1,2}:\d{2})(?::(?P<sec>\d{2}))?\s+[-–]\s+(?P<text>.*)$"
)

_pat_bracket_sys = re.compile(
    r"^\[(?P<date>\d{1,2}\.\d{1,2}\.\d{2,4}),\s+(?P<time>\d{1,2}:\d{2})(?::(?P<sec>\d{2}))?\]\s+(?P<text>.*)$"
)

def parse_dt_de(d: str, t_hm: str, t_s: Optional[str]) -> dt.datetime:
    # date with 2-digit or 4-digit year
    dd, mm, yy = d.split(".")
    day = int(dd)
    month = int(mm)
    year = int(yy)
    if year < 100:
        # WhatsApp uses 2-digit year -> assume 2000-2099 for 00-99
        year += 2000
    hh, mi = t_hm.split(":")
    ss = int(t_s) if t_s is not None else 0
    return dt.datetime(year, month, day, int(hh), int(mi), ss)

def parse_messages(chat_path: Path) -> List[Message]:
    raw = chat_path.read_text(encoding="utf-8", errors="replace").splitlines()
    msgs: List[Message] = []

    last: Optional[Message] = None
    for line in raw:
        line = line.rstrip("\n")
        # iOS-WhatsApp-Exporte enthalten teils unsichtbare BOM-/Bidi-Zeichen, die die Header-RegEx brechen.
        # Wenn das passiert, wird "[..] Marcel:" als Fortsetzung der vorherigen Bubble gewertet (falsche Seite).
        if line:
            line = (line.replace("\ufeff", "")
                        .replace("\u200e", "").replace("\u200f", "")
                        .replace("\u202a", "").replace("\u202b", "").replace("\u202c", ""))
        if not line:
            # keep empty line as continuation if inside message
            if last is not None:
                last.text += "\n"
            continue

        m = _pat_iso.match(line)
        if m:
            d_s, t_s, author, text = m.groups()
            ts = dt.datetime.fromisoformat(f"{d_s} {t_s}")
            author = _norm_space(author)
            msg = Message(ts=ts, author=author, text=text)
            msgs.append(msg)
            last = msg
            continue

        m = _pat_de.match(line)
        if m:
            d, t_hm, t_sec, author, text = m.groups()
            ts = parse_dt_de(d, t_hm, t_sec)
            author = _norm_space(author)
            msg = Message(ts=ts, author=author, text=text)
            msgs.append(msg)
            last = msg
            continue

        m = _pat_bracket.match(line)
        if m:
            d, t_hm, t_sec, author, text = m.groups()
            ts = parse_dt_de(d, t_hm, t_sec)
            author = _norm_space(author)
            msg = Message(ts=ts, author=author, text=text)
            msgs.append(msg)
            last = msg
            continue

        # continuation line
        if last is not None:
            last.text += "\n" + line
        else:
            # stray header line -> ignore
            pass

    return msgs


# ---------------------------
# "Ich"-Perspektive selection (robust)
# ---------------------------

def choose_me_name(authors: List[str]) -> str:
    # normalize + unique
    uniq: List[str] = []
    for a in authors:
        a2 = _norm_space(a)
        if not a2:
            continue
        if a2 not in uniq:
            uniq.append(a2)

    # filter typical system pseudo-authors if they appear as "author"
    system_markers = {
        "system",
        "whatsapp",
        "messages to this chat are now secured",
        "nachrichten und anrufe sind ende-zu-ende-verschlüsselt",
    }
    uniq2 = [a for a in uniq if _norm_space(a).casefold() not in system_markers]
    if uniq2:
        uniq = uniq2

    # fallback if still empty
    if not uniq:
        return "Ich"

    # If stdin is not interactive, pick first
    try:
        interactive = sys.stdin.isatty()
    except Exception:
        interactive = False
    if not interactive:
        return uniq[0]

    print("\nIch-Perspektive wählen (welcher Name ist 'ich'):\n")
    for i, a in enumerate(uniq, 1):
        print(f"  {i}) {a}")

    idx_map = {str(i): name for i, name in enumerate(uniq, 1)}
    name_map = {name.casefold(): name for name in uniq}

    while True:
        try:
            raw = _norm_space(input("Nummer oder Name: "))
        except EOFError:
            # no input available -> fallback
            return uniq[0]

        if raw == "":
            return uniq[0]

        raw_num = raw.rstrip(").")
        if raw_num in idx_map:
            return idx_map[raw_num]

        key = raw.casefold()
        if key in name_map:
            return name_map[key]

        print("Bitte eine gültige Nummer (wie angezeigt) oder einen der Namen eingeben.")


# ---------------------------
# Attachment handling
# ---------------------------

_attach_re = re.compile(r"<\s*Anhang:\s*([^>]+?)\s*>", re.IGNORECASE)

def find_attachments(text: str) -> List[str]:
    return [m.group(1).strip() for m in _attach_re.finditer(text or "")]

def strip_attachment_markers(text: str) -> str:
    return _attach_re.sub("", text or "").strip()

def guess_mime_from_name(name: str) -> str:
    n = name.lower()
    if n.endswith(".jpg") or n.endswith(".jpeg"):
        return "image/jpeg"
    if n.endswith(".png"):
        return "image/png"
    if n.endswith(".gif"):
        return "image/gif"
    if n.endswith(".webp"):
        return "image/webp"
    return "application/octet-stream"

def file_to_data_url(path: Path) -> Optional[str]:
    if not path.exists() or not path.is_file():
        return None
    mime = guess_mime_from_name(path.name)
    try:
        data = path.read_bytes()
    except Exception:
        return None
    b64 = base64.b64encode(data).decode("ascii")
    return f"data:{mime};base64,{b64}"


# ---------------------------
# Link previews (online)
# ---------------------------

@dataclass
class Preview:
    url: str
    title: str
    description: str
    image_data_url: Optional[str]

_preview_cache: Dict[str, Preview] = {}

def _http_get(url: str, timeout: int = 15) -> Tuple[bytes, str]:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (WhatsAppExportTools/1.0)",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        ct = r.headers.get("Content-Type", "") or ""
        data = r.read()
        return data, ct

def _resolve_url(base: str, maybe: str) -> str:
    return urllib.parse.urljoin(base, maybe)

_meta_re = re.compile(r'<meta\s+[^>]*?>', re.IGNORECASE)
_attr_re = re.compile(r'(\w+)\s*=\s*(".*?"|\'.*?\'|[^\s>]+)')

def _parse_meta(html_bytes: bytes) -> Dict[str, str]:
    try:
        s = html_bytes.decode("utf-8", errors="replace")
    except Exception:
        s = str(html_bytes)

    out: Dict[str, str] = {}
    for tag in _meta_re.findall(s[:800_000]):  # limit
        attrs = {}
        for k, v in _attr_re.findall(tag):
            v = v.strip().strip("\"'").strip()
            attrs[k.lower()] = v
        prop = attrs.get("property", "").lower()
        name = attrs.get("name", "").lower()
        content = attrs.get("content", "")
        key = prop or name
        if key and content:
            out[key] = content
    # title fallback
    m = re.search(r"<title>(.*?)</title>", s[:800_000], re.IGNORECASE | re.DOTALL)
    if m:
        out.setdefault("title", html.unescape(m.group(1)).strip())
    return out

def _download_image_as_data_url(img_url: str, timeout: int = 15, max_bytes: int = 2_500_000) -> Optional[str]:
    try:
        data, ct = _http_get(img_url, timeout=timeout)
    except Exception:
        return None
    if len(data) > max_bytes:
        return None
    mime = ct.split(";")[0].strip().lower() if ct else ""
    if not mime.startswith("image/"):
        # guess from url
        mime = guess_mime_from_name(urllib.parse.urlparse(img_url).path)
        if not mime.startswith("image/"):
            return None
    b64 = base64.b64encode(data).decode("ascii")
    return f"data:{mime};base64,{b64}"

def build_preview(url: str) -> Optional[Preview]:
    if url in _preview_cache:
        return _preview_cache[url]

    # YouTube special: always make preview with thumbnail
    vid = is_youtube_url(url)
    if vid:
        thumb = f"https://img.youtube.com/vi/{vid}/hqdefault.jpg"
        img_data = _download_image_as_data_url(thumb)
        prev = Preview(
            url=url,
            title="YouTube",
            description="",
            image_data_url=img_data,
        )
        _preview_cache[url] = prev
        return prev

    try:
        html_bytes, _ct = _http_get(url)
    except Exception:
        return None

    meta = _parse_meta(html_bytes)
    title = meta.get("og:title") or meta.get("title") or url
    desc = meta.get("og:description") or meta.get("description") or ""
    img = meta.get("og:image") or meta.get("twitter:image") or ""

    img_data_url = None
    if img:
        img_url = _resolve_url(url, img)
        img_data_url = _download_image_as_data_url(img_url)

    prev = Preview(url=url, title=title.strip(), description=desc.strip(), image_data_url=img_data_url)
    _preview_cache[url] = prev
    return prev


# ---------------------------
# Rendering
# ---------------------------

WEEKDAY_DE = {
    0: "Montag",
    1: "Dienstag",
    2: "Mittwoch",
    3: "Donnerstag",
    4: "Freitag",
    5: "Samstag",
    6: "Sonntag",
}

def fmt_date_full(d: dt.date) -> str:
    return f"{d.day:02d}.{d.month:02d}.{d.year:04d}"

def fmt_time(t: dt.time) -> str:
    return f"{t.hour:02d}:{t.minute:02d}:{t.second:02d}"

def html_escape_keep_newlines(s: str) -> str:
    return "<br>".join(html.escape(s).splitlines())

def render_html(
    msgs: List[Message],
    chat_path: Path,
    out_html: Path,
    me_name: str,
    enable_previews: bool = True,
) -> None:
    # participants
    authors = []
    for m in msgs:
        a = _norm_space(m.author)
        if a and a not in authors:
            authors.append(a)
    others = [a for a in authors if a != me_name]
    if len(others) == 1:
        title_names = f"{me_name} ↔ {others[0]}"
    elif len(others) > 1:
        title_names = f"{me_name} ↔ {', '.join(others)}"
    else:
        title_names = f"{me_name} ↔ Chat"

    # export time = file mtime of _chat.txt (requested)
    try:
        mtime = dt.datetime.fromtimestamp(chat_path.stat().st_mtime)
    except Exception:
        mtime = dt.datetime.now()

    # CSS: WhatsApp-like, no overlap
    css = """
    :root{
      --bg:#e5ddd5;
      --bubble-me:#DCF8C6;
      --bubble-other:#EAF7E0; /* a bit lighter green */
      --text:#111;
      --muted:#666;
      --shadow: 0 1px 0 rgba(0,0,0,.06);
    }
    html,body{height:100%;margin:0;padding:0;}
    body{
      font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
      background: var(--bg);
      color: var(--text);
      font-size: 18px;
      line-height: 1.35;
    }
    /* subtle pattern */
    body:before{
      content:"";
      position:fixed;inset:0;
      background:
        radial-gradient(circle at 10px 10px, rgba(255,255,255,.12) 2px, transparent 3px) 0 0/36px 36px,
        radial-gradient(circle at 28px 28px, rgba(0,0,0,.04) 2px, transparent 3px) 0 0/36px 36px;
      pointer-events:none;
      opacity:.8;
    }
    .wrap{max-width: 980px; margin: 0 auto; padding: 18px 12px 28px;}
    .header{
      background: rgba(255,255,255,.75);
      backdrop-filter: blur(6px);
      border-radius: 14px;
      padding: 14px 16px;
      box-shadow: var(--shadow);
      margin-bottom: 14px;
    }
    .h-title{font-weight:700; font-size: 24px; margin:0 0 6px;}
    .h-meta{margin:0; color: var(--muted); font-size: 15px; line-height:1.4;}
    .day{
      display:flex;
      justify-content:center;
      margin: 16px 0 10px;
    }
    .day > span{
      background: rgba(255,255,255,.65);
      color: #333;
      border-radius: 999px;
      padding: 6px 12px;
      font-size: 14px;
      box-shadow: var(--shadow);
    }
    .row{
      display:flex;
      margin: 10px 0;
      width:100%;
    }
    .row.me{justify-content:flex-end;}
    .row.other{justify-content:flex-start;}
    .bubble{
      max-width: 78%;
      min-width: 220px;
      padding: 10px 12px 8px;
      border-radius: 18px;
      box-shadow: var(--shadow);
      position:relative;
      overflow:hidden;
    }
    .bubble.me{background: var(--bubble-me);}
    .bubble.other{background: var(--bubble-other);}
    .name{
      font-weight: 700;
      margin: 0 0 8px;
      font-size: 18px;
      opacity: .9;
    }
    .text{white-space: normal; word-wrap: break-word;}
    .meta{
      margin-top: 10px;
      text-align: right;
      font-size: 14px;
      color: #444;
      opacity: .9;
      line-height: 1.1;
    }
    .media{
      margin-top: 10px;
      border-radius: 14px;
      overflow:hidden;
      background: rgba(255,255,255,.35);
    }
    .media img{
      display:block;
      width:100%;
      height:auto;
    }
    .preview{
      margin-top: 10px;
      border-radius: 14px;
      overflow:hidden;
      background: rgba(255,255,255,.55);
      border: 1px solid rgba(0,0,0,.06);
    }
    .preview a{color: inherit; text-decoration:none; display:block;}
    .preview .pimg img{width:100%;height:auto;display:block;}
    .preview .pbody{padding:10px 12px;}
    .preview .ptitle{font-weight:700; margin:0 0 4px; font-size: 16px;}
    .preview .pdesc{margin:0; color: var(--muted); font-size: 14px;}
    .linkline{margin-top:8px;font-size:15px;color:#2a5db0;word-break:break-all;}
    """

    # Render messages with day separators
    parts: List[str] = []
    parts.append("<!doctype html><html lang='de'><head><meta charset='utf-8'>")
    parts.append("<meta name='viewport' content='width=device-width, initial-scale=1'>")
    parts.append(f"<title>{html.escape('WhatsApp Chat: ' + title_names)}</title>")
    parts.append("<style>" + css + "</style></head><body><div class='wrap'>")

    parts.append("<div class='header'>")
    parts.append(f"<p class='h-title'>WhatsApp Chat<br>{html.escape(title_names)}</p>")
    # r07: show only basename;
    parts.append(f"<p class='h-meta'>Quelle: {html.escape(Path(chat_path).name)}<br>"
    # R07: Header simplified – file mtime omitted.
                 f"Export: {html.escape(mtime.strftime('%d.%m.%Y %H:%M:%S'))}<br>"
                 f"Nachrichten: {len(msgs)}</p>")
    parts.append("</div>")

    last_day: Optional[dt.date] = None

    for m in msgs:
        day = m.ts.date()
        if last_day != day:
            wd = WEEKDAY_DE[day.weekday()]
            parts.append(f"<div class='day'><span>{html.escape(wd + ', ' + fmt_date_full(day))}</span></div>")
            last_day = day

        author = _norm_space(m.author) or "Unbekannt"
        is_me = (author == me_name)
        row_cls = "me" if is_me else "other"
        bub_cls = "me" if is_me else "other"

        text_raw = m.text or ""
        attachments = find_attachments(text_raw)
        text_wo_attach = strip_attachment_markers(text_raw)

        # html text
        text_html = html_escape_keep_newlines(text_wo_attach) if text_wo_attach else ""

        # urls + preview
        urls = extract_urls(text_wo_attach)
        preview_html = ""
        if enable_previews and urls:
            # show preview for first url; show remaining as plain
            first = urls[0]
            prev = build_preview(first)
            if prev:
                img_block = ""
                if prev.image_data_url:
                    img_block = f"<div class='pimg'><img alt='' src='{prev.image_data_url}'></div>"
                ptitle = html.escape(prev.title or first)
                pdesc = html.escape(prev.description or "")
                preview_html = (
                    "<div class='preview'>"
                    f"<a href='{html.escape(first)}' target='_blank' rel='noopener'>"
                    f"{img_block}"
                    f"<div class='pbody'><p class='ptitle'>{ptitle}</p>"
                    + (f"<p class='pdesc'>{pdesc}</p>" if pdesc else "")
                    + "</div></a></div>"
                )

        # attachments (images only) embedded
        media_blocks: List[str] = []
        for fn in attachments:
            p = (chat_path.parent / fn).resolve()
            data_url = file_to_data_url(p)
            if data_url and guess_mime_from_name(fn).startswith("image/"):
                media_blocks.append(f"<div class='media'><img alt='' src='{data_url}'></div>")
            else:
                # if not embeddable: show nothing (requested: filename text can go out)
                pass

        # also keep links as plain (if no preview image etc.)
        link_lines = ""
        if urls:
            # show all urls as lines (WhatsApp shows link too)
            link_lines = "<div class='linkline'>" + "<br>".join(
                f"<a href='{html.escape(u)}' target='_blank' rel='noopener'>{html.escape(u)}</a>" for u in urls
            ) + "</div>"

        parts.append(f"<div class='row {row_cls}'>")
        parts.append(f"<div class='bubble {bub_cls}'>")
        parts.append(f"<div class='name'>{html.escape(author)}</div>")
        if text_html:
            parts.append(f"<div class='text'>{text_html}</div>")
        if preview_html:
            parts.append(preview_html)
        if link_lines:
            parts.append(link_lines)
        if media_blocks:
            parts.extend(media_blocks)

        parts.append(f"<div class='meta'>{html.escape(fmt_time(m.ts.time()))}<br>{html.escape(fmt_date_full(m.ts.date()))}</div>")
        parts.append("</div></div>")

    parts.append("</div></body></html>")
    out_html.write_text("".join(parts), encoding="utf-8")


def render_md(
    msgs: List[Message],
    chat_path: Path,
    out_md: Path,
    me_name: str,
) -> None:
    authors = []
    for m in msgs:
        a = _norm_space(m.author)
        if a and a not in authors:
            authors.append(a)
    others = [a for a in authors if a != me_name]
    if len(others) == 1:
        title_names = f"{me_name} ↔ {others[0]}"
    elif len(others) > 1:
        title_names = f"{me_name} ↔ {', '.join(others)}"
    else:
        title_names = f"{me_name} ↔ Chat"

    try:
        mtime = dt.datetime.fromtimestamp(chat_path.stat().st_mtime)
    except Exception:
        mtime = dt.datetime.now()

    lines: List[str] = []
    lines.append(f"# WhatsApp Chat: {title_names}")
    lines.append("")
    lines.append(f"- Quelle: {chat_path}")
    lines.append(f"- Export (file mtime): {mtime.strftime('%d.%m.%Y %H:%M:%S')}")
    lines.append(f"- Nachrichten: {len(msgs)}")
    lines.append("")

    last_day: Optional[dt.date] = None
    for m in msgs:
        day = m.ts.date()
        if last_day != day:
            wd = WEEKDAY_DE[day.weekday()]
            lines.append(f"## {wd}, {fmt_date_full(day)}")
            lines.append("")
            last_day = day

        author = _norm_space(m.author) or "Unbekannt"
        ts_line = f"{fmt_time(m.ts.time())} / {fmt_date_full(m.ts.date())}"
        text_raw = m.text or ""
        attachments = find_attachments(text_raw)
        text_wo_attach = strip_attachment_markers(text_raw)

        lines.append(f"**{author}**  ")
        lines.append(f"*{ts_line}*  ")
        if text_wo_attach.strip():
            lines.append(text_wo_attach.strip())
        urls = extract_urls(text_wo_attach)
        if urls:
            for u in urls:
                lines.append(f"- {u}")
        # attachments: keep as relative file refs (not embedded in md)
        for fn in attachments:
            # user asked: in HTML no filename; in md it's ok to reference
            lines.append(f"![Anhang]({fn})")
        lines.append("")

    out_md.write_text("\n".join(lines), encoding="utf-8")


# ---------------------------
# Main
# ---------------------------

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="WhatsApp _chat.txt -> HTML + Markdown (R06 rev0.6)")
    ap.add_argument("chat", help="Path to WhatsApp _chat.txt")
    ap.add_argument("--outdir", default=".", help="Output directory (default: current)")
    ap.add_argument("--no-previews", action="store_true", help="Disable online link previews")
    ap.add_argument("--me", dest="me", default=None, help="Your display name (for styling). If omitted, auto-detect.")
    args = ap.parse_args(argv)

    chat_path = Path(args.chat).expanduser().resolve()
    outdir = Path(args.outdir).expanduser().resolve()
    outdir.mkdir(parents=True, exist_ok=True)

    msgs = parse_messages(chat_path)

    # collect authors from parsed messages
    authors = [m.author for m in msgs if _norm_space(m.author)]
    me_name = args.me if args.me else choose_me_name(authors)

    # output filename: include chat partner(s), chat period (first/last message date) and render timestamp
    now = dt.datetime.now()

    authors = sorted({a for a in authors if _norm_space(a) and a != SYSTEM_AUTHOR})
    me_norm = _norm_space(me_name)
    partners = [a for a in authors if _norm_space(a) != me_norm]

    if not partners:
        partners_part = "UNKNOWN"
    elif len(partners) <= 3:
        partners_part = "+".join(partners)
    else:
        partners_part = "+".join(partners[:3]) + f"+{len(partners)-3}more"

    # chat period (date only)
    if msgs:
        start_date = min(m.ts for m in msgs).date().isoformat()
        end_date = max(m.ts for m in msgs).date().isoformat()
        period_part = f"{start_date}_to_{end_date}"
    else:
        period_part = "NO_MESSAGES"

    base = "_".join([
        safe_filename_stem("WHATSAPP_CHAT"),
        safe_filename_stem(partners_part),
        period_part,
        now.strftime("%Y-%m-%d_%H-%M-%S"),
    ])

    out_html = outdir / f"{base}.html"
    out_md = outdir / f"{base}.md"

    print(f"Messages: {len(msgs)}")
    try:
        mtime = dt.datetime.fromtimestamp(chat_path.stat().st_mtime)
        print(f"Export (file mtime): {mtime.strftime('%d.%m.%Y %H:%M:%S')}")
    except Exception:
        pass

    render_html(msgs, chat_path, out_html, me_name=me_name, enable_previews=(not args.no_previews))
    render_md(msgs, chat_path, out_md, me_name=me_name)

    print(f"OK: wrote {out_html.name}")
    print(f"OK: wrote {out_md.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())