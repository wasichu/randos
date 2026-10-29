# Pretrained voice experiment

`just voice-model` runs **Seed-VC V2** on the four existing public LibriVox
excerpts, then the lab's **Models** tab presents Original → Converted with
250 ms gaps, looping and the existing local review workflow. First run
downloads about 2.7 GB of weights. Inference is entirely local, on MPS if
available or CPU otherwise. No microphone or call recordings are used.

This is a listening experiment, not a selected production architecture.
The owner judged all eight McAdams approximate recoveries recognizable;
stronger McAdams settings also sounded artificial. The next hypothesis is
that a learned content bottleneck and speech regeneration can produce a
more convincing, natural change of voice. Neural conversion does **not**
itself establish resistance to recognition or reconstruction.

## Selection

- **Seed-VC V2, chosen:** pretrained weights, a narrow content bottleneck,
  optional autoregressive style regeneration, and average-voice mode make
  it the strongest fit among the candidates inspected for this probe.
  This is an architectural judgment, not a measured ranking of all models.
  Both [code](https://github.com/Plachtaa/seed-vc) and
  [weights](https://huggingface.co/Plachta/Seed-VC) are GPL-3.0; upstream is
  archived. They stay in ignored local storage, outside the app and Rust
  dependency tree. Redistribution/integration is a separate decision.
- [OpenVoice V2](https://huggingface.co/myshell-ai/OpenVoiceV2): MIT code and
  weights, a useful alternative if permissive licensing becomes a hard
  requirement. Its tone-color conversion is a weaker test of removing
  source style than Seed V2's narrow-token + AR path.
- [StreamVC](https://arxiv.org/abs/2401.03078): relevant mobile/streaming
  architecture, but a paper/demo alone is insufficient to run this probe;
  the inspected unofficial implementation did not supply trained weights.
- VoicePrivacy baselines are valuable evaluation references, but adopting
  their full infrastructure would delay this four-clip listening decision.

## Reproduce

The bootstrap uses `uv`, git, FFmpeg (upstream creates an unused MP3 preview), and an isolated Python 3.11.17 environment in
`tmp/seed-vc/.venv`; it never changes `tools/voice-eval/.venv` or any runtime
dependency. `requirements.lock` pins the complete inference environment.
`models.json` pins upstream code and each model repository revision. Only
the required official weight/config/tokenizer files are downloaded. Model
constructors receive local snapshots, with no remote model code enabled.

An existing checkout must match the pin and have no tracked edits; the
probe refuses to silently replace a locally modified model. If the checkout
was made manually, use the revision in `models.json` before running.

The fixed configuration is 30 diffusion steps, style conversion **on**,
anonymization-only **on**, length adjustment 1, seed 20261024, and upstream
guidance/sampling defaults captured in the report. Style conversion is
essential: upstream's CLI default disables the narrow-token + AR path.
Compilation is not enabled. MPS uses upstream's float16 autocast/cache
dtype; CPU uses float32. Some modules remain float32, so the dtype is not
a claim that every operation runs at half precision.

The wrapper still loads/processes the same `mid_voice.wav` reference for
all four inputs. Average-voice mode supplies no target prefix to AR and
zeros speaker-style/acoustic-prompt conditioning in the flow generator.
Reference content tokens still reach that generator's attention context;
reference independence is **unverified**. This is not an explicitly
target-person cloning experiment; reference-path effects are not separately
ablated. We save the returned float waveform, not the MP3 preview. No output
is trimmed to input length. Both original and output are multiplied by a
fixed 0.25 for playback headroom, without per-clip normalization.

`results/seed-vc-v2.json` records source/model hashes, exact configuration,
device, dtype, seed, durations, wall times, output saturation and listening
clipping. Each result is published as it completes; failures remain visible
and terminate the run. WAV filenames are content-addressed in ignored
`tmp/voice-model`, so a later run cannot change audio under an old review.
The dev-only controller serves only WAV basenames from this directory.
Missing files can be regenerated with the same command.

## Decision after listening

Save reviews in the Models tab, including any word, pronunciation, accent,
rhythm or emotion changes in Notes. A language-practice tool must preserve
more than the approximate meaning. Listen before expanding the corpus or
building a streaming runtime. If promising, measure memory/compute and test
appropriate recorded-output recovery attacks; retain the known-reference
recognition benchmark as a separate diagnostic.

Whole-clip processing time is **not** call latency. Upstream's method named
`convert_voice_with_streaming` reads/extracts full source features before
yielding output. CFM/AR parameter counts omit the large content encoder
and vocoder. This probe provides no evidence of browser feasibility or
reconstruction resistance. No browser port, training, or call integration
is part of it.
