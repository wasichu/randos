Refactor the main Phoenix LiveView homepage render function for maintainability without changing behavior or appearance.

The current `render(assigns)` function contains a large inline `~H` HEEx template. Extract the major page sections into private render helper functions in the same LiveView module, or into colocated HEEx/component helpers if that is cleaner.

Goals:

1. Preserve the exact rendered UI and behavior.
2. Preserve all existing gettext calls.
3. Do not dynamically construct translatable strings.
4. Keep gettext calls statically visible in HEEx where possible.
5. Split the large template into clear sections such as:

   * hero
   * language selection
   * call controls
   * waiting/matching state
   * active call state
   * footer or info sections
6. Keep assigns usage explicit and easy to follow.
7. Avoid introducing new dependencies.
8. Avoid changing event names, IDs, phx hooks, CSS classes, or JS integration points.
9. Prefer small private functions like `hero(assigns)`, `language_selector(assigns)`, and `call_panel(assigns)` if appropriate.
10. After refactoring, run formatting and ensure the code compiles.

Important constraints:

* This is a refactor only.
* Do not redesign the page.
* Do not change copy.
* Do not change gettext domains or message IDs.
* Do not move translated strings into JavaScript.
* Do not replace gettext calls with plain strings.
* Do not invent new components unless they make the file clearly simpler.

After completing the refactor, summarize:

1. What changed structurally.
2. Whether any behavior changed.
3. Any gettext/localization risks you noticed.

