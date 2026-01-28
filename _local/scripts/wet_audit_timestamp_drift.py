#!/usr/bin/env python3
import os
import sys
from pathlib import Path


SKIP_DIRS = {"__MACOSX"}
SKIP_FILES = {".DS_Store"}


def scrub_component(comp: str) -> str:
    out = []
    last_underscore = False
    for ch in comp:
        if ch.isalpha():
            if not last_underscore:
                out.append("_")
                last_underscore = True
        else:
            out.append(ch)
            last_underscore = False
    trimmed = "".join(out).strip("_")
    return trimmed if trimmed else "_"


def sanitize(rel: str) -> str:
    p = rel.replace("\\", "/").strip("/")
    parts = [c for c in p.split("/") if c and c != "."]
    out = []
    for idx, comp in enumerate(parts):
        lower = comp.lower()
        if idx == 0 and (lower.startswith("whatsapp chat") or lower.startswith("whatsapp-chat")):
            continue
        if lower in {"documents", "images", "videos", "audios", "media", "attachments", "_thumbs", "_previews", "previews"}:
            out.append(lower)
        else:
            out.append(scrub_component(comp))
    return "/".join(out)


def is_skipped(path: Path) -> bool:
    name = path.name
    if name in SKIP_FILES:
        return True
    if name.startswith("._"):
        return True
    return False


def find_single_export_dir(root: Path) -> Path:
    entries = [p for p in root.iterdir() if p.is_dir() and not p.name.startswith(".")]
    entries = [p for p in entries if p.name not in SKIP_DIRS]
    if len(entries) != 1:
        raise RuntimeError("Expected exactly one export directory")
    return entries[0]


def collect_mtimes(base: Path) -> dict:
    out = {}
    for root, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        for name in files:
            if name in SKIP_FILES or name.startswith("._"):
                continue
            path = Path(root) / name
            rel = os.path.relpath(path, base)
            try:
                out[rel] = path.stat().st_mtime
            except FileNotFoundError:
                continue
    return out


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("Usage: wet_audit_timestamp_drift.py <folderOut> <zipOut>\n")
        return 2

    folder_root = Path(sys.argv[1]).resolve()
    zip_root = Path(sys.argv[2]).resolve()

    folder_base = find_single_export_dir(folder_root)
    zip_base = find_single_export_dir(zip_root)

    folder_map = collect_mtimes(folder_base)
    zip_map = collect_mtimes(zip_base)

    folder_keys = set(folder_map.keys())
    zip_keys = set(zip_map.keys())
    shared = folder_keys & zip_keys

    nonzero = 0
    plus3600 = 0
    minus3600 = 0
    pdf_nonzero = 0
    pdf_plus3600 = 0
    pdf_minus3600 = 0

    offenders = []
    pdf_offenders = []

    for rel in shared:
        delta = int(round(zip_map[rel] - folder_map[rel]))
        if delta != 0:
            nonzero += 1
        if delta == 3600:
            plus3600 += 1
            offenders.append(sanitize(rel))
        if delta == -3600:
            minus3600 += 1
            offenders.append(sanitize(rel))
        if rel.lower().endswith(".pdf"):
            if delta != 0:
                pdf_nonzero += 1
            if delta == 3600:
                pdf_plus3600 += 1
                pdf_offenders.append(sanitize(rel))
            if delta == -3600:
                pdf_minus3600 += 1
                pdf_offenders.append(sanitize(rel))

    missing_in_folder = len(zip_keys - folder_keys)
    missing_in_zip = len(folder_keys - zip_keys)

    print(
        "AUDIT: shared={} missing_in_folder={} missing_in_zip={} nonzero={} delta+3600={} delta-3600={}".format(
            len(shared), missing_in_folder, missing_in_zip, nonzero, plus3600, minus3600
        )
    )
    print(
        "AUDIT_PDF: shared={} nonzero={} delta+3600={} delta-3600={}".format(
            len([k for k in shared if k.lower().endswith(".pdf")]),
            pdf_nonzero,
            pdf_plus3600,
            pdf_minus3600,
        )
    )

    max_list = 10
    if plus3600 or minus3600:
        for rel in offenders[:max_list]:
            print("OFFENDER: {}".format(rel))
    if pdf_plus3600 or pdf_minus3600:
        for rel in pdf_offenders[:max_list]:
            print("OFFENDER_PDF: {}".format(rel))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
