import { hasRedis } from "./_store.js";
export default function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  res.status(200).json({ ok: true, service: "STRDM Live Cloud", sharedStorage: hasRedis, media: Boolean(process.env.BLOB_READ_WRITE_TOKEN), now: Date.now() });
}
