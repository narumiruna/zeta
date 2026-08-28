import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [root, command, argument] = process.argv.slice(2);
if (!root || !command) throw new Error("usage: oracle.mjs <pi-root> <command> [argument]");

if (command === "protocol") {
  const protocol = await import(pathToFileURL(resolve(root, "packages/protocol/dist/index.js")));
  const bytes = protocol.encodeClientMessage({ type: "hello", version: protocol.PROTOCOL_VERSION });
  process.stdout.write(Buffer.from(bytes).toString("hex"));
} else if (command === "session") {
  const sessions = await import(
    pathToFileURL(resolve(root, "packages/coding-agent/dist/core/session-manager.js"))
  );
  const entries = sessions.parseSessionEntries(readFileSync(argument, "utf8"));
  const sessionEntries = entries.filter((entry) => entry.type !== "session");
  const context = sessions.buildSessionContext(sessionEntries);
  process.stdout.write(JSON.stringify({
    entries: sessionEntries.length,
    messages: context.messages.length,
    thinkingLevel: context.thinkingLevel,
    model: context.model,
  }));
} else if (command === "sqlite-mutate") {
  const { DatabaseSync } = await import("node:sqlite");
  const database = new DatabaseSync(argument);
  database.exec("BEGIN IMMEDIATE");
  try {
    database.prepare("UPDATE session_sequences SET next_seq=3 WHERE session_id=?").run("session-fixture");
    database.prepare("INSERT INTO entries(session_id,seq,id,parent_id,type,timestamp,payload) VALUES(?,?,?,?,?,?,?)")
      .run("session-fixture", 2, "entry-typescript", "entry-1", "custom", 1700000000100,
        JSON.stringify({ customType: "interop", runtime: "typescript" }));
    database.prepare("INSERT INTO branch_entries VALUES(?,?,?,?,?,?)")
      .run("session-fixture", "entry-1", "entry-typescript", 2, "custom", "interop");
    database.prepare("UPDATE branch_tips SET tip_id=? WHERE session_id=? AND branch_id=?")
      .run("entry-typescript", "session-fixture", "entry-1");
    database.prepare("UPDATE lanes SET leaf_id=? WHERE session_id=? AND lane='main'")
      .run("entry-typescript", "session-fixture");
    database.exec("COMMIT");
  } catch (error) {
    database.exec("ROLLBACK");
    throw error;
  }
  database.close();
  process.stdout.write(JSON.stringify({ mutated: true }));
} else if (command === "sqlite") {
  const { DatabaseSync } = await import("node:sqlite");
  const database = new DatabaseSync(argument, { readOnly: true });
  const tables = database
    .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    .all()
    .map((row) => row.name);
  const integrity = database.prepare("PRAGMA integrity_check").get().integrity_check;
  const entries = tables.includes("entries")
    ? database.prepare("SELECT count(*) AS count FROM entries").get().count
    : 0;
  database.close();
  process.stdout.write(JSON.stringify({ tables, integrity, entries }));
} else if (command === "serve") {
  const { createUnixServer } = await import(
    pathToFileURL(resolve(root, "packages/server/dist/transports/unix/index.js"))
  );
  const service = {
    async listSessions() { return []; },
    async listModels() { return []; },
    async createSession() { throw new Error("not implemented"); },
    async openSession() { throw new Error("not implemented"); },
  };
  const server = createUnixServer(service, { path: argument, serverId: "typescript-interop" });
  await server.start();
  process.stdout.write("READY\n");
  await new Promise((resolveSignal) => {
    process.once("SIGTERM", resolveSignal);
    process.once("SIGINT", resolveSignal);
  });
  await server.close();
} else if (command === "client") {
  const { PiClient } = await import(pathToFileURL(resolve(root, "packages/client/dist/index.js")));
  const { createUnixTransportFactory } = await import(
    pathToFileURL(resolve(root, "packages/client/dist/unix.js"))
  );
  const client = new PiClient({
    transportFactory: createUnixTransportFactory({ path: argument }),
  });
  await client.connect();
  const initial = await client.listSessions();
  const session = await client.createSession({ cwd: "/interop" });
  const snapshot = await session.prompt("hello from TypeScript");
  await session.detach();
  const sessions = await client.listSessions();
  process.stdout.write(JSON.stringify({
    initialSessions: initial.length,
    sessions: sessions.length,
    transcript: snapshot.transcript.length,
    attached: snapshot.attached,
  }));
  await client.dispose();
} else {
  throw new Error(`unknown command: ${command}`);
}
