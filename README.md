// Cloudflare Worker — وسيط آمن بين التطبيق و Gemini
// المفتاح يُحفظ كسر (Secret) باسم GEMINI_API_KEY ولا يظهر في التطبيق أبداً.

const FIREBASE_KEY = "AIzaSyBk_hr_RSYRjTQww2KPwQcq42V1NzU7uH4"; // مفتاح الويب العام لمشروعك (موجود أصلاً في التطبيق)
const MODELS = ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite", "gemini-3-flash-preview"];
const DEFAULT_MODEL = "gemini-2.5-flash";
const LIMIT_PER_MIN = 20;                 // الحد الأقصى للرسائل لكل مستخدم في الدقيقة
const hits = new Map();

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};
const json = (o, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

export default {
  async fetch(req, env) {
    if (req.method === "OPTIONS") return new Response(null, { headers: cors });
    if (req.method !== "POST") return json({ error: "POST only" }, 405);
    if (!env.GEMINI_API_KEY) return json({ error: "missing GEMINI_API_KEY" }, 500);

    let b;
    try { b = await req.json(); } catch { return json({ error: "bad json" }, 400); }

    // التحقق من أن الطلب من مستخدم مسجّل في تطبيقك
    const v = await fetch(
      "https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=" + FIREBASE_KEY,
      { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ idToken: b.idToken || "" }) }
    );
    if (!v.ok) return json({ error: "unauthorized" }, 401);
    const uid = ((await v.json()).users || [])[0]?.localId;
    if (!uid) return json({ error: "unauthorized" }, 401);

    // حد معدّل بسيط ضد الإساءة
    const now = Date.now();
    const arr = (hits.get(uid) || []).filter((t) => now - t < 60000);
    if (arr.length >= LIMIT_PER_MIN) return json({ error: "rate limit" }, 429);
    arr.push(now); hits.set(uid, arr);

    // تجهيز المحادثة
    const msgs = (Array.isArray(b.messages) ? b.messages : []).slice(-30).map((m) => ({
      role: m.role === "model" ? "model" : "user",
      parts: [{ text: String(m.text || "").slice(0, 4000) }],
    }));
    if (!msgs.length) return json({ error: "no messages" }, 400);

    let system = String(b.system || "").slice(0, 4000);
    if (b.voice) system += "\nالرد سيُقرأ صوتياً: اجعله من جملة إلى ثلاث جمل قصيرة وطبيعية.";
    const model = MODELS.includes(b.model) ? b.model : DEFAULT_MODEL;
    const temperature = Math.min(1.5, Math.max(0, Number(b.temperature ?? 0.8)));

    const body = {
      contents: msgs,
      generationConfig: { temperature, maxOutputTokens: 2048 },
    };
    if (system.trim()) body.systemInstruction = { parts: [{ text: system }] };

    const r = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
      { method: "POST", headers: { "Content-Type": "application/json", "x-goog-api-key": env.GEMINI_API_KEY }, body: JSON.stringify(body) }
    );
    const d = await r.json().catch(() => ({}));
    if (!r.ok) return json({ error: "gemini", detail: d.error?.message || r.status }, 502);

    const text = (d.candidates?.[0]?.content?.parts || []).map((p) => p.text || "").join("").trim();
    return json({ text });
  },
};
