# LocalVoice production patches

The active Qwen streaming wrapper runs on `million@192.168.0.189` at:

`/Users/million/localvoice-server/localvoice_streaming_server.py`

`2026-08-03-stream-full-recovery.patch` records the production change that
detects repeated decoder output or multiple voiced stalls and falls back to one
full-audio, fresh-cache transcription. The server-side rollback copy is:

`localvoice_streaming_server.py.pre-full-recovery-20260803`

Reproduction audio session: `047837AA-0ED7-48FF-A7EF-F79E585B5D3F`.
Before the patch, the stream returned 45 characters and lost roughly the final
half. A full decode with the same Qwen3-ASR-0.6B model returned 112 characters.
After the patch, the WebSocket final reported `full_retry=true`,
`full_recovered=true`, and returned the full 112-character result.
