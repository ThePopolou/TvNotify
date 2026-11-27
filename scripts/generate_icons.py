#!/usr/bin/env python3
"""Generate Control4 Experience Button icons for TvNotify Controller."""

import os
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "drivers", "tvnotify_controller", "www", "icons", "device")
SIZES = [1024, 512, 300, 90, 70]


def make_svg(state: str) -> str:
    # Palette per state
    cfg = {
        "idle_online": {
            "bg1": "#182232", "bg2": "#0F1622", "ring": "#2B3B54",
            "screen1": "#0D3B66", "screen2": "#092540",
            "bezel": "#E2E8F0", "stand": "#CBD5E1",
            "toast_bg": "#FFFFFF", "toast_accent": "#03A9F4", "toast_bar": "#334155",
            "toast_opacity": "1",
        },
        "badge_active": {
            "bg1": "#1A2332", "bg2": "#101620", "ring": "#3B4A62",
            "screen1": "#0E426E", "screen2": "#0A2845",
            "bezel": "#F1F5F9", "stand": "#CBD5E1",
            "toast_bg": "#FFFFFF", "toast_accent": "#03A9F4", "toast_bar": "#334155",
            "toast_opacity": "1",
        },
        "sent_confirm": {
            "bg1": "#132A20", "bg2": "#0B1B14", "ring": "#2A5742",
            "screen1": "#14532D", "screen2": "#0B331C",
            "bezel": "#ECFDF5", "stand": "#A7F3D0",
            "toast_bg": "#FFFFFF", "toast_accent": "#22C55E", "toast_bar": "#1E293B",
            "toast_opacity": "1",
        },
        "partial_offline": {
            "bg1": "#252016", "bg2": "#17140E", "ring": "#4D422A",
            "screen1": "#1E3A5F", "screen2": "#13243B",
            "bezel": "#E2E8F0", "stand": "#CBD5E1",
            "toast_bg": "#F8FAFC", "toast_accent": "#F59E0B", "toast_bar": "#475569",
            "toast_opacity": "0.92",
        },
        "all_offline": {
            "bg1": "#24191B", "bg2": "#161012", "ring": "#4A2E33",
            "screen1": "#272B33", "screen2": "#1B1E24",
            "bezel": "#94A3B8", "stand": "#64748B",
            "toast_bg": "#475569", "toast_accent": "#94A3B8", "toast_bar": "#94A3B8",
            "toast_opacity": "0.65",
        },
        "muted": {
            "bg1": "#1E2028", "bg2": "#13151B", "ring": "#3A3F4D",
            "screen1": "#262B36", "screen2": "#1A1E26",
            "bezel": "#CBD5E1", "stand": "#94A3B8",
            "toast_bg": "#64748B", "toast_accent": "#94A3B8", "toast_bar": "#CBD5E1",
            "toast_opacity": "0.55",
        },
    }[state]

    overlay = ""
    if state == "badge_active":
        # Prominent amber pinned-badge pill in top-right of TV
        overlay = """
        <g>
          <rect x="615" y="190" width="230" height="118" rx="59" fill="#0F172A"/>
          <rect x="631" y="206" width="198" height="86" rx="43" fill="#FFB300"/>
          <circle cx="678" cy="249" r="20" fill="#1E293B"/>
          <rect x="714" y="236" width="84" height="26" rx="13" fill="#1E293B"/>
        </g>"""
    elif state == "sent_confirm":
        # Crisp emerald checkmark badge in top-right
        overlay = """
        <g>
          <circle cx="786" cy="246" r="108" fill="#0B1B14"/>
          <circle cx="786" cy="246" r="90" fill="#22C55E"/>
          <path d="M740 248 L772 280 L836 212" fill="none" stroke="#FFFFFF" stroke-width="24" stroke-linecap="round" stroke-linejoin="round"/>
        </g>"""
    elif state == "partial_offline":
        # Amber warning badge in bottom-right
        overlay = """
        <g>
          <circle cx="786" cy="696" r="108" fill="#17140E"/>
          <circle cx="786" cy="696" r="90" fill="#F59E0B"/>
          <rect x="774" y="644" width="24" height="62" rx="12" fill="#1E293B"/>
          <circle cx="786" cy="734" r="14" fill="#1E293B"/>
        </g>"""
    elif state == "all_offline":
        # Coral red X offline badge in bottom-right
        overlay = """
        <g>
          <circle cx="786" cy="696" r="108" fill="#161012"/>
          <circle cx="786" cy="696" r="90" fill="#EF4444"/>
          <path d="M750 660 L822 732 M822 660 L750 732" fill="none" stroke="#FFFFFF" stroke-width="24" stroke-linecap="round"/>
        </g>"""
    elif state == "muted":
        # Diagonal mute slash across screen + muted indicator badge
        overlay = """
        <g>
          <line x1="250" y1="670" x2="774" y2="250" stroke="#13151B" stroke-width="58" stroke-linecap="round"/>
          <line x1="250" y1="670" x2="774" y2="250" stroke="#E2E8F0" stroke-width="28" stroke-linecap="round"/>
        </g>"""

    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="{cfg['bg1']}"/>
      <stop offset="100%" stop-color="{cfg['bg2']}"/>
    </linearGradient>
    <linearGradient id="scr" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="{cfg['screen1']}"/>
      <stop offset="100%" stop-color="{cfg['screen2']}"/>
    </linearGradient>
  </defs>

  <!-- Control4 dark-glass tile background -->
  <rect x="32" y="32" width="960" height="960" rx="200" fill="url(#bg)" stroke="{cfg['ring']}" stroke-width="16"/>

  <!-- TV Stand -->
  <rect x="456" y="704" width="112" height="72" rx="12" fill="{cfg['stand']}"/>
  <rect x="348" y="756" width="328" height="36" rx="18" fill="{cfg['stand']}"/>

  <!-- TV Frame & Screen -->
  <rect x="160" y="252" width="704" height="464" rx="44" fill="{cfg['bezel']}"/>
  <rect x="192" y="284" width="640" height="400" rx="22" fill="url(#scr)"/>

  <!-- Subtle screen glass highlight -->
  <path d="M214 284 L540 284 L380 684 L214 684 Q192 684 192 662 L192 306 Q192 284 214 284 Z" fill="#FFFFFF" opacity="0.05"/>

  <!-- On-screen Notification Toast Card -->
  <g opacity="{cfg['toast_opacity']}">
    <rect x="414" y="346" width="376" height="162" rx="34" fill="{cfg['toast_bg']}"/>
    <circle cx="486" cy="427" r="40" fill="{cfg['toast_accent']}"/>
    <rect x="550" y="394" width="196" height="26" rx="13" fill="{cfg['toast_bar']}"/>
    <rect x="550" y="438" width="136" height="22" rx="11" fill="{cfg['toast_bar']}" opacity="0.55"/>
  </g>
  {overlay}
</svg>
"""


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    states = ["idle_online", "badge_active", "sent_confirm", "partial_offline", "all_offline", "muted"]
    with tempfile.TemporaryDirectory() as tmp:
        for st in states:
            svg_path = os.path.join(tmp, f"{st}.svg")
            with open(svg_path, "w", encoding="utf-8") as f:
                f.write(make_svg(st))
            png_1024 = os.path.join(OUT_DIR, f"{st}_1024.png")
            subprocess.run(
                ["magick", "-background", "none", "-density", "192", svg_path, "-resize", "1024x1024", png_1024],
                check=True,
            )
            for sz in SIZES:
                if sz == 1024:
                    continue
                out_png = os.path.join(OUT_DIR, f"{st}_{sz}.png")
                subprocess.run(
                    ["sips", "-z", str(sz), str(sz), png_1024, "--out", out_png],
                    check=True,
                    stdout=subprocess.DEVNULL,
                )
            print(f"Generated {st} ({len(SIZES)} sizes)")


if __name__ == "__main__":
    main()
