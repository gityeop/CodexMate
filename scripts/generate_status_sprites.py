#!/usr/bin/env python3

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path


CATALOG_NAME = "StatusSprites.xcassets"
FRAME_GRID_SIZE = 24
FRAME_SCALE = 3
FRAME_COUNT = 6
SPRITE_SHEET_FILENAME = "sprite_sheet.png"
OVERRIDES_DIRNAME = "status_sprite_overrides"
SPRITE_NAMES = [
    "status_connecting",
    "status_idle",
    "status_waiting_for_user",
    "status_running",
    "status_failed",
    "status_unread",
]

TRANSPARENT = "."
BODY_HIGHLIGHT = "H"
BODY_LIGHT = "L"
BODY_MID = "M"
BODY_SHADOW = "S"
GLYPH = "G"
ACCENT = "A"
ALERT = "R"

PALETTE = {
    TRANSPARENT: None,
    BODY_HIGHLIGHT: "#FFFFFF",
    BODY_LIGHT: "#DCEEFF",
    BODY_MID: "#B9D8FF",
    BODY_SHADOW: "#8FBFFF",
    GLYPH: "#3B86F7",
    ACCENT: "#63A8FF",
    ALERT: "#FF6B6B",
}

# Derived from /Users/imsang-yeob/Downloads/codash.png and padded into a 24x24 pixel grid.
BASE_BODY = [
    ".........XXXXXX.........",
    ".......XXXXXXXXXX.......",
    "......XXXXXXXXXXXX......",
    ".....XXXXXXXXXXXXXX.....",
    ".....XXXXXXXXXXXXXX.....",
    "....XXXXXXXXXXXXXXXX....",
    "....XXX..XXXXXXXXXXX....",
    "....XXXX.XXXXXXXXXXX....",
    "....XXXXX.XXXXXXXXXX....",
    "....XXXXX.XXXXXXXXXX....",
    "...XXXXX..XXXXXXXXXXX...",
    "...XXXX..XXX.....XXXX...",
    "...XXXXXXXXXXXXXXXXXX...",
    "..XXXXXXXXXXXXXXXXXXXX..",
    ".XXXXXXXXXXXXXXXXXXXXXX.",
    "XXXXXXXXXXXXXXXXXXXXXXXX",
    "XXXXXXXXXXXXXXXXXXXXXXXX",
    "XXXXXXXXXXXXXXXXXXXXXXXX",
    "..XXXXXXXXXXXXXXXXXXXX..",
]

ARROW = {(1, 0), (2, 0), (2, 1), (3, 1), (3, 2), (4, 2), (3, 3), (2, 3), (2, 4), (1, 4)}
UNDERSCORE = {(x, y) for y in range(2) for x in range(6)}
BLINK_LEFT_EYE = {(x, 0) for x in range(5)} | {(1, 1), (2, 1), (3, 1)}
BLINK_RIGHT_EYE = {(x, 0) for x in range(4)}
DOT = {(x, y) for y in range(2) for x in range(2)}
BUBBLE = {(x, y) for y in range(6) for x in range(8) if not ((x in (0, 7)) and (y in (0, 5)))}
BUBBLE_TAIL = {(2, 6), (3, 6), (3, 7)}
BADGE = {(x, y) for y in range(6) for x in range(6) if (x - 2.5) ** 2 + (y - 2.5) ** 2 <= 7}
BADGE_PULSE = BADGE | {(0, 2), (5, 2), (2, 0), (2, 5)}
BURST = {
    (3, 0),
    (2, 1), (3, 1), (4, 1),
    (1, 2), (2, 2), (3, 2), (4, 2), (5, 2),
    (0, 3), (1, 3), (2, 3), (3, 3), (4, 3), (5, 3),
    (1, 4), (2, 4), (3, 4), (4, 4), (5, 4),
    (2, 5), (3, 5), (4, 5),
    (3, 6),
}
EXCLAMATION = {(1, 1), (1, 2), (1, 3), (1, 5)}
FAIL_EYE = {(0, 0), (1, 0), (1, 1), (0, 1), (1, 2), (0, 2)}

CATALOG_CONTENTS = {
    "info": {
        "author": "xcode",
        "version": 1,
    }
}

IMAGESET_CONTENTS = {
    "images": [
        {
            "filename": SPRITE_SHEET_FILENAME,
            "idiom": "universal",
        }
    ],
    "info": {
        "author": "xcode",
        "version": 1,
    },
    "properties": {
        "preserves-vector-representation": False,
    },
}


def blank_grid() -> list[list[str]]:
    return [[TRANSPARENT] * FRAME_GRID_SIZE for _ in range(FRAME_GRID_SIZE)]


def blank_mask() -> list[list[bool]]:
    return [[False] * FRAME_GRID_SIZE for _ in range(FRAME_GRID_SIZE)]


def paint(grid: list[list[str]], points: set[tuple[int, int]], origin_x: int, origin_y: int, value: str) -> None:
    for x, y in points:
        pixel_x = origin_x + x
        pixel_y = origin_y + y
        if 0 <= pixel_x < FRAME_GRID_SIZE and 0 <= pixel_y < FRAME_GRID_SIZE:
            grid[pixel_y][pixel_x] = value


def blit_body(mask: list[list[bool]], dx: int = 0, dy: int = 0) -> None:
    for y, row in enumerate(BASE_BODY):
        for x, cell in enumerate(row):
            if cell != "X":
                continue

            pixel_x = x + dx
            pixel_y = y + 2 + dy
            if 0 <= pixel_x < FRAME_GRID_SIZE and 0 <= pixel_y < FRAME_GRID_SIZE:
                mask[pixel_y][pixel_x] = True


def shade_body(mask: list[list[bool]]) -> list[list[str]]:
    grid = blank_grid()
    filled_rows = [index for index, row in enumerate(mask) if any(row)]
    if not filled_rows:
        return grid

    top = filled_rows[0]
    bottom = filled_rows[-1]

    for y, row in enumerate(mask):
        filled_columns = [index for index, cell in enumerate(row) if cell]
        if not filled_columns:
            continue

        left = filled_columns[0]
        right = filled_columns[-1]

        for x in filled_columns:
            tone = BODY_MID

            if y <= top + 2:
                tone = BODY_HIGHLIGHT
            elif y <= top + 7:
                tone = BODY_LIGHT

            if x <= left + 1 and y <= top + 9:
                tone = BODY_HIGHLIGHT

            if x >= right - 1 or y >= bottom - 1:
                tone = BODY_SHADOW
            elif y >= bottom - 4:
                tone = BODY_MID

            if x >= right - 3 and y >= top + 8:
                tone = BODY_SHADOW

            grid[y][x] = tone

    return grid


def frame(status_name: str, frame_index: int) -> list[list[bool]]:
    sway_x = {
        "status_idle": [0, 0, 0, 0, 0, 0],
        "status_connecting": [0, 0, 0, 0, 0, 0],
        "status_waiting_for_user": [0, 0, 0, 0, 0, 0],
        "status_running": [0, 1, 1, 0, -1, 0],
        "status_failed": [0, 0, 0, 0, 0, 0],
        "status_unread": [0, 0, 0, 0, 0, 0],
    }[status_name][frame_index]
    sway_y = {
        "status_idle": [0, 0, 0, 0, 0, 0],
        "status_connecting": [0, 1, 1, 0, 0, 0],
        "status_waiting_for_user": [0, 0, 0, 1, 0, 0],
        "status_running": [0, 0, 1, 0, 0, 1],
        "status_failed": [0, 0, 0, 0, 0, 0],
        "status_unread": [0, 0, 0, 0, 0, 0],
    }[status_name][frame_index]

    body_mask = blank_mask()
    blit_body(body_mask, dx=sway_x, dy=sway_y)
    grid = shade_body(body_mask)

    if status_name == "status_idle":
        if frame_index in (2, 5):
            paint(grid, BLINK_LEFT_EYE, 7, 11, GLYPH)
            paint(grid, BLINK_RIGHT_EYE, 14, 12, GLYPH)
        else:
            paint(grid, ARROW, 6, 9, GLYPH)
            paint(grid, UNDERSCORE, 13, 12, GLYPH)
    elif status_name == "status_connecting":
        paint(grid, ARROW, 6 + sway_x, 9 + sway_y, GLYPH)
        for dot_index in range([1, 2, 3, 2, 1, 0][frame_index]):
            paint(grid, DOT, 13 + sway_x + (dot_index * 3), 12 + sway_y, GLYPH)
    elif status_name == "status_waiting_for_user":
        paint(grid, ARROW, 6 + sway_x, 9 + sway_y, GLYPH)
        paint(grid, UNDERSCORE, 13 + sway_x, 12 + sway_y, GLYPH)
        paint(grid, BUBBLE, 14, 1, ACCENT)
        paint(grid, BUBBLE_TAIL, 16, 1, ACCENT)
        for dot_index in range([1, 2, 3, 2, 1, 2][frame_index]):
            paint(grid, DOT, 15 + (dot_index * 2), 3, BODY_HIGHLIGHT)
    elif status_name == "status_running":
        paint(grid, ARROW, 6 + sway_x, 9 + sway_y, GLYPH)
        paint(grid, ARROW, 10 + sway_x, 9 + sway_y, GLYPH)
        bar_origin_x = [12, 13, 14, 13, 12, 11][frame_index]
        paint(grid, UNDERSCORE, bar_origin_x + sway_x, 12 + sway_y, GLYPH)
    elif status_name == "status_failed":
        paint(grid, ARROW, 6 + sway_x, 9 + sway_y, GLYPH)
        paint(grid, FAIL_EYE, 7, 9, ALERT)
        paint(grid, FAIL_EYE, 13, 9, ALERT)
        paint(grid, BURST, 16, 0, ALERT)
        paint(grid, EXCLAMATION, 18, 1, BODY_HIGHLIGHT)
    elif status_name == "status_unread":
        paint(grid, ARROW, 6 + sway_x, 9 + sway_y, GLYPH)
        paint(grid, UNDERSCORE, 13 + sway_x, 12 + sway_y, GLYPH)
        if frame_index == 2:
            paint(grid, BADGE_PULSE, 17, 1, BODY_HIGHLIGHT)
        paint(grid, BADGE, 17, 1, ACCENT)

    return grid


def write_xpm(grid: list[list[str]], path: Path) -> None:
    used_symbols = [
        symbol for symbol in PALETTE
        if symbol == TRANSPARENT or any(symbol in row for row in grid)
    ]

    lines = [
        "/* XPM */",
        "static char * sprite[] = {",
        f"\"{FRAME_GRID_SIZE} {FRAME_GRID_SIZE} {len(used_symbols)} 1\",",
    ]
    for symbol in used_symbols:
        color = PALETTE[symbol]
        if color is None:
            lines.append(f"\"{symbol} c None\",")
        else:
            lines.append(f"\"{symbol} c {color}\",")
    for row in grid:
        lines.append("\"" + "".join(row) + "\",")
    lines[-1] = lines[-1].rstrip(",")
    lines.append("};")
    path.write_text("\n".join(lines), encoding="utf-8")


def generate_sprite_sheet(status_name: str, output_path: Path, overrides_path: Path) -> None:
    override_path = overrides_path / f"{status_name}.png"
    if override_path.exists():
        identify = subprocess.run(
            ["magick", "identify", "-format", "%w %h", str(override_path)],
            check=True,
            capture_output=True,
            text=True,
        )
        width_text, height_text = identify.stdout.strip().split()
        width = int(width_text)
        height = int(height_text)
        trimmed_width = width - (width % 3)
        trimmed_height = height - (height % 3)
        if trimmed_width <= 0 or trimmed_height <= 0:
            raise ValueError(f"Override sprite sheet has invalid size: {override_path}")

        if trimmed_width == width and trimmed_height == height:
            shutil.copyfile(override_path, output_path)
            return

        horizontal_inset = (width - trimmed_width) // 2
        vertical_inset = (height - trimmed_height) // 2
        subprocess.run(
            [
                "magick",
                str(override_path),
                "-crop",
                f"{trimmed_width}x{trimmed_height}+{horizontal_inset}+{vertical_inset}",
                "+repage",
                str(output_path),
            ],
            check=True,
        )
        return

    with tempfile.TemporaryDirectory(prefix=f"{status_name}-") as temp_dir:
        temp_path = Path(temp_dir)
        frame_paths: list[str] = []

        for frame_index in range(FRAME_COUNT):
            xpm_path = temp_path / f"{status_name}-{frame_index}.xpm"
            png_path = temp_path / f"{status_name}-{frame_index}.png"
            write_xpm(frame(status_name, frame_index), xpm_path)
            subprocess.run(
                [
                    "magick",
                    str(xpm_path),
                    "-filter",
                    "point",
                    "-resize",
                    f"{FRAME_SCALE * 100}%",
                    str(png_path),
                ],
                check=True,
            )
            frame_paths.append(str(png_path))

        subprocess.run(
            ["magick", *frame_paths, "+append", str(output_path)],
            check=True,
        )


def ensure_clean_catalog(catalog_path: Path) -> None:
    if catalog_path.exists():
        shutil.rmtree(catalog_path)
    catalog_path.mkdir(parents=True, exist_ok=True)


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    overrides_path = Path(__file__).resolve().parent / OVERRIDES_DIRNAME
    catalog_path = repo_root / "Sources" / "CodexMate" / "Resources" / CATALOG_NAME

    ensure_clean_catalog(catalog_path)
    write_json(catalog_path / "Contents.json", CATALOG_CONTENTS)

    for status_name in SPRITE_NAMES:
        imageset_path = catalog_path / f"{status_name}.imageset"
        imageset_path.mkdir(parents=True, exist_ok=True)
        generate_sprite_sheet(status_name, imageset_path / SPRITE_SHEET_FILENAME, overrides_path)
        write_json(imageset_path / "Contents.json", IMAGESET_CONTENTS)


if __name__ == "__main__":
    main()
