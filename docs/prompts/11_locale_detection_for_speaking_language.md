# Randos Locale-Based Language Defaults

Add lightweight locale-based language defaults.

## Goal

Reduce friction when entering the matchmaking flow.

The app should intelligently default the user’s “Speak” language based on browser locale.

If locale detection fails or is unsupported, default to English.

## Requirements

Use browser locale information such as:

```js
navigator.language
```

Examples:

```text
en-US
es-ES
pt-BR
ja-JP
```

Normalize locales to the app’s internal language codes.

Examples:

```text
en-US -> en
es-MX -> es
pt-BR -> pt
ja-JP -> ja
```

## Supported Mapping

Support the current initial language set:

```text
en
es
zh
hi
ar
pt
bn
ru
ja
fr
de
ko
it
tr
id
```

## Default Behavior

### Speak Language

Default to the detected locale language if supported.

Fallback:

```text
English (en)
```

if unsupported or unavailable.

### Hear Language

Initially default to the same language as Speak.

Users can then intentionally change it for:

- crosstalk
- language exchange
- listening practice

## Constraints

Do not add:

- geolocation
- account preferences
- persistent cookies/settings yet
- translation
- auto language switching

This should be a lightweight browser-locale convenience only.
