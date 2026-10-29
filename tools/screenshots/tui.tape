# The TUI's README screenshots (run by screenshots.mjs, which has a peer
# waiting on the throwaway server at :4010). A test tone for the mic and no
# speaker (RANDOS_FAKE_AUDIO), so nothing real is heard or recorded.
Set Shell "bash"
Set FontSize 18
Set Width 1300
Set Height 760
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 0

Hide
# Fresh settings in English (not the developer's own file and language).
Type "cd clients/tui && rm -f tmp/screenshots-settings.json && clear && LC_ALL=en_US.UTF-8 RANDOS_TUI_SETTINGS=tmp/screenshots-settings.json RANDOS_FAKE_AUDIO=1 mix tui --url ws://localhost:4010/participant/websocket"
Enter
Sleep 5s
Show
Sleep 500ms
Screenshot tmp/tui-language-pristine.png
Type "l"
Sleep 500ms
Screenshot docs/assets/tui-language.png
Escape
Sleep 500ms
Screenshot tmp/tui-language-dismissed.png

Hide
# Also happy to hear Spanish (the peer speaks it), then confirm "I'm an
# adult". The cursor stays on the hearing row, for the screenshot.
Tab
Right
Space
Tab
Space
Up
Sleep 500ms
Show
Sleep 500ms
Screenshot docs/assets/tui-idle.png
Sleep 500ms

Type "?"
Sleep 500ms
Screenshot docs/assets/tui-help.png
Escape
Sleep 500ms

Type "b3"
Right
Sleep 500ms
Screenshot docs/assets/tui-voice.png
Escape
Sleep 500ms

Enter
Sleep 7s
Screenshot docs/assets/tui-call.png
Sleep 500ms

Type "e"
Sleep 1s
# Inviting someone (the link's host is PHX_HOST's).
Type "v"
Sleep 2s
Screenshot docs/assets/tui-invite.png
Sleep 500ms
Type "c"
Sleep 1s
Type "q"
Sleep 1s
