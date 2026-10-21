// Minimal smoke test (no extra test framework needed)
const assert = require("assert");
const http = require("http");
const app = require("./server");

const server = app.listen(0, async () => {
  const port = server.address().port;
  const get = (path) =>
    new Promise((resolve, reject) => {
      http
        .get({ host: "127.0.0.1", port, path }, (res) => {
          let body = "";
          res.on("data", (c) => (body += c));
          res.on("end", () => resolve({ status: res.statusCode, body }));
        })
        .on("error", reject);
    });

  try {
    const health = await get("/healthz");
    assert.strictEqual(health.status, 200);

    const ready = await get("/readyz");
    assert.strictEqual(ready.status, 200);

    const root = await get("/");
    assert.strictEqual(root.status, 200);
    const json = JSON.parse(root.body);
    assert.ok(json.environment, "environment missing");
    assert.ok(json.version, "version missing");

    console.log("All tests passed");
    server.close();
  } catch (err) {
    console.error("Test failed:", err.message);
    server.close();
    process.exit(1);
  }
});
