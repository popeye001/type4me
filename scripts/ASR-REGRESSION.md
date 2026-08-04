# LocalVoice ASR regression gate

This gate replays saved Type4Me WAV recordings through the same 200 ms
WebSocket chunks used by the app. A fresh-cache whole-file REST transcription
from the same Qwen model is the coverage reference. Each stream is repeated so
randomness, dropped clauses, repeated text, and cross-run variance are visible.

Apple SpeechAnalyzer runs locally as an independent coverage judge:

```bash
scripts/apple_speech_regression.swift \
  --output /tmp/type4me-apple.json \
  "$HOME/Library/Application Support/Type4Me/AudioHistory"
```

Run `streaming_asr_regression.py` inside the LocalVoice server virtualenv (it
needs `httpx` and `websockets`). Copy the WAV corpus and Apple report to the
server first, then run:

```bash
.venv/bin/python streaming_asr_regression.py ./audio \
  --api-key-file ./api-key \
  --apple-report ./apple.json \
  --repeat 3 \
  --output ./streaming-asr-regression.json
```

The command exits non-zero when any final result fails. The report keeps raw
stream quality separate from client recovery: `raw_failed_cases` shows decoder
failures, while `failed_cases` must be zero after the Apple cross-check and
whole-file recovery policy are applied.

The client cross-check itself has a no-XCTest smoke gate for machines whose
Command Line Tools do not ship the XCTest module:

```bash
swiftc Type4Me/ASR/ASRShadowCrossCheck.swift \
  scripts/asr_shadow_crosscheck_smoke.swift \
  -o /tmp/asr-shadow-crosscheck-smoke
/tmp/asr-shadow-crosscheck-smoke
```

Do not commit personal WAV recordings or transcript reports. They may contain
private dictation and belong under the user's Type4Me application-support
directory.
