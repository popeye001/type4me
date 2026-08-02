#!/usr/bin/env python3
"""DoubaoIme ASR WebSocket server for Type4Me.

Same WebSocket protocol as the Qwen3-ASR / SenseVoice server so the
Swift client (SenseVoiceWSClient) can connect without changes.

Protocol:
  - Client sends binary PCM16-LE audio frames (16kHz mono)
  - Client sends empty frame to signal end-of-audio
  - Server sends JSON: {"type": "transcript", "text": "...", "is_final": bool}
  - Server sends JSON: {"type": "completed"} when done

Requires: pip install doubaoime-asr fastapi uvicorn
"""

import argparse
import asyncio
import json
import os
import socket
import sys
import time

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from doubaoime_asr.asr import DoubaoASR, ResponseType, AudioChunk
from doubaoime_asr.config import ASRConfig

app = FastAPI()

SAMPLE_RATE = 16000
CHANNELS = 1
FRAME_DURATION_MS = 20

# Credential path (cached device_id + token)
CREDENTIAL_PATH = os.path.expanduser(
    "~/Library/Application Support/Type4Me/doubao-asr-credentials.json"
)


def get_config() -> ASRConfig:
    return ASRConfig(
        credential_path=CREDENTIAL_PATH,
        sample_rate=SAMPLE_RATE,
        channels=CHANNELS,
        frame_duration_ms=FRAME_DURATION_MS,
        enable_punctuation=True,
        enable_asr_twopass=True,
        enable_asr_threepass=True,
    )


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()

    config = get_config()
    asr = DoubaoASR(config)

    # Audio queue: Type4Me sends PCM chunks, we feed them to doubaoime-asr
    audio_queue: asyncio.Queue[bytes | None] = asyncio.Queue()

    async def pcm_to_chunks():
        """Async generator that yields PCM chunks from the WebSocket."""
        while True:
            chunk = await audio_queue.get()
            if chunk is None:  # end-of-audio signal
                break
            yield chunk

    async def receive_audio():
        """Receive PCM audio from Type4Me WebSocket client."""
        try:
            while True:
                data = await ws.receive_bytes()
                if len(data) == 0:
                    # Empty frame = end of audio
                    await audio_queue.put(None)
                    break
                await audio_queue.put(data)
        except WebSocketDisconnect:
            await audio_queue.put(None)

    async def process_asr():
        """Run ASR and send results back to Type4Me."""
        try:
            async for response in asr.transcribe_realtime(pcm_to_chunks()):
                if response.type == ResponseType.INTERIM_RESULT:
                    await ws.send_json({
                        "type": "transcript",
                        "text": response.text,
                        "is_final": False,
                    })
                elif response.type == ResponseType.FINAL_RESULT:
                    await ws.send_json({
                        "type": "transcript",
                        "text": response.text,
                        "is_final": True,
                    })
                elif response.type == ResponseType.ERROR:
                    await ws.send_json({
                        "type": "error",
                        "message": response.error_msg,
                    })
                    break
        except Exception as e:
            try:
                await ws.send_json({"type": "error", "message": str(e)})
            except Exception:
                pass

        # Signal completion
        try:
            await ws.send_json({"type": "completed"})
        except Exception:
            pass

    # Run receive and ASR processing concurrently
    recv_task = asyncio.create_task(receive_audio())
    asr_task = asyncio.create_task(process_asr())

    try:
        await asyncio.gather(recv_task, asr_task)
    except Exception as e:
        print(f"[DoubaoASR] Session error: {e}", file=sys.stderr)
    finally:
        recv_task.cancel()
        asr_task.cancel()


@app.get("/health")
async def health():
    return {"status": "ok", "provider": "doubaoime-asr"}


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="DoubaoIme ASR server for Type4Me")
    parser.add_argument("--port", type=int, default=0, help="Port (0 = auto)")
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    port = args.port or find_free_port()

    # Write port to stdout for the Swift process manager to read
    print(f"PORT={port}", flush=True)

    uvicorn.run(app, host=args.host, port=port, log_level="warning")
