# Integration tests need a running Randos server (just tui-smoke starts one).
# :native tests need the media helper built (cargo build -p randos_media).
helper_built? = File.regular?(Tui.Media.default_helper_path())
ExUnit.start(exclude: [:integration] ++ if(helper_built?, do: [], else: [:native]))
