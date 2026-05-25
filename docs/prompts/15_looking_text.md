Update the matchmaking waiting text to be more specific and aligned with the language exchange model.

Current text:
"Looking for a compatible rando..."

Desired behavior:
Show a message like:

"Looking for a rando speaking Spanish who wants to hear English..."

or more generally:

"Looking for a rando speaking {hear_language} who wants to hear {speaks_language}..."

Requirements:

* Keep the wording concise and natural.
* Preserve all existing functionality and assigns/state logic.
* Use existing language selection state rather than introducing new state.
* Preserve gettext/localization support if present.
* Do not redesign the UI.
* Only update the waiting/matchmaking status text.

