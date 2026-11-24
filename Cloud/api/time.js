// Clock sync for the Mac and every phone (never cached).
export default function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.status(200).json({ now: Date.now() });
}
