#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import math
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Overlay acceleration graph from a CSV onto a video with a moving playhead. "
            "Offset is applied so CSV and video timelines can be aligned."
        )
    )
    parser.add_argument(
        "--recording",
        type=str,
        default=None,
        help=(
            "Recording stem (for example: recording_20260329_172110). "
            "When set, script auto-finds CSV/VIDEO/SIDECARS by stem."
        ),
    )
    parser.add_argument("--csv", type=Path, default=None, help="Path to sensor CSV.")
    parser.add_argument("--video", type=Path, default=None, help="Path to source video.")
    parser.add_argument(
        "--search-dir",
        type=Path,
        action="append",
        default=[],
        help=(
            "Directory to search for files when using --recording. "
            "Can be passed multiple times. Default search order: data2/, data/, ."
        ),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output video path. Default: <video_stem>-accel-overlay.mp4",
    )
    parser.add_argument(
        "--offset-sec",
        type=float,
        default=None,
        help=(
            "Manual offset in seconds from video start to CSV start. "
            "Positive means CSV starts after video."
        ),
    )
    parser.add_argument(
        "--video-start-unix",
        type=float,
        default=None,
        help=(
            "Manual video start timestamp (Unix epoch seconds). "
            "When set, offset is computed from CSV first timestamp minus this value."
        ),
    )
    parser.add_argument(
        "--disable-sidecar-sync",
        action="store_true",
        help="Ignore <video_stem>.phone.json and <video_stem>.watch.json even if present.",
    )
    parser.add_argument(
        "--extra-offset-sec",
        type=float,
        default=0.0,
        help="Extra offset to add after auto/manual offset (seconds).",
    )
    parser.add_argument(
        "--graph-height-frac",
        type=float,
        default=0.24,
        help="Graph height as fraction of video height.",
    )
    parser.add_argument(
        "--graph-width-frac",
        type=float,
        default=0.92,
        help="Graph width as fraction of video width.",
    )
    parser.add_argument("--ax-color", type=str, default="#F97316", help="AX line color.")
    parser.add_argument("--ay-color", type=str, default="#f59e0b", help="AY line color.")
    parser.add_argument("--az-color", type=str, default="#facc15", help="AZ line color.")
    parser.add_argument("--indicator-color", type=str, default="0xFF3B30", help="Playhead color for ffmpeg.")
    parser.add_argument("--indicator-width-px", type=int, default=4, help="Playhead width in pixels.")
    parser.add_argument("--line-width", type=float, default=1.8, help="Acceleration line width.")
    parser.add_argument("--y-limit-g", type=float, default=16.0, help="Fixed Y axis limit in g (uses [-limit, +limit]).")
    parser.add_argument("--past-sec", type=float, default=1.5, help="Seconds of history shown left of center line.")
    parser.add_argument("--future-sec", type=float, default=1.5, help="Seconds of future shown right of center line.")
    parser.add_argument(
        "recording_stem",
        nargs="?",
        default=None,
        help="Optional positional recording stem (same behavior as --recording).",
    )
    return parser.parse_args()


def run(cmd: list[str]) -> str:
    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def parse_rate(rate_text: str | None) -> float:
    if not rate_text:
        return 0.0
    if "/" in rate_text:
        num_text, den_text = rate_text.split("/", 1)
        num = float(num_text)
        den = float(den_text)
        if den == 0.0:
            return 0.0
        return num / den
    return float(rate_text)


def load_sidecar_json(path: Path) -> dict[str, object] | None:
    if not path.exists():
        return None
    payload = json.loads(path.read_text())
    if not isinstance(payload, dict):
        raise ValueError(f"Sidecar JSON must be an object: {path}")
    return payload


def get_float_field(payload: dict[str, object] | None, key: str) -> float | None:
    if payload is None:
        return None
    value = payload.get(key)
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def ffprobe_video_info(video_path: Path) -> dict[str, float | int | str | None]:
    output = run(
        [
            "ffprobe",
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_streams",
            "-show_format",
            str(video_path),
        ]
    )
    payload = json.loads(output)
    streams = payload.get("streams", [])
    video_stream = next((s for s in streams if s.get("codec_type") == "video"), None)
    if video_stream is None:
        raise ValueError(f"No video stream found in {video_path}")

    duration = payload.get("format", {}).get("duration")
    if duration is None:
        duration = video_stream.get("duration")
    if duration is None:
        raise ValueError(f"Could not determine duration for {video_path}")

    format_tags = payload.get("format", {}).get("tags", {})
    stream_tags = video_stream.get("tags", {})
    creation_time = format_tags.get("creation_time") or stream_tags.get("creation_time")

    rotation_deg = 0
    for side_data in video_stream.get("side_data_list", []):
        if "rotation" in side_data:
            rotation_deg = int(round(float(side_data["rotation"])))
            break
    if rotation_deg == 0 and "rotate" in stream_tags:
        rotation_deg = int(round(float(stream_tags["rotate"])))

    width = int(video_stream["width"])
    height = int(video_stream["height"])
    fps = parse_rate(video_stream.get("avg_frame_rate") or video_stream.get("r_frame_rate"))
    if abs(rotation_deg) % 180 == 90:
        display_width = height
        display_height = width
    else:
        display_width = width
        display_height = height

    return {
        "width": width,
        "height": height,
        "display_width": display_width,
        "display_height": display_height,
        "rotation_deg": rotation_deg,
        "fps": fps,
        "duration_sec": float(duration),
        "creation_time": creation_time,
    }


def parse_creation_time_to_epoch(creation_time: str | None) -> float | None:
    if not creation_time:
        return None
    normalized = creation_time.replace("Z", "+00:00")
    dt = datetime.fromisoformat(normalized)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def load_csv(csv_path: Path) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    required = {"timestamp", "ax", "ay", "az"}
    missing = required.difference(df.columns)
    if missing:
        raise ValueError(f"CSV missing required columns: {sorted(missing)}")
    return df


def dedupe_paths(paths: list[Path]) -> list[Path]:
    seen: set[Path] = set()
    ordered: list[Path] = []
    for path in paths:
        resolved = path.resolve()
        if resolved not in seen:
            seen.add(resolved)
            ordered.append(resolved)
    return ordered


def resolve_input_paths(args: argparse.Namespace) -> tuple[Path, Path]:
    recording_token = args.recording or args.recording_stem

    if recording_token:
        if args.csv is not None or args.video is not None:
            raise SystemExit("Use recording stem mode OR --csv/--video mode, not both.")

        recording_path = Path(recording_token)
        stem = recording_path.stem if recording_path.suffix else recording_path.name
        root_stem_path = recording_path.with_suffix("")

        search_dirs: list[Path] = []
        if root_stem_path.parent != Path("."):
            search_dirs.append(root_stem_path.parent)
        search_dirs.extend(args.search_dir)
        if not search_dirs:
            search_dirs = [Path("data2"), Path("data"), Path(".")]
        search_dirs = dedupe_paths(search_dirs)

        video_extensions = [".mov", ".mp4", ".m4v", ".avi", ".mkv"]
        attempted: list[str] = []
        for directory in search_dirs:
            csv_candidate = (directory / stem).with_suffix(".csv")
            if not csv_candidate.exists():
                attempted.append(str(csv_candidate))
                continue

            for ext in video_extensions:
                video_candidate = (directory / stem).with_suffix(ext)
                if video_candidate.exists():
                    return csv_candidate.resolve(), video_candidate.resolve()
                attempted.append(str(video_candidate))

        attempted_text = "\n".join(f"  - {path}" for path in attempted[:20])
        raise FileNotFoundError(
            f"Could not auto-resolve recording '{stem}'. Tried paths such as:\n{attempted_text}"
        )

    if args.csv is None or args.video is None:
        raise SystemExit("Provide a recording stem (--recording or positional) OR both --csv and --video.")
    return args.csv.resolve(), args.video.resolve()


def choose_offset_sec(
    csv_df: pd.DataFrame,
    video_info: dict[str, float | int | str | None],
    args: argparse.Namespace,
    phone_meta: dict[str, object] | None,
    watch_meta: dict[str, object] | None,
) -> tuple[float, str, dict[str, float | str | None]]:
    csv_first_epoch = float(csv_df["timestamp"].iloc[0])
    video_start_epoch: float | None = None
    watch_to_phone_clock_offset: float | None = None

    if args.offset_sec is not None:
        offset = float(args.offset_sec)
        source = "manual"
    else:
        if args.video_start_unix is not None:
            video_start_epoch = float(args.video_start_unix)
            source = "manual-video-start-unix"
        else:
            phone_video_start = get_float_field(phone_meta, "actualVideoStartUnix")
            phone_planned_start = get_float_field(phone_meta, "plannedStartUnix")
            watch_actual_start = get_float_field(watch_meta, "actualWatchStartUnix")
            watch_planned_start = get_float_field(watch_meta, "plannedStartUnix")

            if (
                phone_video_start is not None
                and phone_planned_start is not None
                and watch_actual_start is not None
                and watch_planned_start is not None
            ):
                if abs(phone_planned_start - watch_planned_start) > 0.050:
                    raise ValueError(
                        "Phone/watch sidecars disagree about plannedStartUnix: "
                        f"phone={phone_planned_start:.6f}, watch={watch_planned_start:.6f}"
                    )
                video_start_epoch = phone_video_start
                watch_to_phone_clock_offset = phone_planned_start - watch_actual_start
                source = "auto-from-phone+watch-json(plannedStartUnix-actualWatchStartUnix,actualVideoStartUnix)"
            elif phone_video_start is not None:
                video_start_epoch = phone_video_start
                source = "auto-from-phone-json(actualVideoStartUnix)"
            else:
                video_start_epoch = parse_creation_time_to_epoch(video_info.get("creation_time"))  # type: ignore[arg-type]
                if video_start_epoch is None:
                    source = "auto-fallback-zero (missing phone json + missing creation_time)"
                else:
                    source = "auto-from-creation-time"

        if video_start_epoch is None:
            offset = 0.0
        else:
            offset = csv_first_epoch - video_start_epoch
            if watch_to_phone_clock_offset is not None:
                offset += watch_to_phone_clock_offset

    total = offset + float(args.extra_offset_sec)
    details: dict[str, float | str | None] = {
        "csv_first_epoch": csv_first_epoch,
        "video_start_epoch": video_start_epoch,
        "video_start_source": source,
        "watch_to_phone_clock_offset": watch_to_phone_clock_offset,
        "phone_actual_video_start": get_float_field(phone_meta, "actualVideoStartUnix"),
        "phone_sync_flash": get_float_field(phone_meta, "syncFlashUnix"),
        "phone_planned_start": get_float_field(phone_meta, "plannedStartUnix"),
        "watch_actual_start": get_float_field(watch_meta, "actualWatchStartUnix"),
        "watch_planned_start": get_float_field(watch_meta, "plannedStartUnix"),
    }
    return total, source, details


def make_graph_image(
    csv_df: pd.DataFrame,
    graph_path: Path,
    video_duration_sec: float,
    graph_image_w_px: int,
    graph_h_px: int,
    offset_sec: float,
    ax_color: str,
    ay_color: str,
    az_color: str,
    y_limit_g: float,
    line_width: float,
) -> None:
    timestamps = csv_df["timestamp"].to_numpy(dtype=np.float64)
    t_local = timestamps - timestamps[0]
    t_video = t_local + offset_sec

    ax_values = csv_df["ax"].to_numpy(dtype=np.float64)
    ay_values = csv_df["ay"].to_numpy(dtype=np.float64)
    az_values = csv_df["az"].to_numpy(dtype=np.float64)
    y_limit = max(float(y_limit_g), 0.25)
    y_min = -y_limit
    y_max = y_limit

    dpi = 120
    fig_w = graph_image_w_px / dpi
    fig_h = graph_h_px / dpi
    fig, ax = plt.subplots(figsize=(fig_w, fig_h), dpi=dpi)
    fig.patch.set_alpha(0.0)
    ax.set_facecolor((0.0, 0.0, 0.0, 0.0))
    ax.plot(t_video, ax_values, color=ax_color, linewidth=line_width, alpha=0.98, label="ax")
    ax.plot(t_video, ay_values, color=ay_color, linewidth=line_width, alpha=0.98, label="ay")
    ax.plot(t_video, az_values, color=az_color, linewidth=line_width, alpha=0.98, label="az")
    ax.axhline(0.0, color=(1.0, 1.0, 1.0, 0.35), linewidth=0.9)
    ax.set_xlim(0.0, max(video_duration_sec, 1e-6))
    ax.set_ylim(y_min, y_max)
    ax.grid(True, axis="y", color="white", alpha=0.25, linewidth=0.6)
    for spine in ax.spines.values():
        spine.set_color((1.0, 1.0, 1.0, 0.65))
    ax.tick_params(colors="white", labelsize=7)
    ax.set_xlabel("video time (s)", color="white", fontsize=8)
    ax.set_ylabel("g", color="white", fontsize=8)
    legend = ax.legend(
        loc="upper right",
        framealpha=0.15,
        facecolor=(0.0, 0.0, 0.0, 0.2),
        edgecolor=(1.0, 1.0, 1.0, 0.2),
        ncol=3,
        fontsize=8,
        handlelength=1.6,
        handletextpad=0.4,
        borderpad=0.3,
    )
    for text in legend.get_texts():
        text.set_color("white")
    fig.tight_layout(pad=0.15)
    fig.savefig(graph_path, transparent=True)
    plt.close(fig)


def overlay_graph_on_video(
    video_path: Path,
    graph_path: Path,
    output_path: Path,
    video_info: dict[str, float | int | str | None],
    graph_x: int,
    graph_y: int,
    graph_w: int,
    graph_h: int,
    graph_px_per_sec: float,
    indicator_color: str,
    indicator_width_px: int,
    rotation_deg: int,
) -> None:
    duration = float(video_info["duration_sec"])  # type: ignore[arg-type]
    indicator_width_px = max(int(indicator_width_px), 2)
    center_x = graph_x + (graph_w // 2) - (indicator_width_px // 2)
    graph_overlay_x_expr = f"{graph_x + (graph_w / 2.0):.3f}-(t*{graph_px_per_sec:.6f})"

    bg_x = max(graph_x - 8, 0)
    bg_y = max(graph_y - 6, 0)
    bg_w = graph_w + 16
    bg_h = graph_h + 12

    rotation_expr = rotation_filter(rotation_deg)
    if rotation_expr is None:
        main_video_chain = "[0:v]"
        rotate_stage = ""
    else:
        rotate_stage = f"[0:v]{rotation_expr}[rot];"
        main_video_chain = "[rot]"

    filter_complex = (
        f"{rotate_stage}"
        f"{main_video_chain}drawbox=x={bg_x}:y={bg_y}:w={bg_w}:h={bg_h}:color=black@0.35:t=fill[bg];"
        f"[1:v]format=rgba[graph];"
        f"[bg][graph]overlay=x='{graph_overlay_x_expr}':y={graph_y}:format=auto:shortest=1:eof_action=endall:eval=frame[tmp];"
        f"[tmp]drawbox=x={center_x}:y={graph_y}:w={indicator_width_px}:h={graph_h}:color={indicator_color}@1.0:t=fill[vout]"
    )

    cmd = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "warning",
        "-noautorotate",
        "-display_rotation:v:0",
        "0",
        "-i",
        str(video_path),
        "-loop",
        "1",
        "-i",
        str(graph_path),
        "-filter_complex",
        filter_complex,
        "-map",
        "[vout]",
        "-map",
        "0:a?",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "18",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "copy",
        "-t",
        f"{duration:.6f}",
        "-shortest",
        str(output_path),
    ]
    subprocess.run(cmd, check=True)


def ensure_positive_int(value: float, minimum: int) -> int:
    return max(int(math.floor(value)), minimum)


def rotation_filter(rotation_deg: int) -> str | None:
    normalized = rotation_deg % 360
    if normalized == 0:
        return None
    if normalized == 90:
        return "transpose=cclock"
    if normalized == 180:
        return "hflip,vflip"
    if normalized == 270:
        return "transpose=clock"
    radians = math.radians(rotation_deg)
    return f"rotate={radians:.10f}:ow=rotw(iw):oh=roth(ih)"


def main() -> None:
    args = parse_args()
    csv_path, video_path = resolve_input_paths(args)
    output_path = (
        args.output.resolve()
        if args.output is not None
        else video_path.with_name(f"{video_path.stem}-accel-overlay.mp4")
    )
    print(f"Resolved files: csv={csv_path.name}, video={video_path.name}")

    csv_df = load_csv(csv_path)
    video_info = ffprobe_video_info(video_path)
    phone_sidecar_path = video_path.with_suffix(".phone.json")
    watch_sidecar_path = video_path.with_suffix(".watch.json")
    if args.disable_sidecar_sync:
        phone_meta = None
        watch_meta = None
    else:
        phone_meta = load_sidecar_json(phone_sidecar_path)
        watch_meta = load_sidecar_json(watch_sidecar_path)

    video_w = int(video_info["display_width"])  # type: ignore[arg-type]
    video_h = int(video_info["display_height"])  # type: ignore[arg-type]
    video_duration = float(video_info["duration_sec"])  # type: ignore[arg-type]
    margin = ensure_positive_int(min(video_w, video_h) * 0.03, 8)
    graph_w = ensure_positive_int(video_w * float(args.graph_width_frac), 160)
    graph_h = ensure_positive_int(video_h * float(args.graph_height_frac), 80)
    graph_x = max((video_w - graph_w) // 2, 0)
    graph_y = max(video_h - graph_h - margin, 0)
    past_sec = max(float(args.past_sec), 0.0)
    future_sec = max(float(args.future_sec), 0.0)
    window_sec = max(past_sec + future_sec, 1e-6)
    graph_px_per_sec = graph_w / window_sec
    graph_image_w = ensure_positive_int(video_duration * graph_px_per_sec, graph_w)

    offset_sec, offset_source, sync_details = choose_offset_sec(
        csv_df=csv_df,
        video_info=video_info,
        args=args,
        phone_meta=phone_meta,
        watch_meta=watch_meta,
    )
    print(
        "Video geometry: "
        f"encoded={int(video_info['width'])}x{int(video_info['height'])}, "
        f"display={video_w}x{video_h}, "
        f"rotation={int(video_info['rotation_deg'])}deg, "
        f"fps={float(video_info['fps']):.3f}"
    )
    print(f"Video duration: {video_duration:.3f}s")
    print(
        f"Graph window: past={past_sec:.3f}s, future={future_sec:.3f}s, "
        f"fixed_y=[{-float(args.y_limit_g):.1f}, +{float(args.y_limit_g):.1f}] g"
    )
    print(
        "Sidecars: "
        f"phone_json={'yes' if phone_meta is not None else 'no'} "
        f"({phone_sidecar_path.name}), "
        f"watch_json={'yes' if watch_meta is not None else 'no'} "
        f"({watch_sidecar_path.name})"
    )
    if sync_details["video_start_epoch"] is not None:
        print(
            "Sync timestamps: "
            f"video_start={float(sync_details['video_start_epoch']):.6f}, "
            f"csv_first={float(sync_details['csv_first_epoch']):.6f}"
        )
    else:
        print(f"Sync timestamps: csv_first={float(sync_details['csv_first_epoch']):.6f} (video start unavailable)")
    if sync_details["watch_actual_start"] is not None:
        csv_minus_watch = float(sync_details["csv_first_epoch"]) - float(sync_details["watch_actual_start"])
        print(f"Watch check: csv_first - actualWatchStartUnix = {csv_minus_watch:+.6f}s")
    if sync_details["watch_to_phone_clock_offset"] is not None:
        print(
            "Clock correction: "
            f"watch_to_phone_offset={float(sync_details['watch_to_phone_clock_offset']):+.6f}s"
        )
    print(f"Offset applied: {offset_sec:+.6f}s ({offset_source}, extra={args.extra_offset_sec:+.6f}s)")

    with tempfile.TemporaryDirectory(prefix="accel_overlay_") as tmp_dir:
        graph_path = Path(tmp_dir) / "acceleration_graph.png"
        make_graph_image(
            csv_df=csv_df,
            graph_path=graph_path,
            video_duration_sec=video_duration,
            graph_image_w_px=graph_image_w,
            graph_h_px=graph_h,
            offset_sec=offset_sec,
            ax_color=args.ax_color,
            ay_color=args.ay_color,
            az_color=args.az_color,
            y_limit_g=float(args.y_limit_g),
            line_width=float(args.line_width),
        )
        overlay_graph_on_video(
            video_path=video_path,
            graph_path=graph_path,
            output_path=output_path,
            video_info=video_info,
            graph_x=graph_x,
            graph_y=graph_y,
            graph_w=graph_w,
            graph_h=graph_h,
            graph_px_per_sec=graph_px_per_sec,
            indicator_color=args.indicator_color,
            indicator_width_px=int(args.indicator_width_px),
            rotation_deg=int(video_info["rotation_deg"]),  # type: ignore[arg-type]
        )

    print(f"Wrote: {output_path}")


if __name__ == "__main__":
    main()
