// 3D client pitch links: STRDM Stage uploads a stage design, anyone with the link can orbit it in a browser.
import { put, head } from "@vercel/blob";
import { readBody } from "./_store.js";
import crypto from "node:crypto";

export default async function handler(req, res) {
  if (req.method === "POST") {
    res.setHeader("Cache-Control", "no-store");
    if (!process.env.BLOB_READ_WRITE_TOKEN) return res.status(503).json({ error: "Blob storage not connected" });
    let body;
    try { body = (await readBody(req, 2_000_000)).toString("utf8"); JSON.parse(body); }
    catch { return res.status(400).json({ error: "bad design" }); }
    const id = crypto.randomBytes(5).toString("hex");
    await put(`pitch/${id}.json`, body, { access: "public", addRandomSuffix: false, contentType: "application/json" });
    const host = `https://${req.headers.host}`;
    return res.status(200).json({ id, url: `${host}/p/${id}` });
  }
  const id = String(req.query.id || "").replace(/[^a-f0-9]/g, "");
  if (!id) return res.status(400).json({ error: "id required" });
  try {
    const meta = await head(`pitch/${id}.json`);
    const r = await fetch(meta.url);
    res.setHeader("Cache-Control", "public, s-maxage=300");
    res.setHeader("Content-Type", "application/json");
    return res.status(200).send(await r.text());
  } catch {
    return res.status(404).json({ error: "not found" });
  }
}
