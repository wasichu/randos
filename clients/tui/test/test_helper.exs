# Integration tests need a running Randos server (just tui-smoke starts one).
ExUnit.start(exclude: [:integration])
