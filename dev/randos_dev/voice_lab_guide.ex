defmodule RandosDev.VoiceLabGuide do
  @moduledoc "Plain-language context for the development-only voice lab."
  use Phoenix.Component

  def basics(assigns) do
    ~H"""
    <div class="space-y-6 rounded-lg border border-stone-200 bg-white p-5 sm:p-6">
      <header class="space-y-2">
        <h2 class="text-xl font-semibold">A voice becomes a stream of numbers</h2>
        <p class="max-w-3xl text-stone-600">
          Your vocal folds vibrate, and your mouth and throat shape that vibration into
          speech. A microphone senses the changing air pressure. The computer measures
          that signal many times a second and represents each measurement as a number: a sample.
        </p>
      </header>
      <ol class="grid gap-4 sm:grid-cols-3" aria-label="From voice to digital audio">
        <li class="space-y-1">
          <h3 class="font-semibold">1. Sound</h3><p class="text-sm text-stone-600">
            Air pressure changes continuously as you speak.
          </p>
        </li>
        <li class="space-y-1">
          <h3 class="font-semibold">2. Samples</h3><p class="text-sm text-stone-600">
            At 48,000 Hz, the computer takes 48,000 measurements per second, per channel. This is the sample rate, not the pitch of your voice.
          </p>
        </li>
        <li class="space-y-1">
          <h3 class="font-semibold">3. Playback</h3><p class="text-sm text-stone-600">
            The speaker converts the sequence back into movement, recreating pressure changes you can hear.
          </p>
        </li>
      </ol>
      <div class="space-y-2">
        <h3 class="font-semibold">A file and a live call carry the same kind of signal</h3>
        <p class="max-w-3xl text-sm text-stone-600">
          A recording saves those numbers for later. A WAV file contains a header describing
          its format (sample rate, channels, and sample encoding), followed by audio data.
          Uncompressed PCM stores amplitude samples directly; formats such as Opus compress
          audio to use fewer bytes. Mono has one channel; stereo has two. Bit depth describes
          the precision of integer samples; audio processing often uses floating-point numbers.
        </p>
        <p class="max-w-3xl text-sm text-stone-600">
          This lab decodes its bundled WAV files into one channel of floating-point samples
          at 48,000 Hz. One second is 48,000 numbers. A waveform plots those numbers against
          time. A spectrogram instead breaks short slices into frequencies, making pitch and
          tone patterns easier to see.
        </p>
        <p class="max-w-3xl text-sm text-stone-600">
          Streaming sends short chunks as they arrive instead of saving a whole file first.
          A randos call captures samples, optionally modifies them on your device, compresses
          them with Opus, and sends encrypted WebRTC packets. The other device buffers,
          decodes, and plays them. No call audio is recorded or processed by the randos server.
        </p>
      </div>
      <div class="space-y-2">
        <h3 class="font-semibold">What is the audible speech spectrum?</h3>
        <p class="max-w-3xl text-sm text-stone-600">
          A voice contains many frequencies at once. The repeating vibration gives it
          pitch; higher harmonics, resonances, and breathy or hissing sounds help make
          different vowels and consonants recognizable. “Spectrum” means how the sound’s
          energy is spread across those frequencies. “Audible” means we can hear it.
          The spectrograms here show only 0–4,000 Hz, not the full range of the audio or
          of human hearing. The 48,000 Hz sample rate is how often we measure the signal,
          not the highest frequency in someone’s voice.
        </p>
      </div>
      <div class="space-y-3">
        <h3 class="font-semibold">What can we change?</h3>
        <dl class="grid gap-4 sm:grid-cols-2">
          <div>
            <dt class="font-medium">Volume and filtering</dt><dd class="text-sm text-stone-600">
              Make samples louder or quieter, or emphasize or remove frequency ranges. Useful for sound quality; these alone do not establish anonymity.
            </dd>
          </div>
          <div>
            <dt class="font-medium">Pitch — available now</dt><dd class="text-sm text-stone-600">
              Change how high or low the voice sounds. Our current pitch shifter also moves its resonances, so the voice can sound larger or smaller.
            </dd>
          </div>
          <div>
            <dt class="font-medium">Formants — McAdams experiment available</dt><dd class="text-sm text-stone-600">
              Change the resonances shaped by the vocal tract while retaining the source excitation.
              Choose McAdams under Modification to try it. These changes affect voice character
              and vowel sounds, so listen for naturalness and clear pronunciation.
            </dd>
          </div>
          <div>
            <dt class="font-medium">Voice conversion — a future experiment</dt><dd class="text-sm text-stone-600">
              Use a model to produce speech with a different voice character. We would need to test identity protection, clarity, device cost, and delay before choosing it.
            </dd>
          </div>
        </dl>
      </div>
      <p class="max-w-3xl text-sm text-stone-600">
        Sounding different is only one test. A useful anonymizer must also resist speaker
        recognition, preserve language-learning cues, and run fast enough for a conversation.
        The Benchmark view checks some of those questions; listening checks others.
      </p>
    </div>
    """
  end

  def delay(assigns) do
    ~H"""
    <section
      id="voice-lab-seam"
      class="space-y-4 rounded-lg border border-stone-200 bg-white p-5 sm:p-6"
    >
      <h2 class="text-xl font-semibold">Will changing my voice make the conversation lag?</h2>
      <p class="max-w-3xl text-stone-600">
        A voice modifier sits between your microphone and the outgoing call audio.
        It may need to collect a short piece of sound before it can change it. That means
        the other person hears you a little later. We want to measure this added delay
        before choosing a modification for conversations.
      </p>
      <ol class="flex flex-wrap items-center gap-3 text-sm" aria-label="Outgoing call audio path">
        <li class="rounded-md bg-stone-100 px-3 py-2">Microphone</li>
        <li aria-hidden="true">→</li>
        <li class="rounded-md bg-stone-100 px-3 py-2 text-stone-950">Optional voice processor</li>
        <li aria-hidden="true">→</li>
        <li class="rounded-md bg-stone-100 px-3 py-2">Encode & send to the call</li>
      </ol>
      <p class="max-w-3xl text-sm text-stone-600">
        First, we need a reference measurement: how much delay does the browser add
        just by routing audio through a processing step, even when it copies the sound
        unchanged? This test sends a repeating click along two paths—directly, and through
        an unchanged-copy processor—and compares when the clicks arrive. It takes about
        three seconds, makes no sound, and does not use your microphone.
      </p>
      <div class="flex flex-wrap items-center gap-3">
        <button
          id="voice-lab-measure"
          type="button"
          class="rounded-md border border-stone-300 px-4 py-2 font-medium transition hover:bg-stone-100 disabled:opacity-50"
        >Measure processing overhead</button>
        <span
          id="voice-lab-seam-result"
          role="status"
          class="text-sm text-stone-700"
          data-state="idle"
        ></span>
      </div>
      <p class="max-w-3xl text-sm text-stone-600">
        Read the result as extra waiting time from that unchanged-copy step, in
        milliseconds (1,000 ms = one second). A voice-changing algorithm may add more
        delay on top. This is not a measurement of a complete call: network travel,
        audio compression, and microphone and speaker hardware add their own delays.
        Results vary by browser, device, and run.
      </p>
      <p class="max-w-3xl text-sm text-stone-600">
        In Listen & compare, “render time” means the time needed to prepare a clip as a
        percentage of its duration. 1% means a ten-second clip took about 0.1 seconds to
        prepare. It is not a CPU-utilization reading or proof that every live audio chunk
        will meet its deadline. “Signal delay” estimates how far the processed audio lags
        behind the original within the clip.
      </p>
    </section>
    """
  end
end
