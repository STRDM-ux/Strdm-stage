// STRDM Stage on the Mac pushes the crowd state here (secret room key required).
import { set, authorise, cleanRoom, readBody, phones, SAMPLE, hasRedis } from "./_store.js";

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  const room = cleanRoom(req.query.room);
  if (!(await authorise(room, req.headers["x-room-key"]))) return res.status(403).json({ error: "room key mismatch" });
  let body;
  try { body = (await readBody(req, 64_000)).toString("utf8"); JSON.parse(body); }
  catch { return res.status(400).json({ error: "bad state" }); }
  await set(`room:${room}:state`, body, 6 * 3600);
  res.status(200).json({ ok: true, phones: (await phones(room)) * SAMPLE, shared: hasRedis, now: Date.now() });
}
