defmodule RandosWeb.Illustrations do
  @moduledoc """
  The site's decorative illustrations, drawn in the logo's language: rounded
  strokes and bars on a 96-unit grid, teal for you, warm stone for the other
  person (the same pairing as the call's audio meters). Inline SVG, so they
  follow the light and dark themes; decorative, so hidden from screen
  readers. Designed and chosen on the "randos icons" canvas (2026-10-20).
  """
  use Phoenix.Component

  attr :id, :string, required: true
  attr :class, :string, default: nil

  @doc "Home: short conversations, a three-quarter timer ring around a voice."
  def short_conversations(assigns) do
    ~H"""
    <svg
      id={@id}
      viewBox="0 0 96 96"
      class={@class}
      fill="none"
      stroke-width="4"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <circle cx="48" cy="48" r="34" opacity="0.35" class="stroke-stone-500 dark:stroke-stone-400" />
      <path d="M48 14a34 34 0 1 1-34 34" class="stroke-teal-600 dark:stroke-teal-400" />
      <path d="M36 44v8M44 38v20M52 41v14M60 45v6" class="stroke-stone-500 dark:stroke-stone-400" />
    </svg>
    """
  end

  attr :id, :string, required: true
  attr :class, :string, default: nil

  @doc """
  About: meet, then disappear: a voice, a brief exchange, a fading peer.
  Wide, so its viewBox is cropped to the drawing: size it by height.
  """
  def meet_then_disappear(assigns) do
    ~H"""
    <svg
      id={@id}
      viewBox="4 32 92 32"
      class={@class}
      fill="none"
      stroke-width="4"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <circle cx="14" cy="48" r="7" class="fill-teal-600 dark:fill-teal-400" />
      <path
        d="M26 48c3 0 3-12 6-12s3 24 6 24 3-20 6-20 3 16 6 16 3-8 6-8"
        class="stroke-teal-600 dark:stroke-teal-400"
      />
      <g class="fill-stone-500 dark:fill-stone-400">
        <circle cx="64" cy="48" r="2.5" opacity="0.8" />
        <circle cx="72" cy="48" r="2.5" opacity="0.5" />
      </g>
      <circle
        cx="84"
        cy="48"
        r="7"
        stroke-dasharray="0.1 5.5"
        class="stroke-stone-500 dark:stroke-stone-400"
      />
    </svg>
    """
  end
end
