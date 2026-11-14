#!/usr/bin/env python3
"""Generate a domain-only WKContentRuleList input from public, attributed lists.

Source licenses are recorded in Orbrisa/THIRD_PARTY_NOTICES.md.
Only plain ABP host rules are recognized, not all ABP syntax.
"""
from pathlib import Path
from urllib.request import Request, urlopen
import re
import sys

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "orbrisa/OrbrisaAdBlockDomains.txt")
SOURCES = [
    ("AdGuard DNS", "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt", 12000),
    ("EasyList adult popup", "https://raw.githubusercontent.com/easylist/easylist/master/easylist_adult/adult_adservers_popup.txt", 5000),
]
EXACT = re.compile(r"^\|\|([a-z0-9](?:[a-z0-9.-]{2,176}[a-z0-9])?)\^(?:\$[^\s]*)?$", re.I)
HOST = re.compile(r"^[a-z0-9][a-z0-9.-]*\.[a-z]{2,24}$", re.I)
ESSENTIAL = {
    "apple.com", "icloud.com", "github.com", "google.com", "youtube.com",
    "cloudflare.com", "cloudfront.net", "akamaihd.net", "akamai.net",
    "jsdelivr.net", "jwplayer.com", "vimeo.com", "fastly.net",
}
selected = []
seen = set()
for name, url, cap in SOURCES:
    try:
        req = Request(url, headers={"User-Agent": "Orbrisa-tvOS-adblock-build/1.0"})
        with urlopen(req, timeout=25) as response:
            raw = response.read(16_000_000)
        text = raw.decode("utf-8", errors="replace")
    except Exception as exc:
        print(f"[AdBlock] {name} unavailable: {exc}; keeping built-in rules")
        continue
    additions = 0
    for raw_line in text.splitlines():
        m = EXACT.fullmatch(raw_line.strip())
        if not m:
            continue
        domain = m.group(1).lower()
        if not HOST.fullmatch(domain) or domain in ESSENTIAL or domain in seen:
            continue
        if ".." in domain or domain.endswith("."):
            continue
        selected.append(domain)
        seen.add(domain)
        additions += 1
        if additions >= cap:
            break
    print(f"[AdBlock] {name}: +{additions} domain rules")

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(
    "# Generated third-party domain rules; see Orbrisa/THIRD_PARTY_NOTICES.md\n"
    + "\n".join(selected) + "\n"
)
print(f"[AdBlock] {len(selected)} external host rules ({OUT.stat().st_size} bytes)")
