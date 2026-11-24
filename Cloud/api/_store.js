// Shared storage: Upstash Redis (REST) when connected, otherwise in-memory (single instance — fine for testing).
import crypto from "node:crypto";

const URL_ = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
const TOKEN = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;
const mem = globalThis.__strdmMem || (globalThis.__strdmMem = new Map());

export const hasRedis = Boolean(URL_ && TOKEN);

async function redis(cmd) {
  const r = await fetch(URL_, {
    method: "POST",
    headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify(cmd),
  });
  const j = await r.json();
  if (j.error) throw new Error(j.error);
  return j.result;
}

export async function get(key) {
  if (hasRedis) return redis(["GET", key]);
  const v = mem.get(key);
  return v && (!v.exp || v.exp > Date.now()) ? v.val : null;
}

export async function set(key, val, ttlSec, nx = false) {
  if (hasRedis) {
    const cmd = ["SET", key, val, "EX", String(ttlSec)];
    if (nx) cmd.push("NX");
    return redis(cmd);
  }
  if (nx && (await get(key)) != null) return null;
  mem.set(key, { val, exp: Date.now() + ttlSec * 1000 });
  return "OK";
}

export async function seen(room, id) {
  const now = Date.now();
  const key = `room:${room}:phones`;
  if (hasRedis) {
    await redis(["ZADD", key, String(now), id]);
    await redis(["ZREMRANGEBYSCORE", key, "0", String(now - 75000)]);
    await redis(["EXPIRE", key, "3600"]);
    return;
  }
  const z = mem.get(key)?.val || new Map();
  z.set(id, now);
  for (const [k, t] of z) if (t < now - 75000) z.delete(k);
  mem.set(key, { val: z, exp: now + 3600000 });
}

export async function phones(room) {
  const key = `room:${room}:phones`;
  if (hasRedis) {
    await redis(["ZREMRANGEBYSCORE", key, "0", String(Date.now() - 75000)]);
    return Number(await redis(["ZCARD", key])) || 0;
  }
  return mem.get(key)?.val?.size || 0;
}

export const SAMPLE = 5; // 1 in 5 phones reports presence; counts are scaled up

export function cleanRoom(r) {
  return String(r || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 12);
}

export function hash(s) {
  return crypto.createHash("sha256").update(String(s)).digest("hex");
}

/// The Mac that first pushes to a room owns it (by its secret key) for 30 days.
export async function authorise(room, key) {
  if (!room || !key || key.length < 16) return false;
  const k = `room:${room}:owner`;
  const h = hash(key);
  await set(k, h, 30 * 86400, true);
  return (await get(k)) === h;
}

export async function readBody(req, limit = 4_400_000) {
  const chunks = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > limit) throw Object.assign(new Error("too large"), { status: 413 });
    chunks.push(c);
  }
  return Buffer.concat(chunks);
}
