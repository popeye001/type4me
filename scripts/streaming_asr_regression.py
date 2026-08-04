#!/usr/bin/env python3
"""Regression gate for LocalVoice streaming against fresh-cache batch ASR.

The batch endpoint and WebSocket stream use the same local Qwen model. Batch
output is the coverage reference; streaming is allowed to differ slightly in
punctuation and wording, but must not lose, duplicate, or randomly change large
parts of the recording.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import statistics
import sys
import time
import wave
from dataclasses import asdict, dataclass
from pathlib import Path

import httpx
import websockets


PRESENTATION_RE = re.compile(r"[\s，。！？、；：,.!?;:'\"“”‘’（）()《》【】\[\]—…-]+")


@dataclass
class RunResult:
    run: int
    text: str
    normalized_text: str
    cer: float
    length_ratio: float
    deletion_rate: float
    largest_reference_gap: int
    elapsed_seconds: float
    audio_seconds: float
    repeated_appends: int
    full_retry: bool
    full_recovered: bool
    processing_ms: int
    coverage_complete: bool
    unresolved_audio_seconds: float
    final_source: str
    raw_passed: bool
    shadow_retry: bool
    shadow_length_ratio: float | None
    shadow_distance: float | None
    recovered_by_full_audio: bool
    passed: bool
    failures: list[str]


@dataclass
class CaseResult:
    file: str
    audio_seconds: float
    reference: str
    normalized_reference: str
    batch_elapsed_seconds: float
    runs: list[RunResult]
    max_pairwise_cer: float
    passed: bool


def normalize(text: str) -> str:
    return PRESENTATION_RE.sub("", text or "").lower()


def edit_distance(left: str, right: str) -> int:
    if len(left) < len(right):
        left, right = right, left
    previous = list(range(len(right) + 1))
    for row, left_char in enumerate(left, 1):
        current = [row]
        for column, right_char in enumerate(right, 1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[column] + 1,
                    previous[column - 1] + (left_char != right_char),
                )
            )
        previous = current
    return previous[-1]


def cer(reference: str, candidate: str) -> float:
    if not reference:
        return 0.0 if not candidate else 1.0
    return edit_distance(reference, candidate) / len(reference)


def deletion_diagnostics(reference: str, candidate: str) -> tuple[float, int]:
    """Measure coverage loss separately from ordinary ASR substitutions."""
    from difflib import SequenceMatcher

    matcher = SequenceMatcher(None, reference, candidate, autojunk=False)
    deleted = 0
    largest_gap = 0
    for tag, left_start, left_end, right_start, right_end in matcher.get_opcodes():
        if tag == "delete":
            gap = left_end - left_start
        elif tag == "replace":
            gap = max(0, (left_end - left_start) - (right_end - right_start))
        else:
            gap = 0
        deleted += gap
        largest_gap = max(largest_gap, gap)
    rate = deleted / len(reference) if reference else 0.0
    return rate, largest_gap


def shadow_normalize(text: str) -> str:
    return normalize(text).translate(str.maketrans("0123456789", "零一二三四五六七八九"))


def shadow_decision(primary: str, shadow: str) -> tuple[bool, float, float]:
    """Mirror ASRShadowCrossCheck.swift exactly for corpus-level gating."""
    primary_text = shadow_normalize(primary)
    shadow_text = shadow_normalize(shadow)
    ratio = len(primary_text) / len(shadow_text) if shadow_text else 1.0
    distance = (
        edit_distance(primary_text, shadow_text) / max(len(primary_text), len(shadow_text), 1)
    )
    if len(shadow_text) < 4:
        return False, ratio, distance
    minimum_ratio, maximum_ratio = (0.70, 1.40) if len(shadow_text) < 8 else (0.92, 1.12)
    should_retry = (
        ratio < minimum_ratio
        or ratio > maximum_ratio
        or (max(len(primary_text), len(shadow_text)) >= 20 and distance > 0.32)
    )
    return should_retry, ratio, distance


def read_wav(path: Path) -> tuple[bytes, float]:
    with wave.open(str(path), "rb") as audio:
        properties = (
            audio.getnchannels(),
            audio.getsampwidth(),
            audio.getframerate(),
        )
        if properties != (1, 2, 16_000):
            raise ValueError(f"unsupported WAV format {properties}: {path}")
        frames = audio.readframes(audio.getnframes())
        return frames, len(frames) / 32_000.0


async def batch_transcribe(
    client: httpx.AsyncClient,
    http_url: str,
    api_key: str,
    path: Path,
    model: str,
) -> tuple[str, float]:
    started = time.monotonic()
    response = await client.post(
        http_url,
        headers={"Authorization": f"Bearer {api_key}"},
        files={"file": (path.name, path.read_bytes(), "audio/wav")},
        data={"model": model, "response_format": "json"},
        timeout=180,
    )
    response.raise_for_status()
    return str(response.json().get("text") or "").strip(), time.monotonic() - started


async def stream_transcribe(
    websocket_url: str,
    api_key: str,
    pcm: bytes,
    pace: float,
    args: argparse.Namespace,
) -> tuple[dict, float]:
    started = time.monotonic()
    async with websockets.connect(
        websocket_url,
        additional_headers={"Authorization": f"Bearer {api_key}"},
        max_size=None,
        open_timeout=15,
        close_timeout=15,
        # Accelerated replay can queue minutes of audio while the server still
        # performs every checkpoint serially. That is intentional stress, not
        # a transport-idle failure; the Type4Me client does not use this Python
        # library's 20-second automatic ping timeout.
        ping_interval=None,
    ) as socket:
        await socket.send(json.dumps({
            "type": "start",
            "context": "",
            "chunk_size_sec": args.chunk_size_sec,
            "max_context_sec": args.max_context_sec,
            "finalization_mode": "accuracy",
            "endpointing_mode": "fixed",
            "verification_stride_sec": args.verification_stride_sec,
            "verification_overlap_sec": args.verification_overlap_sec,
        }))
        ready = json.loads(await socket.recv())
        if ready.get("type") != "ready":
            raise RuntimeError(f"stream did not become ready: {ready}")

        async def receive_final() -> dict:
            while True:
                result = json.loads(await socket.recv())
                if result.get("type") == "error":
                    raise RuntimeError(result.get("message") or "stream error")
                if result.get("type") == "final":
                    return result

        # Type4Me sends microphone frames and receives partials concurrently.
        # A send-all-then-receive test fills the WebSocket inbound queue after
        # roughly 20 partials and creates a fake 60-80 second disconnect.
        receiver = asyncio.create_task(receive_final())
        try:
            frame_bytes = 6_400  # the app's 200ms PCM chunk
            for offset in range(0, len(pcm), frame_bytes):
                await socket.send(pcm[offset : offset + frame_bytes])
                if pace > 0:
                    await asyncio.sleep(pace)
            await socket.send(json.dumps({"type": "finish"}))
            result = await receiver
            return result, time.monotonic() - started
        finally:
            if not receiver.done():
                receiver.cancel()


def evaluate_run(
    run_number: int,
    reference: str,
    response: dict,
    elapsed: float,
    max_cer: float,
    min_length_ratio: float,
    shadow_text: str | None,
    max_deletion_rate: float,
    max_reference_gap: int,
    max_finalize_seconds: float,
) -> RunResult:
    candidate = str(response.get("text") or "").strip()
    normalized_reference = normalize(reference)
    normalized_candidate = normalize(candidate)
    error_rate = cer(normalized_reference, normalized_candidate)
    length_ratio = (
        len(normalized_candidate) / len(normalized_reference)
        if normalized_reference else 1.0
    )
    deletion_rate, largest_reference_gap = deletion_diagnostics(
        normalized_reference, normalized_candidate
    )
    verification = response.get("verification") or {}
    coverage_complete = bool(response.get("coverage_complete"))
    unresolved_audio_seconds = float(
        verification.get("unresolved_audio_seconds") or 0
    )
    finalization_seconds = float(response.get("processing_ms") or 0) / 1000.0
    failures: list[str] = []
    if not normalized_candidate:
        failures.append("empty final transcript")
    if error_rate > max_cer:
        failures.append(f"CER {error_rate:.3f} > {max_cer:.3f}")
    if length_ratio < min_length_ratio:
        failures.append(
            f"length ratio {length_ratio:.3f} < {min_length_ratio:.3f}"
        )
    if deletion_rate > max_deletion_rate:
        failures.append(
            f"deletion rate {deletion_rate:.3f} > {max_deletion_rate:.3f}"
        )
    if largest_reference_gap > max_reference_gap:
        failures.append(
            f"largest reference gap {largest_reference_gap} > {max_reference_gap}"
        )
    if not coverage_complete:
        failures.append("server did not verify complete audio coverage")
    if unresolved_audio_seconds > 0.01:
        failures.append(
            f"unresolved audio {unresolved_audio_seconds:.3f}s > 0.01s"
        )
    if finalization_seconds > max_finalize_seconds:
        failures.append(
            f"finalization {finalization_seconds:.3f}s > {max_finalize_seconds:.3f}s"
        )
    raw_passed = not failures
    shadow_retry = False
    shadow_length_ratio = None
    shadow_distance = None
    if shadow_text:
        shadow_retry, shadow_length_ratio, shadow_distance = shadow_decision(
            candidate, shadow_text
        )
    # Apple remains a useful independent diagnostic, but it must never turn a
    # broken server result into a passing regression. The returned WebSocket
    # final itself has to prove complete coverage.
    recovered = False
    final_failures = failures
    return RunResult(
        run=run_number,
        text=candidate,
        normalized_text=normalized_candidate,
        cer=error_rate,
        length_ratio=length_ratio,
        deletion_rate=deletion_rate,
        largest_reference_gap=largest_reference_gap,
        elapsed_seconds=elapsed,
        audio_seconds=float(response.get("audio_seconds") or 0),
        repeated_appends=int(response.get("repeated_appends") or 0),
        full_retry=bool(response.get("full_retry")),
        full_recovered=bool(response.get("full_recovered")),
        processing_ms=int(response.get("processing_ms") or 0),
        coverage_complete=coverage_complete,
        unresolved_audio_seconds=unresolved_audio_seconds,
        final_source=str(response.get("final_source") or "unknown"),
        raw_passed=raw_passed,
        shadow_retry=shadow_retry,
        shadow_length_ratio=shadow_length_ratio,
        shadow_distance=shadow_distance,
        recovered_by_full_audio=recovered,
        passed=not final_failures,
        failures=final_failures,
    )


async def run_case(
    path: Path,
    client: httpx.AsyncClient,
    args: argparse.Namespace,
    api_key: str,
    shadow_text: str | None,
) -> CaseResult:
    pcm, audio_seconds = read_wav(path)
    reference, batch_elapsed = await batch_transcribe(
        client, args.http_url, api_key, path, args.model
    )
    if not normalize(reference):
        raise RuntimeError(f"batch reference is empty: {path.name}")

    runs: list[RunResult] = []
    for run_number in range(1, args.repeat + 1):
        response, elapsed = await stream_transcribe(
            args.websocket_url, api_key, pcm, args.pace, args
        )
        runs.append(evaluate_run(
            run_number,
            reference,
            response,
            elapsed,
            args.max_cer,
            args.min_length_ratio,
            shadow_text,
            args.max_deletion_rate,
            args.max_reference_gap,
            args.max_finalize_seconds,
        ))

    pairwise = [
        cer(left.normalized_text, right.normalized_text)
        for index, left in enumerate(runs)
        for right in runs[index + 1 :]
    ]
    max_pairwise = max(pairwise, default=0.0)
    if max_pairwise > args.max_variance_cer:
        for run in runs:
            if not run.recovered_by_full_audio:
                run.failures.append(
                    f"cross-run variance CER {max_pairwise:.3f} > {args.max_variance_cer:.3f}"
                )
                run.passed = False

    return CaseResult(
        file=path.name,
        audio_seconds=audio_seconds,
        reference=reference,
        normalized_reference=normalize(reference),
        batch_elapsed_seconds=batch_elapsed,
        runs=runs,
        max_pairwise_cer=max_pairwise,
        passed=all(run.passed for run in runs),
    )


def print_case(case: CaseResult) -> None:
    status = "PASS" if case.passed else "FAIL"
    run_summary = " ".join(
        f"r{run.run}:cer={run.cer:.3f},len={run.length_ratio:.2f},"
        f"del={run.deletion_rate:.3f},gap={run.largest_reference_gap},"
        f"coverage={int(run.coverage_complete)},tail={run.unresolved_audio_seconds:.1f}s,"
        f"source={run.final_source},finalize={run.processing_ms / 1000:.2f}s,"
        f"server_retry={int(run.full_retry)},shadow_retry={int(run.shadow_retry)},"
        f"recovered={int(run.recovered_by_full_audio or run.full_recovered)}"
        for run in case.runs
    )
    print(
        f"{status:4} {case.file} audio={case.audio_seconds:.1f}s "
        f"variance={case.max_pairwise_cer:.3f} {run_summary}",
        flush=True,
    )
    if not case.passed:
        print(f"  REF: {case.reference}")
        for run in case.runs:
            if not run.passed:
                print(f"  RUN {run.run}: {run.text}")
                print(f"  WHY: {', '.join(run.failures)}")


async def main_async(args: argparse.Namespace) -> int:
    api_key = Path(args.api_key_file).expanduser().read_text().strip()
    if not api_key:
        raise RuntimeError("API key file is empty")

    audio_paths: list[Path] = []
    for item in args.audio:
        path = Path(item).expanduser()
        audio_paths.extend(sorted(path.glob("*.wav")) if path.is_dir() else [path])
    audio_paths = sorted(set(audio_paths), key=lambda path: path.name)
    if not audio_paths:
        raise RuntimeError("no WAV files found")
    eligible_paths: list[Path] = []
    skipped_paths: list[str] = []
    for path in audio_paths:
        _, duration = read_wav(path)
        if duration >= args.min_audio_seconds:
            eligible_paths.append(path)
        else:
            skipped_paths.append(path.name)
    audio_paths = eligible_paths
    if not audio_paths:
        raise RuntimeError("no WAV files meet the minimum duration")

    shadow_by_file: dict[str, str] = {}
    if args.apple_report:
        shadow_rows = json.loads(Path(args.apple_report).expanduser().read_text())
        shadow_by_file = {
            str(row["file"]): str(row.get("text") or "")
            for row in shadow_rows
            if not row.get("error")
        }

    results: list[CaseResult] = []
    async with httpx.AsyncClient() as client:
        for index, path in enumerate(audio_paths, 1):
            print(f"[{index}/{len(audio_paths)}] {path.name}", flush=True)
            case = await run_case(
                path, client, args, api_key, shadow_by_file.get(path.name)
            )
            results.append(case)
            print_case(case)

    payload = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "configuration": {
            "repeat": args.repeat,
            "max_cer": args.max_cer,
            "min_length_ratio": args.min_length_ratio,
            "max_variance_cer": args.max_variance_cer,
            "max_deletion_rate": args.max_deletion_rate,
            "max_reference_gap": args.max_reference_gap,
            "max_finalize_seconds": args.max_finalize_seconds,
            "pace": args.pace,
            "chunk_size_sec": args.chunk_size_sec,
            "max_context_sec": args.max_context_sec,
            "verification_stride_sec": args.verification_stride_sec,
            "verification_overlap_sec": args.verification_overlap_sec,
            "model": args.model,
            "min_audio_seconds": args.min_audio_seconds,
            "apple_report": args.apple_report,
        },
        "summary": {
            "cases": len(results),
            "runs": sum(len(case.runs) for case in results),
            "passed_cases": sum(case.passed for case in results),
            "failed_cases": sum(not case.passed for case in results),
            "raw_failed_cases": sum(
                any(not run.raw_passed for run in case.runs) for case in results
            ),
            "shadow_recovered_runs": sum(
                run.recovered_by_full_audio for case in results for run in case.runs
            ),
            "mean_cer": statistics.fmean(
                run.cer for case in results for run in case.runs
            ),
            "max_cer": max(run.cer for case in results for run in case.runs),
            "skipped_files": skipped_paths,
        },
        "cases": [asdict(case) for case in results],
    }
    output_path = Path(args.output).expanduser()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(payload["summary"], ensure_ascii=False), flush=True)
    print(f"report={output_path}", flush=True)
    return 0 if payload["summary"]["failed_cases"] == 0 else 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", nargs="+", help="WAV files or directories")
    parser.add_argument(
        "--websocket-url",
        default="ws://127.0.0.1:18765/v1/audio/transcriptions/stream",
    )
    parser.add_argument(
        "--http-url",
        default="http://127.0.0.1:18765/v1/audio/transcriptions",
    )
    parser.add_argument(
        "--api-key-file",
        default=os.environ.get("LOCALVOICE_API_KEY_FILE", "api-key"),
    )
    parser.add_argument("--model", default="Qwen/Qwen3-ASR-0.6B")
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--pace", type=float, default=0.0)
    parser.add_argument("--max-cer", type=float, default=0.12)
    parser.add_argument("--min-length-ratio", type=float, default=0.88)
    parser.add_argument("--max-variance-cer", type=float, default=0.08)
    parser.add_argument("--max-deletion-rate", type=float, default=0.05)
    parser.add_argument("--max-reference-gap", type=int, default=8)
    parser.add_argument("--max-finalize-seconds", type=float, default=5.0)
    parser.add_argument("--chunk-size-sec", type=float, default=3.0)
    parser.add_argument("--max-context-sec", type=float, default=120.0)
    parser.add_argument("--verification-stride-sec", type=float, default=10.0)
    parser.add_argument("--verification-overlap-sec", type=float, default=2.0)
    parser.add_argument("--min-audio-seconds", type=float, default=2.0)
    parser.add_argument(
        "--apple-report",
        help="JSON from apple_speech_regression.swift; enables client recovery gate",
    )
    parser.add_argument("--output", default="streaming-asr-regression.json")
    return parser.parse_args()


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main_async(parse_args())))
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as error:
        print(f"FATAL: {type(error).__name__}: {error}", file=sys.stderr)
        raise SystemExit(2)
