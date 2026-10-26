#!/usr/bin/env python3
"""Source-level geometry regression for the Recently Played gallery."""
from pathlib import Path
import re
src = Path(__file__).resolve().parents[2] / "Sources" / "NuvioPlaybackLibrary.swift"
s = src.read_text(encoding="utf-8")

def constraint(name, anchor, reference):
    pattern = (rf"{name}\.{anchor}Anchor\.constraint\(equalTo: "
               rf"{reference}\.{anchor}Anchor, constant: ([0-9]+)\)")
    match = re.search(pattern, s)
    assert match, f"Missing {name}.{anchor} anchored to {reference}.{anchor}"
    return int(match.group(1))

assert re.search(r"tiles\.spacing\s*=\s*54\b", s), "Poster gap must be 54pt, up 50% from 36pt"
assert 54 == int(36 * 1.5)
assert "heading.topAnchor.constraint(equalTo: topAnchor, constant: 24)" in s
assert "heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32)" in s
assert "gallery.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44)" in s
assert "gallery.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 164)" in s
assert "widthAnchor.constraint(equalToConstant: 411)" in s, "Keep original 411pt poster width"
assert "poster.heightAnchor.constraint(equalToConstant: 601)" in s, "Keep original 601pt poster height"
print("Recently Played top-left geometry and 50% wider spacing: PASS")
