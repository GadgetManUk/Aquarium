#!/bin/bash
# Static checks for SupportSite: the GitHub Pages site backing the URLs in
# Sources/AquariumApp/AquariumReleaseInfo.swift and the App Store metadata.
# No network access is required or performed; every check runs against the
# files on disk.
set -euo pipefail
cd "$(dirname "$0")/.."

python_bin=/usr/bin/python3
[[ -x "$python_bin" ]] || python_bin=python3

"$python_bin" - <<'PY'
import html.parser
import pathlib
import re
import sys

root = pathlib.Path("site")
failures = []
oks = []

def fail(msg):
    failures.append(msg)

def ok(msg):
    oks.append(msg)

# --- 0. Site files must exist -------------------------------------------------
required_files = [
    "index.html", "support.html", "privacy.html", "404.html", "styles.css",
    "assets/app-icon.png", "assets/aquarium-preview.jpg",
]
for name in required_files:
    path = root / name
    if path.is_file():
        ok(f"exists: {name}")
    else:
        fail(f"missing required file: {name}")

if failures:
    # Nothing else can be meaningfully checked without the files.
    print("\n".join(f"FAIL: {f}" for f in failures))
    print(f"\n{len(failures)} failing, {len(oks)} passing (stopped early: site files missing)")
    sys.exit(1)

pages = {
    "index.html": root / "index.html",
    "support.html": root / "support.html",
    "privacy.html": root / "privacy.html",
    "404.html": root / "404.html",
}
texts = {name: path.read_text(encoding="utf-8") for name, path in pages.items()}

# --- 1. Titles -----------------------------------------------------------------
for name, text in texts.items():
    match = re.search(r"<title>(.*?)</title>", text, re.IGNORECASE | re.DOTALL)
    if match and match.group(1).strip():
        ok(f"{name}: has non-empty <title>")
    else:
        fail(f"{name}: missing or empty <title>")

# --- 2. No <script> tags, no forms, no cookies keywords -------------------------
for name, text in texts.items():
    if re.search(r"<script", text, re.IGNORECASE):
        fail(f"{name}: contains a <script> tag")
    else:
        ok(f"{name}: no <script> tag")
    if re.search(r"<form", text, re.IGNORECASE):
        fail(f"{name}: contains a <form> tag")
    else:
        ok(f"{name}: no <form> tag")
    if re.search(r"document\.cookie", text, re.IGNORECASE):
        fail(f"{name}: references document.cookie")

# --- 3. HTML parsing: collect all href/src attributes --------------------------
class LinkCollector(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs = []
        self.srcs = []
        self.link_hrefs = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "a" and attrs.get("href"):
            self.hrefs.append(attrs["href"])
        if tag == "img" and attrs.get("src"):
            self.srcs.append(attrs["src"])
        if tag == "link" and attrs.get("href"):
            self.link_hrefs.append(attrs["href"])
        if tag == "script" and attrs.get("src"):
            self.srcs.append(attrs["src"])

ALLOWED_OUTBOUND_SUFFIXES = ("github.com", "apple.com", "gadgetmanuk.github.io")

def hostname_of(url):
    m = re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://([^/]+)", url)
    return m.group(1) if m else None

for name, text in texts.items():
    parser = LinkCollector()
    parser.feed(text)

    # img/link/script src: local only (no external resource loading).
    for src in parser.srcs:
        if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", src):
            fail(f"{name}: loads external resource src='{src}'")
        else:
            target = (root / src).resolve()
            if target.is_file():
                ok(f"{name}: local resource resolves: {src}")
            else:
                fail(f"{name}: local resource missing: {src}")

    for href in parser.link_hrefs:
        if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", href):
            fail(f"{name}: loads external <link href='{href}'>")
        else:
            target = (root / href).resolve()
            if target.is_file():
                ok(f"{name}: local <link> resolves: {href}")
            else:
                fail(f"{name}: local <link> target missing: {href}")

    # a href: local links must resolve to files that exist; outbound links
    # (http/https) are restricted to an allow-list of trusted domains.
    for href in parser.hrefs:
        if href.startswith("#"):
            continue
        if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", href):
            host = hostname_of(href)
            if host and any(host == suf or host.endswith("." + suf) for suf in ALLOWED_OUTBOUND_SUFFIXES):
                ok(f"{name}: outbound link to allow-listed host: {href}")
            else:
                fail(f"{name}: outbound link to disallowed host: {href}")
        elif href.startswith("mailto:"):
            fail(f"{name}: mailto link found (personal email must not be published): {href}")
        else:
            local_target = href.split("#", 1)[0]
            if not local_target:
                continue
            target = (root / local_target).resolve()
            if target.is_file():
                ok(f"{name}: local link resolves: {href}")
            else:
                fail(f"{name}: broken local link: {href}")

# --- 4. No personal email address anywhere on the site --------------------------
email_pattern = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
for name, text in texts.items():
    if email_pattern.search(text):
        fail(f"{name}: contains what looks like an email address")
    else:
        ok(f"{name}: no email-address pattern")

# --- 5. Content requirements -----------------------------------------------------
def require(name, text, needle, label):
    if needle.lower() in text.lower():
        ok(f"{name}: mentions {label}")
    else:
        fail(f"{name}: missing expected content — {label}")

require("support.html", texts["support.html"], "github.com/GadgetManUk/Aquarium/issues", "GitHub Issues support URL")
require("support.html", texts["support.html"], "Restore Purchases", "Restore Purchases instructions")
require("support.html", texts["support.html"], "reportaproblem.apple.com", "Apple refund URL")
require("support.html", texts["support.html"], "About Aquarium", "About Aquarium location")

require("index.html", texts["index.html"], "macOS 14", "macOS 14 system requirement")
require("index.html", texts["index.html"], "Aquarium Pro", "Aquarium Pro edition")
require("index.html", texts["index.html"], "support.html", "link to Support")
require("index.html", texts["index.html"], "privacy.html", "link to Privacy")
require("index.html", texts["index.html"], "Coming to the Mac App Store", "non-live App Store status")

privacy_lower = texts["privacy.html"].lower()
for phrase, label in [
    ("does not collect", "no data collection statement"),
    ("storekit", "StoreKit purchase processing statement"),
    ("github pages", "GitHub Pages hosting disclosure"),
    ("no cookies", "no cookies statement"),
    ("children", "children section"),
    ("26 september 2026", "effective date"),
    ("paul hilton", "developer name"),
]:
    if phrase in privacy_lower:
        ok(f"privacy.html: mentions {label}")
    else:
        fail(f"privacy.html: missing expected content — {label}")

if re.search(r"family sharing", privacy_lower) or re.search(r"family sharing", texts["support.html"].lower()):
    fail("site claims Family Sharing support, which is not implemented")
else:
    ok("site does not claim Family Sharing support")

# --- 6. Footer copyright on every page -------------------------------------------
for name, text in texts.items():
    if "2026 Paul Hilton" in text:
        ok(f"{name}: has copyright footer")
    else:
        fail(f"{name}: missing copyright footer")

# --- 7. Image size limits ---------------------------------------------------------
SIZE_LIMITS = {
    "assets/app-icon.png": 300_000,
    "assets/aquarium-preview.jpg": 400_000,
}
for name, limit in SIZE_LIMITS.items():
    path = root / name
    if not path.is_file():
        fail(f"missing image: {name}")
        continue
    size = path.stat().st_size
    if size <= limit:
        ok(f"{name}: {size} bytes <= {limit} byte limit")
    else:
        fail(f"{name}: {size} bytes exceeds {limit} byte limit")

# Any other image dropped into assets/ must also stay reasonably small.
for path in (root / "assets").glob("*"):
    if path.suffix.lower() in {".png", ".jpg", ".jpeg"} and str(path.relative_to(root)) not in SIZE_LIMITS:
        size = path.stat().st_size
        if size <= 400_000:
            ok(f"{path.relative_to(root)}: {size} bytes <= 400000 byte limit")
        else:
            fail(f"{path.relative_to(root)}: {size} bytes exceeds 400000 byte limit")

# --- Report ------------------------------------------------------------------------
print(f"{len(oks)} checks passed")
if failures:
    print()
    for f in failures:
        print(f"FAIL: {f}")
    print(f"\n{len(failures)} failing, {len(oks)} passing")
    sys.exit(1)

print("All SupportSite checks passed.")
PY
