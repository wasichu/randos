# Randos Language Default Adjustment

Update locale-based language defaults.

Current behavior sets both Speak and Hear to the detected locale language.

Change this.

## Desired Behavior

### Speak Language

Default Speak to the detected browser locale language if it is supported.

Fallback to:

```text
en
```

### Hear Language

Default Hear to a different language from Speak.

Use this rule:

```text
if speak_language == "en":
  hear_language = "es"
else:
  hear_language = "en"
```

Examples:

```text
Browser locale en-US:
  Speak: English
  Hear: Español

Browser locale es-ES:
  Speak: Español
  Hear: English

Browser locale fr-FR:
  Speak: Français
  Hear: English

Unsupported locale:
  Speak: English
  Hear: Español
```

## Constraints

Do not change matchmaking logic.

Do not add persistence.

Do not add account preferences.

Do not add geolocation.

This is only a default selection change.
