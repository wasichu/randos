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
Type "cd clients/tui && clear && RANDOS_FAKE_AUDIO=1 mix tui --url ws://localhost:4010/participant/websocket"
Enter
Sleep 5s
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

Enter
Sleep 7s
Screenshot docs/assets/tui-call.png
Sleep 500ms

Type "e"
Sleep 1s
Type "q"
Sleep 1s
