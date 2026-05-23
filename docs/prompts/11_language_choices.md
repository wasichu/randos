# Randos Language Expansion Pass

Expand the available language selection options.

The app should support an intentionally limited but globally useful initial set of languages to improve matchmaking density while keeping the UI simple and calm.

## Goal

Add the following languages as selectable options for:

- Speak
- Hear

Use native language names where practical.

## Initial Language Set

```text
English (EN)
Español (ES)
中文 (ZH)
हिन्दी (HI)
العربية (AR)
Português (PT)
বাংলা (BN)
Русский (RU)
日本語 (JA)
Français (FR)
Deutsch (DE)
한국어 (KO)
Italiano (IT)
Türkçe (TR)
Bahasa Indonesia (ID)
```

## Internal Representation

Store languages internally using proper language codes.

Examples:

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

Avoid hardcoding display labels directly into matchmaking logic.

Keep display labels separate from internal identifiers.

## Display Style

Do not use country flags.

Languages are not countries.

Instead, use:

- native language names
- subtle language codes

Examples:

```text
Español (ES)
English (EN)
Português (PT)
日本語 (JA)
```

Keep the styling restrained and readable.

Avoid:

- emoji flags
- oversized badges
- Duolingo-style visuals
- gamified language-picker aesthetics

## UI Requirements

Language selectors should remain:

- simple
- clean
- mobile friendly
- uncluttered

Do not add:

- searchable mega dropdowns
- language recommendation systems
- proficiency filtering
- dialect selection
- regional selection

Simple select/dropdown UI is sufficient.

## Matching Logic

Do not change the existing compatibility logic.

The expanded language set should integrate into the current matchmaking system.

## Constraints

Do not add:

- translation features
- AI assistance
- automatic language detection
- language learning gamification
- profile-based matching

This change should only expand the supported language set and associated UI presentation.
