# Randos

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## HTTPS in development

Microphone capture and WebRTC testing are more reliable from a secure browser
context. This project enables a dev HTTPS endpoint when local certificate files
exist at `priv/cert/randos_dev.pem` and `priv/cert/randos_dev_key.pem`.

Install and initialize `mkcert`, then generate the local certificate:

```bash
mkcert -install
mkdir -p priv/cert
mkcert \
  -key-file priv/cert/randos_dev_key.pem \
  -cert-file priv/cert/randos_dev.pem \
  localhost 127.0.0.1 ::1 "$(hostname)" randos.local
```

Then start the server:

```bash
mix phx.server
```

Visit [`https://localhost:4001`](https://localhost:4001) for microphone and
WebRTC work. The HTTP endpoint remains available at
[`http://localhost:4000`](http://localhost:4000).

Restart the browser after `mkcert -install` if it was already open, so the new
local CA is picked up.

Useful overrides:

```bash
HTTPS_PORT=4443 mix phx.server
DEV_SSL_CERTFILE=/path/to/cert.pem DEV_SSL_KEYFILE=/path/to/key.pem mix phx.server
```

For LAN or phone testing, regenerate the certificate with the device-visible
hostname or IP address included in the `mkcert` name list, then restart Phoenix.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
