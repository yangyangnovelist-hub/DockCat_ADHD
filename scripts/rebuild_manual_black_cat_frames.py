#!/usr/bin/env python3
"""
Rebuild the black cat's animation frames from manually separated source images.

This script only uses the hand-cut frames under:
~/Downloads/小猫动作手动处理

It rebuilds four sequences:
- sit   -> black/sit
- drag  -> black/drag
- eat   -> black/eat
- paw   -> black/paw
"""

from __future__ import annotations

from io import BytesIO
from pathlib import Path
from statistics import median
import re
import shutil
import subprocess
import tempfile
import time

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageOps


REPO_ROOT = Path(__file__).resolve().parents[1]
MANUAL_ROOT = Path.home() / "Downloads/小猫动作手动处理"
TARGET_ROOT = (
    REPO_ROOT
    / "ThirdParty/Upstreams/pet-therapy/Packages/Pets/Sources/Pets/Assets/pets/cat/black"
)
DEBUG_ROOT = Path.home() / "Downloads/.cat_debug_contacts/manual_black_rebuild"
BACKUP_ROOT = Path.home() / "Downloads/.cat_backups/manual_black_rebuild"

ACTION_MAP = {
    "sit": {
        "source_dir": "小猫 idle",
        "target_dir": "sit",
        "keep_mode": "largest",
    },
    "drag": {
        "source_dir": "小猫 drag",
        "target_dir": "drag",
        "keep_mode": "largest",
    },
    "eat": {
        "source_dir": "小猫 eat",
        "target_dir": "eat",
        "keep_mode": "cat_plus_nearby",
    },
    "paw": {
        "source_dir": "小猫 anxious",
        "target_dir": "paw",
        "keep_mode": "largest",
    },
}


def natural_key(path: Path) -> list[object]:
    parts = re.split(r"(\d+)", path.name)
    return [int(part) if part.isdigit() else part.lower() for part in parts]


def read_source_bytes(path: Path) -> bytes:
    if path.suffix.lower() not in {".heic", ".heif"}:
        return path.read_bytes()

    with tempfile.TemporaryDirectory(prefix="cat-heic-") as temp_dir:
        converted = Path(temp_dir) / f"{path.stem}.png"
        subprocess.run(
            ["sips", "-s", "format", "png", str(path), "--out", str(converted)],
            check=True,
            capture_output=True,
            text=True,
        )
        return converted.read_bytes()


def load_source_rgba(data: bytes) -> Image.Image:
    return Image.open(BytesIO(data)).convert("RGBA")


def components_for(image: Image.Image, threshold: int = 18) -> list[dict[str, int]]:
    alpha = np.array(image.getchannel("A"))
    _, binary = cv2.threshold(alpha, threshold, 255, cv2.THRESH_BINARY)
    component_count, _, stats, _ = cv2.connectedComponentsWithStats(binary, 8)

    components: list[dict[str, int]] = []
    for index in range(1, component_count):
        x, y, width, height, area = map(int, stats[index])
        if area <= 0:
            continue
        components.append(
            {
                "x": x,
                "y": y,
                "w": width,
                "h": height,
                "x2": x + width,
                "y2": y + height,
                "area": area,
            }
        )
    return components


def edge_connected_background_mask(
    image: Image.Image,
    source_key: str,
) -> np.ndarray:
    rgb = np.array(image.convert("RGB"))
    channels_min = rgb.min(axis=2)
    channels_max = rgb.max(axis=2)
    channels_mean = rgb.mean(axis=2)

    if source_key == "paw":
        candidate = channels_max <= 18
    else:
        candidate = ((channels_max - channels_min) <= 18) & (channels_mean >= 150)

    height, width = candidate.shape
    visited = np.zeros_like(candidate, dtype=bool)
    stack = []

    for x in range(width):
        stack.append((0, x))
        stack.append((height - 1, x))
    for y in range(height):
        stack.append((y, 0))
        stack.append((y, width - 1))

    while stack:
        y, x = stack.pop()
        if y < 0 or x < 0 or y >= height or x >= width:
            continue
        if visited[y, x] or not candidate[y, x]:
            continue

        visited[y, x] = True
        stack.extend(
            [
                (y - 1, x),
                (y + 1, x),
                (y, x - 1),
                (y, x + 1),
            ]
        )

    return visited


def keyed_source_frame(image: Image.Image, source_key: str) -> Image.Image:
    rgba = image.convert("RGBA")
    pixels = np.array(rgba)
    background = edge_connected_background_mask(image, source_key)
    pixels[background, 3] = 0
    return Image.fromarray(pixels, mode="RGBA")


def select_components(
    components: list[dict[str, int]], keep_mode: str
) -> list[dict[str, int]]:
    filtered = [component for component in components if component["area"] > 40]
    if not filtered:
        return []

    filtered.sort(key=lambda component: component["area"], reverse=True)
    largest = filtered[0]
    kept = [largest]

    if keep_mode == "cat_plus_nearby":
        area_floor = max(80, int(largest["area"] * 0.015))
        largest_center_x = largest["x"] + largest["w"] / 2
        largest_center_y = largest["y"] + largest["h"] / 2
        for component in filtered[1:]:
            if component["area"] < area_floor:
                continue

            component_center_x = component["x"] + component["w"] / 2
            component_center_y = component["y"] + component["h"] / 2
            horizontal_gap = max(
                0,
                max(largest["x"] - component["x2"], component["x"] - largest["x2"]),
            )
            vertical_gap = max(
                0,
                max(largest["y"] - component["y2"], component["y"] - largest["y2"]),
            )
            is_front_lower = (
                component_center_x <= largest_center_x + largest["w"] * 0.1
                and component_center_y >= largest_center_y - largest["h"] * 0.05
            )
            if horizontal_gap <= 120 and vertical_gap <= 100 and is_front_lower:
                kept.append(component)

    return kept


def crop_to_components(
    image: Image.Image, components: list[dict[str, int]], padding: int = 6
) -> Image.Image:
    x1 = max(0, min(component["x"] for component in components) - padding)
    y1 = max(0, min(component["y"] for component in components) - padding)
    x2 = min(image.width, max(component["x2"] for component in components) + padding)
    y2 = min(image.height, max(component["y2"] for component in components) + padding)
    return image.crop((x1, y1, x2, y2))


def keep_final_components(
    image: Image.Image,
    keep_mode: str,
) -> Image.Image:
    alpha = np.array(image.getchannel("A"))
    _, binary = cv2.threshold(alpha, 1, 255, cv2.THRESH_BINARY)
    component_count, labels, stats, _ = cv2.connectedComponentsWithStats(binary, 8)

    components = []
    for index in range(1, component_count):
        x, y, width, height, area = map(int, stats[index])
        if area <= 0:
            continue
        components.append(
            {
                "id": index,
                "x": x,
                "y": y,
                "w": width,
                "h": height,
                "x2": x + width,
                "y2": y + height,
                "area": area,
            }
        )

    kept = select_components(components, keep_mode)
    if not kept:
        return image

    kept_ids = {component["id"] for component in kept}
    mask = np.isin(labels, list(kept_ids))

    rgba = np.array(image)
    rgba[:, :, 3] = np.where(mask, rgba[:, :, 3], 0)
    return Image.fromarray(rgba, mode="RGBA")


def clean_source_frame(path: Path, source_key: str, keep_mode: str) -> Image.Image:
    image = keyed_source_frame(load_source_rgba(read_source_bytes(path)), source_key)
    components = select_components(components_for(image), keep_mode)
    if not components:
        return image
    return crop_to_components(image, components)


def target_stats(target_dir: Path) -> dict[str, float | tuple[int, int] | str]:
    stats_dir = target_dir
    backup_matches = sorted(
        backup_dir / target_dir.name
        for backup_dir in BACKUP_ROOT.iterdir()
        if backup_dir.is_dir() and (backup_dir / target_dir.name).is_dir()
    )
    if backup_matches:
        stats_dir = backup_matches[0]

    files = sorted(stats_dir.glob("*.png"), key=natural_key)
    if not files:
        raise FileNotFoundError(f"No PNG frames found in {stats_dir}")

    prefix = re.sub(r"-\d+$", "", files[0].stem)
    canvas_size = Image.open(files[0]).size

    bbox_entries = []
    for path in files:
        bbox = Image.open(path).convert("RGBA").getbbox()
        if not bbox:
            continue
        width = bbox[2] - bbox[0]
        height = bbox[3] - bbox[1]
        bbox_entries.append(
            {
                "bbox": bbox,
                "area": width * height,
                "width": width,
                "height": height,
                "center_x": (bbox[0] + bbox[2]) / 2,
                "bottom": bbox[3],
            }
        )

    median_area = median(entry["area"] for entry in bbox_entries)
    stable = [
        entry for entry in bbox_entries if median_area * 0.55 <= entry["area"] <= median_area * 1.6
    ]

    return {
        "prefix": prefix,
        "canvas": canvas_size,
        "target_width": median(entry["width"] for entry in stable),
        "target_height": median(entry["height"] for entry in stable),
        "target_center_x": median(entry["center_x"] for entry in stable),
        "target_bottom": median(entry["bottom"] for entry in stable),
    }


def align_frames(
    frames: list[Image.Image], stats: dict[str, float | tuple[int, int] | str]
) -> list[Image.Image]:
    canvas_width, canvas_height = stats["canvas"]  # type: ignore[index]
    raw_widths = [frame.width for frame in frames]
    raw_heights = [frame.height for frame in frames]

    scale = min(
        float(stats["target_width"]) / median(raw_widths),
        float(stats["target_height"]) / median(raw_heights),
    )
    scale *= 0.98

    aligned = []
    for frame in frames:
        width = max(1, round(frame.width * scale))
        height = max(1, round(frame.height * scale))
        if width > canvas_width - 8 or height > canvas_height - 8:
            shrink = min((canvas_width - 8) / width, (canvas_height - 8) / height)
            width = max(1, round(width * shrink))
            height = max(1, round(height * shrink))

        resized = frame.resize((width, height), Image.Resampling.LANCZOS)
        canvas = Image.new("RGBA", (canvas_width, canvas_height), (0, 0, 0, 0))
        x = round(float(stats["target_center_x"]) - width / 2)
        y = round(float(stats["target_bottom"]) - height)
        x = max(0, min(canvas_width - width, x))
        y = max(0, min(canvas_height - height, y))
        canvas.alpha_composite(resized, (x, y))
        aligned.append(canvas)

    return aligned


def remove_checker_artifacts(image: Image.Image) -> Image.Image:
    rgba = np.array(image)
    rgb = rgba[:, :, :3]
    alpha = rgba[:, :, 3]
    bright_neutral = (
        (alpha > 0)
        & (rgb.mean(axis=2) >= 138)
        & ((rgb.max(axis=2) - rgb.min(axis=2)) <= 48)
    )
    component_count, labels, stats, _ = cv2.connectedComponentsWithStats(
        bright_neutral.astype(np.uint8) * 255,
        8,
    )
    for index in range(1, component_count):
        x, y, width, height, area = map(int, stats[index])
        if area > 40:
            continue
        rgba[labels == index, 3] = 0
    return Image.fromarray(rgba, mode="RGBA")


def render_contact_sheet(frames: list[Image.Image], output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    cell_width = 240
    cell_height = 270
    columns = 3
    rows = (len(frames) + columns - 1) // columns

    sheet = Image.new("RGB", (columns * cell_width, rows * cell_height), (246, 246, 246))
    for index, frame in enumerate(frames):
        thumb = ImageOps.contain(frame, (220, 220))
        canvas = Image.new("RGBA", (cell_width, cell_height), (255, 255, 255, 255))
        x = (cell_width - thumb.width) // 2
        canvas.alpha_composite(thumb, (x, 10))
        ImageDraw.Draw(canvas).text((10, 235), f"frame {index + 1}", fill="black")
        sheet.paste(canvas.convert("RGB"), ((index % columns) * cell_width, (index // columns) * cell_height))

    sheet.save(output_path, quality=92)


def backup_target_dir(target_dir: Path) -> None:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup_dir = BACKUP_ROOT / stamp / target_dir.name
    backup_dir.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(target_dir, backup_dir)


def write_frames(
    frames: list[Image.Image],
    target_dir: Path,
    prefix: str,
) -> None:
    for path in target_dir.glob("*.png"):
        path.unlink()

    for index, frame in enumerate(frames, start=1):
        output_path = target_dir / f"{prefix}-{index}.png"
        frame.save(output_path, optimize=True)


def source_files(source_dir: Path) -> list[Path]:
    files = [path for path in source_dir.iterdir() if path.is_file() and not path.name.startswith(".")]
    if not files:
        raise FileNotFoundError(f"No frames found in {source_dir}")
    return sorted(files, key=natural_key)


def rebuild_action(source_key: str) -> None:
    config = ACTION_MAP[source_key]
    source_dir = MANUAL_ROOT / config["source_dir"]
    target_dir = TARGET_ROOT / config["target_dir"]
    stats = target_stats(target_dir)

    cleaned_frames = [
        clean_source_frame(path, source_key, config["keep_mode"])
        for path in source_files(source_dir)
    ]
    if source_key == "drag" and len(cleaned_frames) >= 6:
        cleaned_frames[4] = cleaned_frames[5].copy()
    if source_key == "paw" and len(cleaned_frames) >= 9:
        cleaned_frames[8] = cleaned_frames[2].copy()
    aligned_frames = align_frames(cleaned_frames, stats)
    aligned_frames = [remove_checker_artifacts(frame) for frame in aligned_frames]
    aligned_frames = [
        keep_final_components(frame, config["keep_mode"])
        for frame in aligned_frames
    ]

    backup_target_dir(target_dir)
    write_frames(aligned_frames, target_dir, stats["prefix"])  # type: ignore[arg-type]
    render_contact_sheet(aligned_frames, DEBUG_ROOT / f"{source_key}.jpg")


def main() -> None:
    DEBUG_ROOT.mkdir(parents=True, exist_ok=True)
    for source_key in ACTION_MAP:
        rebuild_action(source_key)
    print("Rebuilt manual frame sets:")
    for source_key, config in ACTION_MAP.items():
        print(f"- {source_key} -> {TARGET_ROOT / config['target_dir']}")
    print(f"Contact sheets: {DEBUG_ROOT}")
    print(f"Backups: {BACKUP_ROOT}")


if __name__ == "__main__":
    main()
