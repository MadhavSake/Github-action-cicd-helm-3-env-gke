const express = require("express");
const os = require("os");

const app = express();

const PORT = process.env.PORT || 8080;
const APP_ENV = process.env.APP_ENV || "local";
const APP_VERSION = process.env.APP_VERSION || "dev-local";
const APP_MESSAGE = process.env.APP_MESSAGE || "Hello from sample-app";

const startedAt = new Date().toISOString();

app.get("/", (req, res) => {
  res.json({
    message: APP_MESSAGE,
    environment: APP_ENV,
    version: APP_VERSION,
    pod: os.hostname(),
    startedAt,
  });
});

// Liveness probe - process is up
app.get("/healthz", (req, res) => res.status(200).send("ok"));

// Readiness probe - app is ready to receive traffic
app.get("/readyz", (req, res) => res.status(200).send("ready"));

let server;
if (require.main === module) {
  server = app.listen(PORT, () => {
    console.log(`sample-app [${APP_ENV}] v${APP_VERSION} listening on :${PORT}`);
  });

  // Graceful shutdown so rolling updates don't drop requests
  const shutdown = (signal) => {
    console.log(`${signal} received, shutting down`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 10000).unref();
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

module.exports = app;
