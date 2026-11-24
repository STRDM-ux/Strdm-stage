// Sampled phone presence (only some phones report, every 30 s).
import { seen, cleanRoom } from "./_store.js";

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  const room = cleanRoom(req.query.room);
  const id = String(req.query.id || "").slice(0, 40);
  if (room && id) await seen(room, id);
  res.status(204).end();
}
