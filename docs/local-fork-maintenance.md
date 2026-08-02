# Type4Me Local Fork Maintenance

This fork carries Mac-local fixes that are useful before they are accepted
upstream. The goals are:

- keep the local Apple Silicon ASR path stable for daily use;
- avoid high sustained load from speculative LLM calls while recording;
- keep patches small enough to submit upstream as focused PRs.

## Current Patch Set

### Qwen3-ASR memory control

Source: `qwen3-asr-server/server.py`

This patch is based on upstream PR #157 and addresses memory growth during
long SenseVoice + Qwen3 sessions:

- store audio as `bytearray` instead of `list[int]`;
- cap partial windows to 20 seconds;
- decode PCM16 with `numpy.frombuffer`;
- call MLX cache cleanup after each ASR/LLM inference;
- set an MLX cache limit when the installed MLX exposes the API.

Runtime expectation: the Qwen3-ASR helper should idle around hundreds of MB
and should not grow monotonically into multi-GB RSS during long dictation.

### Disable recording-time speculative LLM by default

Source: `Type4Me/Session/RecognitionSession.swift`

The upstream app speculatively calls the configured LLM during recording when
streaming ASR emits partial transcript updates. This reduces stop-time latency
for fast cloud LLMs, but it is expensive for local large models. On a local
Qwen3.6 35B endpoint it repeatedly wakes the model, cancels in-flight requests,
and causes high sustained power draw before the user finishes speaking.

This fork adds a `tf_enableSpeculativeLLM` override. When the key is not set,
speculative LLM remains enabled for cloud providers and is disabled for local
LLM providers such as Ollama. Final post-processing after the user stops
recording is unchanged.

To explicitly re-enable it for fast local or small-model setups:

```bash
defaults write com.type4me.localfixed tf_enableSpeculativeLLM -bool true
```

To explicitly disable it again:

```bash
defaults write com.type4me.localfixed tf_enableSpeculativeLLM -bool false
```

## Local Build Notes

The public source tree does not include `Frameworks/sherpa-onnx.xcframework`.
Without that framework the Swift target builds without `HAS_SHERPA_ONNX`, and
the local SenseVoice provider will show as unsupported.

For a true source-built local app, first build or provide the framework:

```bash
cd /path/to/type4me
bash scripts/build-sherpa.sh
```

Then package the local variant:

```bash
VARIANT=local \
ARCH=arm64 \
APP_BUNDLE_ID=com.type4me.localfixed \
APP_PATH="$HOME/Applications/Type4Me Local Fixed.app" \
QWEN3_MODEL_PATH="/Applications/Type4Me.app/Contents/Resources/Models/Qwen3-ASR" \
bash scripts/package-app.sh
```

Until the framework is available, the practical local hotfix flow is:

1. copy the installed local DMG app;
2. change bundle id/name;
3. replace `qwen3-asr-server-dist/qwen3-asr-server` with a wrapper that runs
   the patched Python server;
4. sign the bundle consistently.

## Signing

Ad-hoc signing works for local testing but macOS TCC Accessibility permissions
can be invalidated whenever the app is modified and re-signed.

Recommended stable options:

- use an Apple Developer ID certificate if this build will be distributed;
- use a persistent local codesigning certificate for personal builds;
- keep a fixed install path, currently:

```text
~/Applications/Type4Me Local Fixed.app
```

After re-signing, reset and grant Accessibility again if hotkeys stop working:

```bash
tccutil reset Accessibility com.type4me.localfixed
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
```

Grant the fixed app path, not `/Applications/Type4Me.app`.

## Verification

Check processes:

```bash
ps -axo pid,ppid,pcpu,pmem,rss,etime,args \
  | egrep -i 'Type4Me|qwen3-asr|server.py|omlx' \
  | egrep -v 'egrep|Codex'
```

Check for unwanted recording-time LLM calls:

```bash
tail -f "$HOME/Library/Application Support/Type4Me/debug.log" \
  | egrep 'speculative LLM|fresh LLM|sync LLM|q3Port|ASR transcript'
```

Expected after this fork patch:

- no `speculative LLM: firing` lines while recording;
- exactly one final `fresh LLM` or `sync LLM` call after stop when the selected
  mode has a prompt;
- Qwen3-ASR RSS stays bounded over repeated long recordings.

## Upstream PR Plan

Submit small PRs independently:

1. Qwen3-ASR memory fix, based on PR #157 or as a review/continuation.
2. Add a user/defaults setting for speculative LLM and disable it by default
   for local LLM providers or large local models.
3. Optional UI toggle: "Low-latency speculative LLM" vs "Energy-saving final
   LLM only".

Avoid bundling signing or local wrapper changes in upstream PRs; those are
local distribution concerns.
