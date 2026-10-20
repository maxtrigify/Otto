# Voice system benchmark

## Fixed synthetic baseline

Measured on 3 August 2026 on an Apple M4 Mac using ten identical 16 kHz mono WAV files generated
with the macOS system voice. Normalization ignores case and punctuation but preserves words and
numbers.

| Local ASR | Exact | WER | Correct route | Latency |
| --- | ---: | ---: | ---: | --- |
| Parakeet TDT 0.6B v3 int8, warm worker | 6/10 | 13.21% | 10/10 | 294 ms median; 452 ms median observed p95 |
| Apple Speech, on-device en-GB | 4/10 | 24.53% | 7/10 | 221 ms median; 314 ms p95 after cold request |

The warm Parakeet worker meets the current short-command p95 gate and wins this fixed corpus on
accuracy and routing. Five clean four-thread runs produced a 1,515 ms median one-off prepare time,
a 294 ms median-of-medians per utterance, and a 452 ms median observed p95. Otto prewarms one shared
worker for Command and Dictate, so the model is loaded once rather than once per keybinding. Apple
Speech remains the zero-install fallback.

Parakeet routed 10/10 cases correctly, but only 1/3 relayed payloads survived exactly. Otto now strips
the deterministic contamination in “Tell Chase to …”; the remaining substitutions came from ASR
(`v two` → `the tube`, `verbatim` → `verbate and`). The router deliberately does not guess those
words. Relay payload accuracy therefore remains a release blocker even though route accuracy is
strong.

An A/B experiment using sherpa's modified beam search and contextual hotwords was rejected. At a
1.5 token score it recognized `VERBATIM` and `V2`, but regressed `Fit all` to `fittle`, reduced route
accuracy to 9/10, left payload accuracy at 1/3, and had a 480 ms p95. A conservative 0.5 score was
worse: 16.98% WER, 9/10 routes, 1/3 exact payloads, and 756 ms p95. Contextual decoding remains
available to the benchmark but is not the shipped default.

This corpus is deliberately repeatable, not representative of production microphone conditions.
Release qualification also requires recorded speakers, accents, pauses, background audio, near
field/far field microphones, self-echo, and the complete transcript-to-tool action result.

## Release gates

- Command audio-to-action p50 <= 300 ms and p95 <= 600 ms for short supported commands.
- Dictation audio-to-final-text p95 <= 1,000 ms after the user releases push-to-talk.
- Exact deterministic routing >= 99% after a correct transcript.
- Recorded relay routing >= 99% and exact spoken-word payload delivery >= 99% across at least 100
  held-out cases from at least five real speakers.
- No cloud requests from Command, Dictate, Parakeet, or wake-word paths.
- “Hey Otto” recall >= 90% on held-out real speakers and false positives <= 0.1/hour.
- “Otto” alone must not wake the app.
- Echoed Otto speech must not wake the app; voice-processed capture remains enabled.
- “Go to sleep” must close the cloud session and return to opt-in wake listening.

## Reproduce the ASR baseline

```sh
swift build --product otto-voice-benchmark
.build/debug/otto-voice-benchmark --generate-audio-corpus /tmp/otto-voice-corpus
.build/debug/otto-voice-benchmark --benchmark-apple-audio /tmp/otto-voice-corpus
.build/debug/otto-voice-benchmark --benchmark-parakeet-audio /tmp/otto-voice-corpus
.build/debug/otto-voice-benchmark --benchmark-parakeet-warm-audio /tmp/otto-voice-corpus
```

Parakeet can also be benchmarked before installation by passing `--parakeet-runtime` and
`--parakeet-model`. Pass `--parakeet-threads 4` to match the app. Contextual experiments additionally
accept `--parakeet-hotwords`, `--parakeet-bpe-vocab`, and `--parakeet-hotwords-score`. The warm
benchmark keeps the WebSocket worker and model alive across every file.

The official offline WebSocket server listens on all IPv4 interfaces; Otto itself connects only to
`127.0.0.1`, sends no audio to a cloud service, and terminates the child worker when Parakeet is no
longer selected. Replacing that upstream listener with a strictly loopback-bound/in-process runtime
is still desirable defense in depth.

## Competitor feature comparison

Otto now has the same four architectural pillars under evaluation: local Parakeet recognition,
separate Talk/Command/Dictate keybindings, an opt-in raw-audio acoustic wake-word path, and an
audio-to-action benchmark rather than transcript-only testing. Otto additionally has deterministic
sleep handling, one shared prewarmed local worker, cloud/local mode separation, configurable cloud
voices with previews, and explicit release gates.

That is not yet evidence that Otto is categorically better. The competitor has more demonstrated
real-world microphone mileage. Otto still needs a trained production `Hey Otto` classifier and a
multi-speaker recorded relay corpus that clears the exact-payload gate.

## Continuous Talk architecture

OpenAI's GPT-Live design is the target architecture for Otto Talk mode:
<https://openai.com/index/continuous-voice-interaction-with-gpt-live/>. Command and Dictate remain
local Parakeet paths and do not depend on this migration.

The provider-neutral foundation now includes:

- explicit turn-based versus full-duplex provider capabilities;
- speculative partial-transcript records that become authoritative only on provider commit;
- application tool delegation outside the serial voice-event path, so slow agent work cannot hold
  up microphone, transcript, or playback events; and
- a dedicated GPT-5.6 Responses planning path: the live voice model acknowledges a compound
  request immediately, strict structured output splits it into at most six independent briefs,
  and Otto launches those local workers concurrently while Talk remains available; and
- `gpt-realtime-2.1` as the default OpenAI Talk model, with xAI and turn-based OpenAI sessions kept
  as compatibility paths.

The multi-task planner requires an OpenAI API key even when xAI Grok Voice is the selected live
conversation engine. Agent nodes are the durable execution/status surface and their completion,
failure, and waiting transitions flow back through the existing grouped spoken-notification path.

Provider-dependent work remains:

- a WebRTC media frontend and one-round-trip session establishment when OpenAI exposes the required
  GPT-Live transport contract;
- continuous model inference that can listen and speak simultaneously without server VAD;
- warm model-instance handoff/context compaction for long sessions; and
- production shadow traffic, overlap metrics, reconnect metrics, and staged rollout controls.

Do not advertise full duplex for the current WebSocket providers. They stream microphone audio
continuously but still commit turns with server VAD. A future provider must declare full-duplex
support explicitly before Otto preserves assistant playback during overlapping user speech.

## Wake-word model

**Current phrase.** The app's detector loads exactly one classifier file,
`hey_muse.onnx`, and listens for whatever phrase that model was trained on. The only model the
pipeline has produced so far was trained on **"hey muse"** (and only as an undertrained smoke
artifact, see below); no production-qualified classifier has been trained or installed for either
phrase. Until a qualified `hey_otto.onnx` exists and the app loads it, wake listening stays
unavailable and the app must not claim it listens for "Hey Otto".

**Future phrase.** The pipeline now targets **"hey otto"**: the production configuration is
`Config/Voice/hey-otto-wakeword.yaml` (model `hey_otto`, output `hey_otto.onnx`); the small
`-smoke` / `-test` configurations only prove pipeline wiring. Training uses the LiveKit acoustic
pipeline pinned to revision `95448a7559c453fcd87645bd67b247ffb45f85b0`. A production classifier is
installed at:

```text
~/Library/Application Support/Otto/VoiceModels/WakeWord/hey_otto.onnx   # future "Hey Otto"
~/Library/Application Support/Otto/VoiceModels/WakeWord/hey_muse.onnx   # file the app loads today
```

Otto fails closed if the classifier or the native acoustic runtime is missing. Wake listening is
opt-in and default-off because it keeps the microphone/audio subsystem active, shows macOS's orange
microphone indicator, and draws a small continuous amount of power.

An ONNX file alone is not considered installed. Otto also requires the matching
`<model>.quality.json`, verifies that its SHA-256 matches the classifier, loads the evaluated
threshold, and refuses to enable wake listening unless all held-out real-speaker gates pass:

- at least 100 positive samples from at least five distinct speakers;
- at least ten hours of negative/ambient audio;
- recall >= 90%; and
- false activations <= 0.1/hour.

Settings > Voice > Wake-word qualification records 24 kHz mono WAV samples locally and maintains
the corpus manifest at:

```text
~/Library/Application Support/Otto/VoiceQualification/HeyMuse/manifest.json
```

(The folder keeps its pre-rename name until the qualification recorder is retargeted; samples in
it must be of the phrase the model under test was trained on.) Positive samples require an
anonymous speaker ID. Negative samples should include the confusable phrases in the training
config, ordinary conversation, far-field rooms, self-echo, music, typing, and long ambient
sessions. Do not reuse training speakers in this held-out corpus.

Validate or run the pinned training pipeline:

```sh
export OTTO_WAKEWORD_SOURCE=/path/to/livekit-wakeword-at-95448a7559c453fcd87645bd67b247ffb45f85b0
scripts/train-hey-otto-wakeword.sh validate
scripts/train-hey-otto-wakeword.sh smoke
scripts/train-hey-otto-wakeword.sh train
```

`scripts/train-hey-muse-wakeword.sh` remains as a thin wrapper for the renamed script. Every
`OTTO_WAKEWORD_*` variable falls back to its pre-rename `MUSE_WAKEWORD_*` name.
`OTTO_WAKEWORD_SOURCE` is optional: when omitted, the script checks out the official upstream at
the pinned revision under Application Support. Training data and output are staged outside the Git
workspace at `~/Library/Application Support/Otto/VoiceTraining/HeyOtto` by default (a new folder:
the old `VoiceTraining/HeyMuse` workspace holds "hey muse" clips and is never reused). Override
that location with `OTTO_WAKEWORD_TRAINING_ROOT`, for example when using a larger external volume.
The script refuses a fresh setup below 24 GiB free, a smoke run below 12 GiB, or a complete
production run below 35 GiB; `OTTO_WAKEWORD_MIN_FREE_GIB` can override the guard only when storage
has been provisioned and measured separately.

The pinned revision currently has an upstream CLI mismatch: its umbrella `run` command omits the
new `SessionOptions` argument required by feature extraction. Otto's script therefore executes the
same generate, augment/extract, train, export, and eval stages explicitly and supplies a default
ONNX Runtime session configuration without modifying the pinned checkout.

The complete smoke pipeline was executed for "hey muse" on 3 August 2026. It synthesized and
augmented 100 positive/100 adversarial-negative training samples plus validation/background
samples, extracted features, trained all adaptive phases, exported a 122 KB ONNX classifier, and
evaluated 20 positive and 30,114 negative windows (16.73 hours). The intentionally undertrained
result reached 95% recall but 3.65 FPPH at threshold 0.50 (optimal constrained result: 90% recall
and 0.72 FPPH at threshold 0.57), proving the pipeline wiring while correctly failing the <=0.1
FPPH production gate. The guarded installer was verified to reject this smoke artifact.

A "hey otto" model has not been trained yet. A production run (25,000 synthesized positives,
100,000 training steps, 35 GiB free required) is a multi-hour job and needs `uv`, `ffmpeg`,
`espeak-ng` and `sox` installed; it is not something to run on a laptop with little free disk.

Qualify the exported model against the recorded corpus, then install it only if the emitted report
passes every release gate:

```sh
swift build --product otto-voice-benchmark
.build/debug/otto-voice-benchmark \
  --qualify-wakeword-audio "$HOME/Library/Application Support/Otto/VoiceQualification/HeyMuse" \
  --wakeword-model ./output/hey_otto/hey_otto.onnx \
  --output ./output/hey_otto/held-out-real-speaker-eval.json
scripts/install-qualified-hey-otto-wakeword.sh \
  ./output/hey_otto/hey_otto.onnx \
  ./output/hey_otto/held-out-real-speaker-eval.json
```

The installer takes the phrase from the model's file name: `hey_otto.onnx` installs as
`hey_otto.onnx`, `hey_muse.onnx` installs as `hey_muse.onnx` (the file today's app loads), and any
other name is rejected. It installs into `Application Support/Otto`, or into a not-yet-migrated
`Application Support/Muse` when only that folder exists; `OTTO_WAKEWORD_INSTALL_ROOT` (fallback
`MUSE_WAKEWORD_INSTALL_ROOT`) overrides the destination.

The evaluator slides the same two-second acoustic model used by Otto across each WAV, optimizes the
threshold subject to the false-positive budget, and reports the distinct speaker and corpus counts.
The installer independently rechecks those gates before copying the model and hash-bound quality
metadata into Application Support.

## Recorded microphone-to-action qualification

Settings > Voice > Exact-relay qualification records labeled 24 kHz mono WAV cases locally and
maintains the corpus manifest at:

```text
~/Library/Application Support/Otto/VoiceQualification/Relay/manifest.json
```

Each case records the anonymous speaker ID, intended target agent, full spoken command, and exact
spoken-word payload that should reach the agent. Collect at least 100 cases from at least five
consenting held-out speakers. Vary accents, speaking speed, natural pauses, near/far microphones,
rooms, fans, typing, music, and other background speech. Include difficult tokens such as
`verbatim`, version numbers, file names, and agent names; do not tune against the held-out corpus.

Run the same warm recognizer and deterministic command router used by Otto:

```sh
swift build --product otto-voice-benchmark
.build/debug/otto-voice-benchmark \
  --qualify-relay-audio "$HOME/Library/Application Support/Otto/VoiceQualification/Relay" \
  --output ./output/relay-held-out-real-speaker-eval.json
```

The report includes WER, transcript exactness, correct routing, exact spoken-word payload delivery,
median latency, and p95 latency for every recording. The release gate requires at least five real
speakers and 100 cases, >=99% correct routing, >=99% exact payloads, and <=1,000 ms p95 warm
audio-to-action latency. Presentation punctuation and capitalization are ignored because they are
not encoded by speech; word insertions, omissions, and substitutions all fail exactness.
