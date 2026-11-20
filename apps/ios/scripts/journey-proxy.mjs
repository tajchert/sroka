#!/usr/bin/env node
// TCP proxy between the simulator and `wrangler dev`, so a journey can take the server "offline" without stopping it.
// Usage: node journey-proxy.mjs <listenPort> <upstreamPort> <controlFile>
// While the control file contains "down", new connections are closed at once and open ones are destroyed.
import fs from "node:fs";
import net from "node:net";

const [listenPort, upstreamPort, controlFile] = process.argv.slice(2);
if (!listenPort || !upstreamPort || !controlFile) {
  console.error("usage: journey-proxy.mjs <listenPort> <upstreamPort> <controlFile>");
  process.exit(2);
}

const isDown = () => {
  try {
    return fs.readFileSync(controlFile, "utf8").trim() === "down";
  } catch {
    return false;
  }
};
const open = new Set();

net
  .createServer((client) => {
    if (isDown()) return client.destroy();
    const upstream = net.connect(Number(upstreamPort), "127.0.0.1");
    open.add(client);
    open.add(upstream);
    const close = () => {
      open.delete(client);
      open.delete(upstream);
      client.destroy();
      upstream.destroy();
    };
    client.on("error", close).on("close", close);
    upstream.on("error", close).on("close", close);
    client.pipe(upstream);
    upstream.pipe(client);
  })
  .listen(Number(listenPort), "127.0.0.1", () => console.log(`proxy :${listenPort} -> :${upstreamPort}`));

setInterval(() => {
  if (isDown()) for (const socket of open) socket.destroy();
}, 200);
