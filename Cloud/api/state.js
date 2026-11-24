// Phones poll this. The CDN caches each room's state for 1 s, so thousands of phones cost ~1 function call per second.
import { get, cleanRoom } from "./_store.js";

export default async function handler(req, res) {
  const room = cleanRoom(req.query.room);
  res.setHeader("Access-Control-Allow-Origin", "*");
  if (!room) return res.status(400).json({ error: "room required" });
  const s = await get(`room:${room}:state`);
  res.setHeader("Cache-Control", "public, max-age=0, s-maxage=1, stale-while-revalidate=2");
  res.setHeader("Content-Type", "application/json");
  res.status(200).send(s || JSON.stringify({ mode: "off", waiting: true }));
}
