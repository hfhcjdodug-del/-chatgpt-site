// ============================================================
// supa-shim.js  —  Firebase-style API on top of Supabase
// يحافظ على نفس أسماء دوال Firebase (doc, onSnapshot, setDoc ...) حتى
// يعمل الموقع ولوحة التحكم بدون إعادة كتابة كاملة.
// ============================================================
import {createClient} from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

export const SUPABASE_URL = "https://deqgwromjujrxunjvmuz.supabase.co";
// مفتاح عام (publishable) آمن للمتصفح — الحماية عبر سياسات RLS في قاعدة البيانات
export const SUPABASE_KEY = "sb_publishable_i4FV3xGkbSxcXk9Givr60A_GzKrA8yS";

let sb = null;
const ensure = () => { if (!sb) initializeApp({}, "default"); return sb; };

// ---------------- app ----------------
export function initializeApp(_cfg, name) {
  if (!sb) {
    sb = createClient(SUPABASE_URL, SUPABASE_KEY, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
        storageKey: "sb-" + (name || "default") + "-auth"
      }
    });
  }
  return {};
}

// ---------------- auth ----------------
const auth = {currentUser: null};
function wrapUser(u) {
  if (!u) return null;
  const md = u.user_metadata || {};
  let prov = (u.app_metadata && u.app_metadata.provider) || "email";
  if (u.is_anonymous) prov = "anonymous";
  return {
    uid: u.id,
    email: u.email || null,
    displayName: md.full_name || md.name || null,
    photoURL: md.avatar_url || md.picture || null,
    isAnonymous: !!u.is_anonymous,
    providerData: u.is_anonymous ? [] : [{providerId: prov === "email" ? "password" : prov === "google" ? "google.com" : prov}],
    getIdToken: async (force) => {
      if (force) { const r = await ensure().auth.refreshSession(); return r.data.session ? r.data.session.access_token : null; }
      const {data} = await ensure().auth.getSession();
      return data.session ? data.session.access_token : null;
    }
  };
}
export function getAuth() { return auth; }
export function initializeAuth() { return auth; }
export const browserLocalPersistence = {}, browserSessionPersistence = {}, inMemoryPersistence = {}, browserPopupRedirectResolver = {};
export class GoogleAuthProvider {}
const authErr = (e) => {
  const err = new Error(e.message || String(e));
  err.code = e.code === "invalid_credentials" ? "auth/invalid-credential"
    : e.code === "provider_disabled" || e.code === "anonymous_provider_disabled" ? "auth/operation-not-allowed"
    : (e.code || e.name || "auth/error");
  return err;
};
async function oauth(provider) {
  const {error} = await ensure().auth.signInWithOAuth({
    provider: "google",
    options: {redirectTo: location.origin + location.pathname}
  });
  if (error) throw authErr(error);
}
export const signInWithPopup = (a, p) => oauth(p);
export const signInWithRedirect = (a, p) => oauth(p);
export async function signInAnonymously() {
  const {error} = await ensure().auth.signInAnonymously();
  if (error) throw authErr(error);
}
export async function signInWithEmailAndPassword(a, email, password) {
  const {error} = await ensure().auth.signInWithPassword({email, password});
  if (error) throw authErr(error);
}
export async function signOut() { await ensure().auth.signOut(); }
export function onAuthStateChanged(a, cb) {
  let lastUid;       // undefined = لم يُستدعَ بعد
  const {data} = ensure().auth.onAuthStateChange((ev, session) => {
    auth.currentUser = wrapUser(session && session.user);
    const id = auth.currentUser ? auth.currentUser.uid : null;
    if (ev !== "INITIAL_SESSION" && id === lastUid) return; // تجاهل تجديد التوكن
    lastUid = id;
    const u = auth.currentUser;
    setTimeout(() => cb(u), 0); // خارج callback المكتبة لتفادي التعليق
  });
  return () => data.subscription.unsubscribe();
}

// ---------------- sentinels ----------------
const TS = {__ts: true};
export const serverTimestamp = () => TS;
export const increment = (n) => ({__inc: n});
export const getFirestore = () => ({});

// ---------------- path -> table ----------------
const snake = (k) => k.replace(/[A-Z]/g, (c) => "_" + c.toLowerCase());
const camel = (k) => k.replace(/_([a-z])/g, (_, c) => c.toUpperCase());
const CALLS_COLS = ["status","cid","name","offer","answer","admin_offer","admin_answer","join_cid","video_req","video_declined","video_offer","video_answer","video_cid","video_status","created_at"];

function parse(p) {
  const [a, b, c, d, e, f] = p;
  if (a === "users") {
    if (p.length === 1) return {t: "profiles", kind: "col", idCol: "id"};
    if (p.length === 2) return {t: "profiles", kind: "doc", idCol: "id", id: b};
    if (c === "conversations") {
      if (p.length === 3) return {t: "conversations", kind: "col", idCol: "id", filter: ["user_id", b], extra: {user_id: b}};
      if (p.length === 4) return {t: "conversations", kind: "doc", idCol: "id", id: d, extra: {user_id: b}};
      if (e === "messages") {
        if (p.length === 5) return {t: "messages", kind: "col", idCol: "id", filter: ["conv_id", d], extra: {user_id: b, conv_id: d}};
        if (p.length === 6) return {t: "messages", kind: "doc", idCol: "id", id: f, extra: {user_id: b, conv_id: d}};
      }
    }
  }
  if (a === "replies") return p.length === 1 ? {t: "replies", kind: "col", idCol: "id"} : {t: "replies", kind: "doc", idCol: "id", id: b};
  if (a === "settings") return p.length === 1 ? {t: "settings", kind: "col", idCol: "id"} : {t: "settings", kind: "doc", idCol: "id", id: b};
  if (a === "calls") {
    if (p.length === 1) return {t: "calls", kind: "col", idCol: "user_id"};
    if (p.length === 2) return {t: "calls", kind: "doc", idCol: "user_id", id: b};
    if (c === "cand") return {t: "call_candidates", kind: "col", idCol: "id", filter: ["user_id", b], extra: {user_id: b}};
  }
  throw new Error("supa-shim: unsupported path /" + p.join("/"));
}

const mk = (type, segs) => ({type, path: segs, d: parse(segs)});
export const collection = (db, ...segs) => mk("col", segs);
export function doc(x, ...segs) {
  if (x && x.type === "col") {
    // doc(collectionRef) → مرجع جديد بمعرّف مولّد
    return mk("doc", [...x.path, crypto.randomUUID()]);
  }
  return mk("doc", segs);
}
export const orderBy = (field, dir) => ({__ord: true, field, dir});
export function query(colRef, ...cs) {
  const o = cs.find((c) => c && c.__ord);
  return {...colRef, order: o ? {col: snake(o.field), asc: o.dir !== "desc"} : null};
}

// ---------------- row <-> data ----------------
function tsObj(v) {
  if (!v) return null;
  const dt = new Date(v);
  return {toDate: () => dt, toMillis: () => dt.getTime(), seconds: Math.floor(dt.getTime() / 1000)};
}
function toRow(t, obj) {
  if (t === "call_candidates") { const {cid, by, ...rest} = obj; return {cid, by, cand: rest}; }
  const r = {};
  for (const [k, v] of Object.entries(obj)) {
    if (v === TS) continue;
    if (t === "messages" && k === "from") { r.sender = v; continue; }
    r[snake(k)] = v;
  }
  return r;
}
function fromRow(t, row) {
  if (!row) return undefined;
  if (t === "settings") return row.data || {};
  if (t === "call_candidates") return {...(row.cand || {}), cid: row.cid, by: row.by};
  if (t === "messages") {
    const o = {from: row.sender, text: row.text || "", at: tsObj(row.at)};
    if (row.att) o.att = row.att;
    if (row.atts) o.atts = row.atts;
    return o;
  }
  const o = {};
  for (const [k, v] of Object.entries(row)) {
    if (k === "id" || k === "user_id") continue;
    o[camel(k)] = v;
  }
  return o;
}
const snapDoc = (d, row) => ({
  id: row ? row[d.idCol] : d.id,
  exists: () => !!row,
  data: () => fromRow(d.t, row)
});

// ---------------- reads ----------------
async function fetchRow(d) {
  const {data, error} = await ensure().from(d.t).select("*").eq(d.idCol, d.id).maybeSingle();
  if (error) throw error;
  return data;
}
function colSnap(d, rows, changes) {
  const docs = rows.map((r) => snapDoc(d, r));
  return {
    docs, size: docs.length, empty: !docs.length,
    forEach: (fn) => docs.forEach(fn),
    docChanges: () => changes
  };
}
async function fetchCol(ref) {
  const d = ref.d;
  let q = ensure().from(d.t).select("*");
  if (d.filter) q = q.eq(d.filter[0], d.filter[1]);
  if (ref.order) q = q.order(ref.order.col, {ascending: ref.order.asc});
  const {data, error} = await q;
  if (error) throw error;
  return data || [];
}
export async function getDoc(ref) { return snapDoc(ref.d, await fetchRow(ref.d)); }
export async function getDocs(ref) {
  const rows = await fetchCol(ref);
  return colSnap(ref.d, rows, rows.map((r, i) => ({type: "added", doc: snapDoc(ref.d, r), newIndex: i, oldIndex: -1})));
}

// ---------------- writes ----------------
async function resolveInc(d, row) {
  const incs = Object.entries(row).filter(([, v]) => v && typeof v === "object" && v.__inc !== undefined);
  if (!incs.length) return row;
  const cur = (await fetchRow(d)) || {};
  const out = {...row};
  for (const [k, v] of incs) out[k] = (Number(cur[k]) || 0) + v.__inc;
  return out;
}
async function settingsMerge(d, obj, merge) {
  let out = obj;
  if (merge) { const cur = await fetchRow(d); out = {...((cur && cur.data) || {}), ...obj}; }
  const {error} = await ensure().from("settings").upsert({id: d.id, data: out});
  if (error) throw error;
}
export async function setDoc(ref, data, opts) {
  const d = ref.d, merge = !!(opts && opts.merge);
  if (d.t === "settings") return settingsMerge(d, data, merge);
  let row = await resolveInc(d, toRow(d.t, data));
  if (!merge && d.t === "calls") for (const c of CALLS_COLS) if (!(c in row)) row[c] = null;
  row = {...row, ...(d.extra || {}), [d.idCol]: d.id};
  const {error} = await ensure().from(d.t).upsert(row, {onConflict: d.idCol});
  if (error) throw error;
}
export async function updateDoc(ref, data) {
  const d = ref.d;
  if (d.t === "settings") return settingsMerge(d, data, true);
  const row = await resolveInc(d, toRow(d.t, data));
  const {error} = await ensure().from(d.t).update(row).eq(d.idCol, d.id);
  if (error) throw error;
}
export async function addDoc(colRef, data) {
  const d = colRef.d;
  const row = {...toRow(d.t, data), ...(d.extra || {})};
  const {data: out, error} = await ensure().from(d.t).insert(row).select("id").single();
  if (error) throw error;
  return {id: out && out.id};
}
export async function deleteDoc(ref) {
  const {error} = await ensure().from(ref.d.t).delete().eq(ref.d.idCol, ref.d.id);
  if (error) throw error;
}
export function writeBatch() {
  const ops = [];
  return {
    set(ref, data, opts) { ops.push(() => setDoc(ref, data, opts)); return this; },
    update(ref, data) { ops.push(() => updateDoc(ref, data)); return this; },
    delete(ref) { ops.push(() => deleteDoc(ref)); return this; },
    async commit() { for (const op of ops) await op(); }
  };
}

// ---------------- realtime ----------------
let chSeq = 0;
export function onSnapshot(ref, cb, errCb) {
  const d = ref.d;
  const fail = (e) => { try { errCb && errCb(e); } catch (_) {} };
  let alive = true, started = false, buf = [];
  const rows = new Map();
  const cmp = ref.order
    ? (a, b) => { const x = a[ref.order.col], y = b[ref.order.col]; const r = x < y ? -1 : x > y ? 1 : 0; return ref.order.asc ? r : -r; }
    : null;
  const sorted = () => { const a = [...rows.values()]; if (cmp) a.sort(cmp); return a; };

  const emit = (row, change) => {
    if (!alive) return;
    if (d.kind === "doc") { cb(snapDoc(d, row)); return; }
    const arr = sorted();
    const ch = change ? [change] : arr.map((r, i) => ({type: "added", doc: snapDoc(d, r), newIndex: i, oldIndex: -1}));
    cb(colSnap(d, arr, ch));
  };
  const apply = (p) => {
    if (d.kind === "doc") {
      emit(p.eventType === "DELETE" ? null : p.new);
      return;
    }
    const row = p.eventType === "DELETE" ? p.old : p.new;
    const id = row && row[d.idCol];
    if (id === undefined) return;
    if (p.eventType === "DELETE") { const old = rows.get(id) || row; rows.delete(id); emit(null, {type: "removed", doc: snapDoc(d, old)}); }
    else { const had = rows.has(id); rows.set(id, row); emit(null, {type: had ? "modified" : "added", doc: snapDoc(d, row)}); }
  };

  const opts = {event: "*", schema: "public", table: d.t};
  if (d.kind === "doc") opts.filter = d.idCol + "=eq." + d.id;
  else if (d.filter) opts.filter = d.filter[0] + "=eq." + d.filter[1];

  const channel = ensure().channel("snap-" + d.t + "-" + (++chSeq) + "-" + Math.random().toString(36).slice(2, 7))
    .on("postgres_changes", opts, (p) => { if (!started) buf.push(p); else apply(p); })
    .subscribe(async (status) => {
      if (status !== "SUBSCRIBED" || started || !alive) return;
      try {
        if (d.kind === "doc") {
          const row = await fetchRow(d);
          started = true; emit(row);
        } else {
          (await fetchCol(ref)).forEach((r) => rows.set(r[d.idCol], r));
          started = true; emit(null);
        }
        const pending = buf; buf = [];
        pending.forEach(apply);
      } catch (e) { fail(e); }
    });
  return () => { alive = false; try { ensure().removeChannel(channel); } catch (_) {} };
}
