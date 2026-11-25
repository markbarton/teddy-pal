#!/usr/bin/env python3
"""Generate 13 x (48x48, 8x6 = 48 frames) 8-bit orange Maine Coon sprite sheets
matching ClawPal's exact lossless 4-bit indexed PNG mascot specification.
"""

from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
MASCOT_DIR = ROOT / "assets" / "mascot"
BACKUP_DIR = ROOT / "assets" / "mascot-crab-backup"

SIZE = 48
COLS = 8
ROWS = 6
FRAMES = COLS * ROWS

# Base palette (10 colors incl. transparent) + prop colors (always <= 16 per sheet)
PAL = {
    ".": (0, 0, 0, 0),          # transparent
    "K": (58, 32, 22, 255),     # warm espresso 8-bit outline
    "O": (236, 126, 40, 255),   # rich ginger orange fur
    "D": (190, 85, 23, 255),    # tabby rust stripes & deep fur shadow
    "H": (248, 166, 75, 255),   # warm golden highlight
    "C": (252, 228, 188, 255),  # fluffy cream Maine Coon chest mane & paws
    "S": (229, 190, 138, 255),  # cream mane shading
    "P": (238, 138, 149, 255),  # pink nose & inner ear
    "G": (185, 196, 56, 255),   # golden-green Maine Coon eye iris
    "W": (255, 253, 247, 255),  # crisp white eye glint & whiskers
    # Prop colors (only used on sheets that need them -> always <= 16 colors/sheet)
    "M": (181, 186, 196, 255),  # metal / light grey cloud / headphones
    "N": (118, 128, 145, 255),  # dark grey cloud / metal shadow / keyboard
    "B": (72, 149, 201, 255),   # blue notes / Zzz / raindrops / headphones
    "Y": (255, 200, 69, 255),   # gold sparkles / sun / moon / stars / note
    "R": (232, 69, 60, 255),    # red alert / happy tongue
    "L": (216, 232, 245, 255),  # light sky / keycap / puddle glint
}


def blank_frame():
    return [["." for _ in range(SIZE)] for _ in range(SIZE)]


def put(grid, x, y, ch):
    if 0 <= x < SIZE and 0 <= y < SIZE:
        grid[y][x] = ch


def stamp(grid, ox, oy, lines):
    for dy, row in enumerate(lines):
        for dx, ch in enumerate(row):
            if ch != " ":
                put(grid, ox + dx, oy + dy, ch)


# Sitting orange Maine Coon head (28px wide x 16px tall, centered around dx=13..14)
# Tall lynx-tufted ears, tabby forehead M-stripes, puffy cream whisker pads, white whiskers.
CAT_HEAD = [
    # 0         1         2
    # 0123456789012345678901234567
    "   K                    K   ",  # 0  tall lynx ear-tip tufts!
    "   KK                  KK   ",  # 1
    "   KOK                KOK   ",  # 2
    "   KOPK              KPOK   ",  # 3  tall pointed Maine Coon ears
    "   KOPOK            KOPOK   ",  # 4
    "   KOPOOKKKKKKKKKKKKOOPOK   ",  # 5
    "   KOOHHODDOOHHODDOOHHOOK   ",  # 6  tabby forehead stripes!
    "   KOOHOOHODDOODDOOHOOHOK   ",  # 7
    "   KOOOOOOHOOOHOOOOOOOOOK   ",  # 8
    "  KOOOOOOOOOOOOOOOOOOOOOOK  ",  # 9  clean eye zone (eyes stamped on top)
    "  KOOOOOOOOOOOOOOOOOOOOOOK  ",  # 10
    "WWKOOOOOOOOOOOOOOOOOOOOOOKWW",  # 11 glorious Maine Coon whiskers!
    "  KOOOOOOOOOOPPOOOOOOOOOOK  ",  # 12 cute pink nose
    "WWKCCOOOOOOCCPPCCOOOOOOCCKWW",  # 13 puffy cream whisker pads + whiskers
    "   KCCCOOOCCCCCCCCOOOCCCK   ",  # 14 soft cream muzzle (mouth stamped on top)
    "    KCCCSSCCCCCCCCSSCCCK    ",  # 15 fluffy cream chin flowing into mane
]

# Seated Maine Coon body with lush fluffy cream mane & ginger tabby flanks (28px wide x 16px tall)
CAT_BODY = [
    # 0123456789012345678901234567
    "    KOOCCCSCCCCCSCCCOOK     ",  # 0
    "   KOODCCCCCCCCCCCCCDDOK    ",  # 1
    "   KOOCCCCCCCCCCCCCCCOOK    ",  # 2  big fluffy cream Maine Coon chest mane
    "   KODCCCCCCCCCCCCCCCSDOK   ",  # 3
    "   KOOCCCSCCCCCCCSCCCCOOK   ",  # 4
    "   KOOCCCSCCCCCCCSCCCCOOK   ",  # 5
    "   KODCCCSSCCCCCSSCCCSDOK   ",  # 6  ginger tabby stripes on flanks
    "   KOODCCCSSCCCSSCCCSDOOK   ",  # 7
    "   KOOODCCCSSSSSCCCSDOOOK   ",  # 8
    "   KOOOOCCCSSSSSCCCOOOOOK   ",  # 9
    "   KODDOOCCCSCSCCCOODDOOK   ",  # 10
    "   KOOOOOCCCCCCCCCOOOOOOK   ",  # 11
    "   KOOOOOKCCCSCCCKOOOOOOK   ",  # 12 front legs separating
    "    KOOOKCCCCKCCCCKOOOK     ",  # 13 fluffy paws
    "    KCCCKCCCK KCCCKCCCK     ",  # 14 cute cream paws
    "     KKKKKKKK KKKKKKKK      ",  # 15
]

# Cozy curled-up sleeping Maine Coon loaf (34px wide x 23px tall, placed at ox=7, oy=21)
CAT_SLEEP = [
    "     K            K               ",  # 0  tall lynx ear tufts
    "     KK          KK               ",  # 1
    "     KOK        KOK               ",  # 2
    "     KOPK      KPOK               ",  # 3
    "     KOPOKKKKKKOPOK               ",  # 4
    "    KOOODDOOHODDOOOK              ",  # 5  tabby stripes
    "    KOOOOOHOOOHOOOOOK             ",  # 6
    "   KOOOOOOOOOOOOOOOOOKKKKKKK      ",  # 7  big curled fluffy back
    "   KOOOKKKOOOOOKKKOOOOOODDOOK     ",  # 8  peaceful closed eyes - -
    " WWKOOOOOOOOOOOOOOOOOHOOOOOOOK    ",  # 9  whiskers
    "   KCCOOOOOPPPOOOOOODDOOOHOOOK    ",  # 10 pink nose + tabby back stripes
    " WWKCCCOOOCCKCCOOOOOHOOOOOOOOK    ",  # 11
    "   KCCCCSSCCCCCCSOODDOOOOOOOOK    ",  # 12 fluffy cream mane
    "   KCCCCCCCCCCCCCOOHOOOOOOOOOK    ",  # 13
    "   KCCCSCCCCCCCSCCOOODDOOOHOOK    ",  # 14
    "   KOOCCCCCCCCCCCSSOOOOOOOOOOK    ",  # 15
    "   KOOOCCCCCCCCCCKKKKKKKKKKKK     ",  # 16 big fluffy plume tail curled in front!
    "    KOOOOCCCCCCCCOOHHHHOOOOOK     ",  # 17
    "    KCCCCKCCCCCCKOODDOOOHHHOK     ",  # 18 tucked cream paws + plume tail
    "     KKKKKKKKKKKKKKKKKKKKKKK      ",  # 19
]

# Fluffy Maine Coon plume tails connected cleanly into right body flank (placed at ox=27, oy=24)
TAILS = [
    # 0: lush upright plume connected smoothly at bottom-left
    [
        "        KKKK   ",
        "       KHHHOOK ",
        "      KHOOOOOOK",
        "      KDOOOHHOK",
        "      KOOOOOOOK",
        "      KOODDOOOK",
        "     KHOOOOOOOK",
        "     KOOOOOHHOK",
        "     KDOOOOOOOK",
        "    KOOOOOOOOOK",
        "   KOOOODDOOOOK",
        "  KOOOOOOOOOOK ",
        " KOOOOOOOOOOK  ",
        " KOOOOOOOOOK   ",
        "  KKKKKKKKK    ",
    ],
    # 1: swaying right
    [
        "         KKKK  ",
        "        KHHHOOK",
        "        KHOOOOK",
        "       KDOOOHOK",
        "       KOOOOOOK",
        "       KOODDOOK",
        "      KHOOOOOOK",
        "      KOOOOOHOK",
        "     KDOOOOOOOK",
        "    KOOOOOOOOOK",
        "   KOOOODDOOOK ",
        "  KOOOOOOOOOOK ",
        " KOOOOOOOOOK   ",
        " KOOOOOOOOK    ",
        "  KKKKKKKK     ",
    ],
    # 2: swaying gently inward
    [
        "      KKKK     ",
        "     KHHHOOK   ",
        "     KHOOOOOK  ",
        "     KDOOOHOK  ",
        "     KOOOOOOK  ",
        "     KOODDOOK  ",
        "     KHOOOOOK  ",
        "     KOOOOOOK  ",
        "    KDOOOOOOK  ",
        "   KOOOOOOOOK  ",
        "  KOOOODDOOOK  ",
        " KOOOOOOOOOOK  ",
        " KOOOOOOOOOK   ",
        " KOOOOOOOOK    ",
        "  KKKKKKKK     ",
    ],
    # 3: puffed bristling alert tail!
    [
        "       KKKKKK  ",
        "      KHHHOOOK ",
        "     KHOOOOOOOK",
        "    KDOOOHHHOOK",
        "    KOOOOOOOOOK",
        "    KOODDOOOOOK",
        "    KHOOOOOOOOK",
        "    KOOOOOHHOOK",
        "    KDOOOOOOOOK",
        "   KOOOOOOOOOOK",
        "  KOOOODDOOOOOK",
        " KOOOOOOOOOOOK ",
        " KOOOOOOOOOOK  ",
        " KOOOOOOOOOK   ",
        "  KKKKKKKKK    ",
    ],
]


def draw_eyes(grid, hx, hy, mood="open"):
    """Overlay symmetric eyes onto head at (hx, hy). Left eye dx=6..9, right eye dx=18..21."""
    if mood == "open":
        for ex in (6, 18):
            stamp(grid, hx + ex, hy + 9, [
                " GG ",
                "GKKG",
                "GWKG",
                " GG ",
            ])
    elif mood == "look_up":
        for ex in (6, 18):
            stamp(grid, hx + ex, hy + 9, [
                "GKKG",
                "GWKG",
                " GG ",
            ])
    elif mood == "blink":
        for ex in (6, 18):
            stamp(grid, hx + ex, hy + 10, [
                "    ",
                "KKKK",
            ])
    elif mood == "happy":
        for ex in (6, 18):
            stamp(grid, hx + ex, hy + 10, [
                " KK ",
                "K  K",
            ])
    elif mood == "focused":
        for ex in (6, 18):
            stamp(grid, hx + ex, hy + 9, [
                "DDDD",
                "GKKG",
                "GWKG",
                " GG ",
            ])
    elif mood == "wide":
        for ex in (6, 18):
            stamp(grid, hx + ex, hy + 9, [
                "GGGG",
                "GWWK",
                "GWKK",
                "GGGG",
            ])
    elif mood == "shades":
        # Symmetric cool retro pixel sunglasses!
        stamp(grid, hx + 4, hy + 9, [
            "KKKKKKKKKKKKKKKKKKKK",
            "KNNLNNKKKKKKNNLNNKK ",
            "KNNNNNKK  KKNNNNNKK ",
            " KKKKKK    KKKKKK   ",
        ])


def draw_mouth(grid, hx, hy, open_happy=False, frown=False):
    # Centered under pink nose (dx=13..14, dy=12..13)
    if open_happy:
        stamp(grid, hx + 12, hy + 13, [
            " PP ",
            "KRRK",
            " KK ",
        ])
    elif frown:
        stamp(grid, hx + 12, hy + 13, [
            " PP ",
            " KK ",
            "K  K",
        ])
    else:
        # Cute delicate :3 cat smile on cream muzzle
        stamp(grid, hx + 11, hy + 13, [
            "  PP  ",
            " K  K ",
            "  KK  ",
        ])


def draw_sitting_cat(grid, hx=6, hy=12, body_dy=0, tail_idx=0, eye_mood="open",
                     open_happy=False, frown=False, ear_twitch=False):
    # Tail behind body, smoothly overlapping the right flank at x=27..41
    stamp(grid, hx + 21, hy + 12 + body_dy, TAILS[tail_idx])
    # Seated body & fluffy cream mane
    stamp(grid, hx, hy + 15 + body_dy, CAT_BODY)
    # Head
    stamp(grid, hx, hy, CAT_HEAD)
    # Subtle ear-tip twitch
    if ear_twitch:
        put(grid, hx + 24, hy, ".")
        put(grid, hx + 25, hy + 1, "K")
    draw_eyes(grid, hx, hy, mood=eye_mood)
    draw_mouth(grid, hx, hy, open_happy=open_happy, frown=frown)


def draw_headphones(grid, hx, hy):
    # Retro grey headband arching cleanly between ears + blue earcups on cheeks
    stamp(grid, hx + 6, hy + 2, [
        "   KKKKKKKKKK   ",
        "  KMMMMMMMMMMK  ",
        " KMMNNNNNNNNMMK ",
        "KMMK        KMMK",
    ])
    stamp(grid, hx, hy + 8, [
        "KKK",
        "KBB",
        "KBB",
        "KBB",
        "KBB",
        "KKK",
    ])
    stamp(grid, hx + 25, hy + 8, [
        "KKK",
        "BBK",
        "BBK",
        "BBK",
        "BBK",
        "KKK",
    ])


def draw_keyboard(grid, ox, oy, active_col=0):
    stamp(grid, ox, oy, [
        "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKK",
        "KMMMMMMMMMMMMMMMMMMMMMMMMMMMMK",
        "KMLLLLLLLLLLLLLLLLLLLLLLLLLLMK",
        "KMNNNNNNNNNNNNNNNNNNNNNNNNNNMK",
        "KMLLLLLLLLLLLLLLLLLLLLLLLLLLMK",
        "KNNNNNNNNNNNNNNNNNNNNNNNNNNNNK",
        "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKK",
    ])
    kx = ox + 3 + (active_col % 7) * 3
    ky = oy + 2 + (active_col % 2) * 2
    col = "B" if active_col % 2 == 0 else "Y"
    put(grid, kx, ky, col)
    put(grid, kx + 1, ky, col)


def draw_note_single(grid, x, y, ch="Y"):
    stamp(grid, x, y, [
        f"  {ch}{ch}",
        f"  {ch} ",
        f"  {ch} ",
        f"{ch}{ch}{ch} ",
        f"{ch}{ch}  ",
    ])


def draw_note_double(grid, x, y, ch="B"):
    stamp(grid, x, y, [
        f" {ch}{ch}{ch}{ch}{ch}",
        f" {ch}   {ch}",
        f" {ch}   {ch}",
        f"{ch}{ch}  {ch}{ch}",
        f"{ch}{ch}  {ch}{ch}",
    ])


def draw_cloud(grid, ox, oy, dark=False):
    hi = "M" if dark else "L"
    mid = "N" if dark else "M"
    stamp(grid, ox, oy, [
        "      KKKKKK       ",
        f"    KK{hi}{hi}{hi}{hi}{hi}{hi}KK     ",
        f"  KK{hi}{hi}{hi}{hi}{hi}{hi}{hi}{hi}{hi}{hi}KK   ",
        f" K{hi}{hi}{hi}{hi}{hi}{hi}{hi}{hi}{hi}{hi}{hi}{hi}{hi}{hi}K  ",
        f"K{hi}{hi}{mid}{mid}{mid}{mid}{mid}{mid}{mid}{mid}{mid}{mid}{mid}{mid}{hi}{hi}K ",
        f"K{mid}{mid}{mid}{mid}{mid}{mid}{mid}{mid}{mid}{mid}{mid}{mid}{mid}{mid}{mid}{mid}K ",
        " KKKKKKKKKKKKKKKK  ",
    ])


def draw_sun(grid, ox, oy, phase=0):
    stamp(grid, ox, oy, [
        "  YYYY  ",
        " YYYYYY ",
        " YYYYYY ",
        "  YYYY  ",
    ])
    rays = [(ox + 3, oy - 2), (ox + 4, oy - 2), (ox + 9, oy + 1), (ox + 9, oy + 2),
            (ox + 3, oy + 5), (ox + 4, oy + 5), (ox - 2, oy + 1), (ox - 2, oy + 2)]
    diag = [(ox - 1, oy - 1), (ox + 8, oy - 1), (ox + 8, oy + 4), (ox - 1, oy + 4)]
    for rx, ry in (rays if phase % 2 == 0 else diag):
        put(grid, rx, ry, "Y")


def draw_moon(grid, ox, oy):
    stamp(grid, ox, oy, [
        "   YYYY ",
        "  YYYY  ",
        " YYY    ",
        " YYY    ",
        " YYY    ",
        "  YYYY  ",
        "   YYYY ",
    ])


def draw_star(grid, x, y, big=False, ch="Y"):
    put(grid, x, y, ch)
    if big:
        put(grid, x - 1, y, ch)
        put(grid, x + 1, y, ch)
        put(grid, x, y - 1, ch)
        put(grid, x, y + 1, ch)


def draw_z(grid, x, y, size=1, ch="B"):
    if size == 1:
        stamp(grid, x, y, [
            f"{ch}{ch}{ch}",
            f" {ch} ",
            f"{ch}{ch}{ch}",
        ])
    elif size == 2:
        stamp(grid, x, y, [
            f"{ch}{ch}{ch}{ch}",
            f"  {ch} ",
            f" {ch}  ",
            f"{ch}{ch}{ch}{ch}",
        ])
    else:
        stamp(grid, x, y, [
            f"{ch}{ch}{ch}{ch}{ch}",
            f"   {ch} ",
            f"  {ch}  ",
            f" {ch}   ",
            f"{ch}{ch}{ch}{ch}{ch}",
        ])


def draw_wrench(grid, ox, oy, tilt=0):
    if tilt == 0:
        stamp(grid, ox, oy, [
            " KK  KK ",
            "KMMKKMMK",
            "KMMMMMMK",
            " KKMMKK ",
            "  KMMK  ",
            "  KMMK  ",
            "  KMMK  ",
            "  KMMK  ",
            "  KKKK  ",
        ])
    else:
        stamp(grid, ox, oy, [
            "   KK KK",
            "  KMMKMK",
            "  KMMMMK",
            "  KMMKK ",
            " KMMK   ",
            "KMMK    ",
            "KMK     ",
            "KK      ",
        ])


def draw_parcel(grid, ox, oy):
    stamp(grid, ox, oy, [
        "KKKKKKKKKKKKKK",
        "KYYYYYWWYYYYYK",
        "KYYYYYWWYYYYYK",
        "KDDDDDWWDDDDDK",
        "KYYYYYWWYYYYYK",
        "KYYYYYWWYYYYYK",
        "KYYYYYWWYYYYYK",
        "KKKKKKKKKKKKKK",
    ])


def make_frame(state, f):
    g = blank_frame()
    blink = f in (30, 31, 32)
    tail_seq = [0, 0, 0, 1, 1, 1, 0, 0, 0, 2, 2, 2]
    tail = tail_seq[(f // 2) % len(tail_seq)]
    breathe = 1 if (f % 16) >= 8 else 0
    ear_twitch = f in (14, 15)

    if state == "idle":
        draw_sitting_cat(g, hx=6, hy=13 + breathe, body_dy=0, tail_idx=tail,
                         eye_mood="blink" if blink else "open", ear_twitch=ear_twitch)

    elif state == "happy":
        hop = -2 if (f % 8) in (2, 3, 4) else 0
        tail_h = 1 if (f % 4) < 2 else 2
        draw_sitting_cat(g, hx=6, hy=13 + hop, body_dy=hop, tail_idx=tail_h,
                         eye_mood="happy", open_happy=True)
        sp = f % 12
        if sp >= 2:
            put(g, 20, 4, "Y"); put(g, 20, 5, "Y"); put(g, 20, 6, "Y")
        if sp >= 4:
            put(g, 13, 6, "Y"); put(g, 14, 7, "Y")
            put(g, 27, 6, "Y"); put(g, 26, 7, "Y")
        if sp in (5, 6, 7, 8):
            draw_star(g, 7, 6, big=True, ch="Y")
            draw_star(g, 35, 7, big=False, ch="Y")

    elif state == "music":
        bob = 1 if (f % 6) >= 3 else 0
        tail_m = 1 if (f % 6) < 3 else 2
        draw_sitting_cat(g, hx=6, hy=13 + bob, body_dy=0, tail_idx=tail_m,
                         eye_mood="happy", open_happy=(f % 12) < 6)
        draw_headphones(g, 6, 13 + bob)
        ny1 = 3 + ((f // 2) % 4)
        ny2 = 5 - ((f // 2) % 4)
        draw_note_single(g, 2, ny1, "Y")
        draw_note_double(g, 39, ny2, "B")

    elif state == "typing":
        tap = (f // 2) % 4
        draw_sitting_cat(g, hx=6, hy=11, body_dy=0, tail_idx=tail,
                         eye_mood="blink" if blink else "focused")
        draw_keyboard(g, 6, 39, active_col=f // 2)
        lp_y = 37 if tap in (0, 2) else 38
        rp_y = 38 if tap in (0, 2) else 37
        stamp(g, 10, lp_y, ["KKKK", "KCCK", "KKKK"])
        stamp(g, 26, rp_y, ["KKKK", "KCCK", "KKKK"])

    elif state == "sleeping":
        s_breathe = 1 if (f % 16) >= 8 else 0
        stamp(g, 6, 22 + s_breathe, CAT_SLEEP)
        z_phase = f % 36
        if 4 <= z_phase < 30:
            draw_z(g, 30, 16 - (z_phase // 8), size=1, ch="B")
        if 12 <= z_phase < 32:
            draw_z(g, 34, 10 - ((z_phase - 12) // 8), size=2, ch="B")
        if z_phase >= 20:
            draw_z(g, 39, 4 - ((z_phase - 20) // 10), size=3, ch="B")

    elif state == "thinking":
        draw_sitting_cat(g, hx=6, hy=13 + breathe, body_dy=0, tail_idx=tail,
                         eye_mood="blink" if blink else "look_up")
        # Raised cream paw near chin
        stamp(g, 22, 28, [" KKK", "KCCK", "KCCK", " KKK"])
        tp = (f // 4) % 4
        if tp >= 1:
            stamp(g, 29, 10, ["KK", "KK"])
        if tp >= 2:
            stamp(g, 33, 7, ["KKK", "KWK", "KKK"])
        if tp >= 3:
            stamp(g, 37, 2, [
                " KKKKK ",
                "KWWWWWK",
                "KWWYWWK",
                "KWWWWWK",
                " KKKKK ",
            ])

    elif state == "working":
        bob = 1 if (f % 6) >= 3 else 0
        draw_sitting_cat(g, hx=5, hy=13 + bob, body_dy=0, tail_idx=2,
                         eye_mood="blink" if blink else "focused")
        # Wrench floating cleanly above right shoulder with work sparks (clear of tail!)
        draw_wrench(g, 36, 9 + bob, tilt=(f // 3) % 2)
        if (f % 6) < 3:
            draw_star(g, 35, 5, big=True, ch="Y")
            draw_star(g, 43, 6, big=False, ch="Y")

    elif state == "carrying":
        step = -1 if (f % 6) < 3 else 0
        draw_sitting_cat(g, hx=6, hy=12 + step, body_dy=step, tail_idx=1 if step else 2,
                         eye_mood="blink" if blink else "open", open_happy=True)
        draw_parcel(g, 13, 30 + step)
        stamp(g, 11, 33 + step, ["KK", "CK", "KK"])
        stamp(g, 27, 33 + step, ["KK", "KC", "KK"])

    elif state == "error":
        shake = -1 if (f % 4) == 1 else (1 if (f % 4) == 3 else 0)
        draw_sitting_cat(g, hx=6 + shake, hy=13, body_dy=0, tail_idx=3,
                         eye_mood="wide", frown=True)
        ey = 2 if (f % 8) < 4 else 3
        stamp(g, 18, ey, [
            "KKKK",
            "KRRK",
            "KRRK",
            "KRRK",
            "KRRK",
            "KKKK",
            "    ",
            "KKKK",
            "KRRK",
            "KKKK",
        ])

    elif state == "sunny":
        draw_sitting_cat(g, hx=6, hy=14 + breathe, body_dy=0, tail_idx=tail,
                         eye_mood="shades", open_happy=True)
        draw_sun(g, 34, 3, phase=f // 4)

    elif state == "cloudy":
        draw_sitting_cat(g, hx=6, hy=14 + breathe, body_dy=0, tail_idx=tail,
                         eye_mood="blink" if blink else "look_up")
        cx = 13 + (1 if (f % 16) < 8 else 0)
        draw_cloud(g, cx, 3, dark=False)

    elif state == "rainy":
        draw_sitting_cat(g, hx=6, hy=15, body_dy=0, tail_idx=2,
                         eye_mood="blink" if blink else "open", frown=True)
        draw_cloud(g, 13, 2, dark=True)
        stamp(g, 6, 44, [
            "   BBBBBBBBBBBBBBBBBBBBBB   ",
            " BBLBBBBBLLLBBBBBBLLBBBBBB  ",
            "   BBBBBBBBBBBBBBBBBBBBBB   ",
        ])
        for i, rx in enumerate((10, 17, 25, 33, 39)):
            ry = 10 + ((f * 2 + i * 7) % 30)
            if 10 <= ry <= 42 and g[ry][rx] == ".":
                put(g, rx, ry, "B")
                if ry + 1 <= 42 and g[ry + 1][rx] == ".":
                    put(g, rx, ry + 1, "L")

    elif state == "night":
        draw_sitting_cat(g, hx=6, hy=14 + breathe, body_dy=0, tail_idx=tail,
                         eye_mood="blink" if (f % 16) in (12, 13, 14) else "open")
        draw_moon(g, 35, 3)
        draw_star(g, 6, 5, big=(f % 12) < 6, ch="Y")
        draw_star(g, 16, 3, big=(f % 12) >= 6, ch="L")
        draw_star(g, 28, 7, big=((f + 4) % 12) < 6, ch="Y")

    return g


def render_sheet(state):
    sheet = Image.new("RGBA", (SIZE * COLS, SIZE * ROWS), (0, 0, 0, 0))
    px = sheet.load()
    colors = set()
    for f in range(FRAMES):
        grid = make_frame(state, f)
        ox = (f % COLS) * SIZE
        oy = (f // COLS) * SIZE
        for y in range(SIZE):
            for x in range(SIZE):
                rgba = PAL[grid[y][x]]
                px[ox + x, oy + y] = rgba
                colors.add(rgba)
    if len(colors) > 16:
        raise ValueError(f"State {state} has {len(colors)} colors (max 16)!")
    return sheet, len(colors)


def main():
    states = ("happy", "idle", "thinking", "working", "sleeping", "carrying",
              "typing", "music", "error", "sunny", "cloudy", "rainy", "night")

    if not BACKUP_DIR.exists():
        BACKUP_DIR.mkdir(parents=True, exist_ok=True)
        for p in MASCOT_DIR.glob("crab_*_sheet.png"):
            (BACKUP_DIR / p.name).write_bytes(p.read_bytes())

    preview_cols = 5
    preview_rows = 3
    scale = 4
    cell = SIZE * scale
    pad = 12
    preview = Image.new("RGBA", (preview_cols * (cell + pad) + pad, preview_rows * (cell + pad + 20) + pad), (20, 22, 28, 255))

    for idx, st in enumerate(states):
        sheet, ncols = render_sheet(st)
        out_path = MASCOT_DIR / f"crab_{st}_sheet.png"
        sheet.save(out_path, format="PNG")
        print(f"{st:10s}: saved ({ncols:2d} colors)")

        sample_f = 24 if st == "sleeping" else (14 if st == "thinking" else 6)
        fx = (sample_f % COLS) * SIZE
        fy = (sample_f // COLS) * SIZE
        frame_img = sheet.crop((fx, fy, fx + SIZE, fy + SIZE)).resize((cell, cell), Image.Resampling.NEAREST)
        pc = idx % preview_cols
        pr = idx // preview_cols
        preview.alpha_composite(frame_img, (pad + pc * (cell + pad), pad + pr * (cell + pad + 20)))

    preview_path = Path("/tmp/cat_mascot_preview.png")
    preview.save(preview_path, format="PNG")
    print(f"Preview saved to {preview_path}")


if __name__ == "__main__":
    main()
