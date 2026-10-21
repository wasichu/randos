// A tiny HTTP proxy for the e2e tests, so a test can cut a page's
// connection to the server the way a network does: abruptly, with no
// WebSocket close handshake (the browser sees code 1006). A close from page
// script can't do that: the server answers it, the close is "clean" (1000),
// and Phoenix doesn't reconnect.
//
// Chrome is pointed at it with --proxy-server (Browser.launch's extraArgs).
// It forwards plain HTTP requests and CONNECT tunnels (HTTPS, wss) alike,
// remembers each tunnel or socket by the path it carried, and dropMatching
// destroys the ones whose first request line matches.
//
//   const proxy = await startDropProxy()
//   const browser = await Browser.launch({extraArgs: [`--proxy-server=127.0.0.1:${proxy.port}`]})
//   ...
//   proxy.outage(1_500)   // cut everything, refuse new connections for 1.5 s
//   proxy.close()

import net from "node:net"

export async function startDropProxy() {
  const connections = new Set()
  let downUntil = 0

  const server = net.createServer(client => {
    // During an outage, new connections die at once, like a dead network.
    if (Date.now() < downUntil) return client.resetAndDestroy?.() ?? client.destroy()

    let head = Buffer.alloc(0)
    const entry = {client, upstream: null, firstLine: ""}
    connections.add(entry)

    const forget = () => {
      connections.delete(entry)
      entry.upstream?.destroy()
      client.destroy()
    }
    client.on("error", forget)
    client.on("close", forget)

    const onData = chunk => {
      head = Buffer.concat([head, chunk])
      const end = head.indexOf("\r\n\r\n")
      if (end < 0) return
      client.off("data", onData)

      const text = head.subarray(0, end).toString("latin1")
      entry.firstLine = text.split("\r\n")[0]
      const [method, target] = entry.firstLine.split(" ")

      if (method === "CONNECT") {
        const [host, port] = target.split(":")
        entry.upstream = net.connect(Number(port), host, () => {
          client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
          const rest = head.subarray(end + 4)
          if (rest.length) entry.upstream.write(rest)
          client.pipe(entry.upstream).pipe(client)
        })
      } else {
        // An absolute-URI request: send it on with the path only.
        const url = new URL(target)
        entry.upstream = net.connect(Number(url.port || 80), url.hostname, () => {
          const rewritten = text.replace(target, url.pathname + url.search)
          entry.upstream.write(rewritten + "\r\n\r\n")
          const rest = head.subarray(end + 4)
          if (rest.length) entry.upstream.write(rest)
          client.pipe(entry.upstream).pipe(client)
        })
      }
      entry.upstream.on("error", forget)
      entry.upstream.on("close", forget)
    }
    client.on("data", onData)
  })

  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve))

  // Destroy both ends at once: no FIN-and-wait, no close frame.
  const cut = entry => {
    entry.client.resetAndDestroy?.() ?? entry.client.destroy()
    entry.upstream?.destroy()
    connections.delete(entry)
  }

  return {
    port: server.address().port,
    // Plain HTTP: the request line shows the path (the WebSocket upgrade).
    dropMatching(pattern) {
      const hits = [...connections].filter(entry => pattern.test(entry.firstLine))
      hits.forEach(cut)
      return hits.length
    },
    // HTTPS: tunnels are opaque (CONNECT host:443), so drop every one.
    dropAll() {
      const all = [...connections]
      all.forEach(cut)
      return all.length
    },
    // The network goes away for `ms`: every connection is cut and new ones
    // are refused until it's back.
    outage(ms) {
      downUntil = Date.now() + ms
      return this.dropAll()
    },
    close() {
      for (const entry of [...connections]) cut(entry)
      server.close()
    },
  }
}
