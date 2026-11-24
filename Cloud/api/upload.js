// Crowd images / short videos from the Mac → Vercel Blob (public CDN URLs for every phone). Max ~4.4 MB per file.
import { put } from "@vercel/blob";
import { authorise, cleanRoom, readBody } from "./_store.js";

export const config = { api: { bodyParser: false } };

const TYPES = { jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", gif: "image/gif", webp: "image/webp",
                mp4: "video/mp4", m4v: "video/mp4", mov: "video/quicktime", webm: "video/webm" };

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  const room = cleanRoom(req.query.room);
  if (!(await authorise(room, req.headers["x-room-key"]))) return res.status(403).json({ error: "room key mismatch" });
  if (!process.env.BLOB_READ_WRITE_TOKEN) return res.status(503).json({ error: "Blob storage not connected" });
  const name = String(req.query.name || "media.jpg").replace(/[^A-Za-z0-9._-]/g, "_").slice(-60);
  const ext = name.split(".").pop().toLowerCase();
  let data;
  try { data = await readBody(req); } catch (e) { return res.status(e.status || 400).json({ error: e.message }); }
  const blob = await put(`rooms/${room}/${name}`, data, { access: "public", addRandomSuffix: true, contentType: TYPES[ext] || "application/octet-stream" });
  res.status(200).json({ url: blob.url });
}
