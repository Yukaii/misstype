// Cloud sync accounts: Dropbox and Google Drive, talked to straight from the
// browser (no server of ours in between). Off until the user connects one.
//
// - Dropbox: an "App folder" app (Apps/<app name>/), OAuth code flow with
//   PKCE and a refresh token, so sync keeps working without signing in again.
// - Google Drive: the `drive.file` scope (only files this app created, in a
//   "Misstype" folder), OAuth token flow: Google gives a browser-only app no
//   refresh token, so after about an hour sync asks to connect again.
//
// Sign-in opens a popup (a full-page redirect if it is blocked) on
// oauth.html, which hands the answer back through localStorage. The app key
// and client ID are public and come from the build (VITE_DROPBOX_APP_KEY,
// VITE_GOOGLE_CLIENT_ID); a provider without one is not offered. sync.js does
// the merging; this file only moves files.
import { syncNotes } from "./sync.js";
import { applyEntries, emptyListing, filesOf, forget, remember, storedListing } from "./dropbox-list.js";

const STATE_KEY = "misstype-editor-sync";
export const PENDING_KEY = "misstype-oauth-pending";
export const RESULT_KEY = "misstype-oauth-result";

// Vite replaces import.meta.env at build time; under Node (tests) it is absent.
const env = import.meta.env || {};
const DROPBOX_KEY = env.VITE_DROPBOX_APP_KEY || "";
const GOOGLE_ID = env.VITE_GOOGLE_CLIENT_ID || "";

export const PROVIDERS = {
  dropbox: { name: "Dropbox", configured: Boolean(DROPBOX_KEY) },
  gdrive: { name: "Google Drive", configured: Boolean(GOOGLE_ID) },
};

const redirectUri = () => new URL("oauth.html", location.href).href.replace(/[?#].*$/, "");

const random = (bytes = 32) => {
  const a = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...a)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
async function challenge(verifier) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  return btoa(String.fromCharCode(...digest)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const readJson = (key) => {
  try { return JSON.parse(localStorage.getItem(key) || "null"); } catch { return null; }
};
const writeJson = (key, value) => {
  try {
    if (value == null) localStorage.removeItem(key);
    else localStorage.setItem(key, JSON.stringify(value));
  } catch { /* private mode */ }
};

export class AuthError extends Error {}

const conflict = (message) => Object.assign(new Error(message), { conflict: true });

async function check(res, what) {
  if (res.ok) return res;
  if (res.status === 401) throw new AuthError(`${what}: signed out`);
  const text = await res.text().catch(() => "");
  if (res.status === 409 && /conflict/.test(text)) throw conflict(`${what}: ${text}`);
  throw new Error(`${what}: ${res.status} ${text.slice(0, 200)}`);
}

// ------------------------------------------------------------------ Dropbox

// Dropbox-API-Arg is an HTTP header, so non-ASCII must be escaped.
const headerJson = (value) => JSON.stringify(value).replace(/[\u007f-￿]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`);

/** The Dropbox remote for sync.js. Exported for tests/editor_dropbox_list_test.mjs. */
export function dropbox(account, saveAccount) {
  async function token() {
    if (account.access && account.expires > Date.now() + 60_000) return account.access;
    const res = await fetch("https://api.dropboxapi.com/oauth2/token", {
      method: "POST",
      body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: account.refresh, client_id: DROPBOX_KEY }),
    });
    if (res.status === 400 || res.status === 401) throw new AuthError("dropbox: refresh refused");
    await check(res, "dropbox token");
    const json = await res.json();
    Object.assign(account, { access: json.access_token, expires: Date.now() + json.expires_in * 1000 });
    saveAccount();
    return account.access;
  }
  const rpc = async (path, body) => {
    const res = await check(await fetch(`https://api.dropboxapi.com/2/${path}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${await token()}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }), `dropbox ${path}`);
    return res.json();
  };
  // The listing kept with the account (dropbox-list.js). It is saved with the
  // rest of the sync state at the end of a pass, never halfway: a pass that
  // fails just continues from the old cursor next time.
  let listing = storedListing(account.listing);
  return {
    /** Whether the last list() found anything this device did not already know. */
    changed: true,
    async list() {
      let next = null;
      let page = null;
      if (listing) {
        next = { cursor: listing.cursor, files: { ...listing.files } };
        try {
          page = await rpc("files/list_folder/continue", { cursor: listing.cursor });
        } catch (err) {
          // An expired or reset cursor: list everything again.
          if (!/reset/.test(err.message)) throw err;
          page = null;
        }
      }
      let changed = !page;
      if (!page) {
        next = emptyListing();
        page = await rpc("files/list_folder", { path: "", recursive: true });
      }
      for (;;) {
        if (applyEntries(next, page.entries)) changed = true;
        if (!page.has_more) break;
        page = await rpc("files/list_folder/continue", { cursor: page.cursor });
      }
      next.cursor = page.cursor;
      listing = next;
      account.listing = listing;
      this.changed = changed;
      return filesOf(listing);
    },
    async read(name) {
      const res = await check(await fetch("https://content.dropboxapi.com/2/files/download", {
        method: "POST",
        headers: { Authorization: `Bearer ${await token()}`, "Dropbox-API-Arg": headerJson({ path: `/${name}` }) },
      }), "dropbox download");
      return res.text();
    },
    // Dropbox has no multi-download endpoint.  Keeping the fan-out here lets
    // the sync layer fetch independent files concurrently without coupling it
    // to a provider-specific API.
    async readMany(names) {
      const out = new Map();
      // Keep enough parallelism to hide WAN latency without creating a burst
      // large enough to trip Dropbox's per-user request limits.
      for (let i = 0; i < names.length; i += 8) {
        const batch = names.slice(i, i + 8);
        for (const [name, text] of await Promise.all(batch.map(async (name) => [name, await this.read(name)]))) {
          out.set(name, text);
        }
      }
      return out;
    },
    async write(name, text, rev) {
      const mode = rev ? { ".tag": "update", update: rev } : { ".tag": "add" };
      const res = await check(await fetch("https://content.dropboxapi.com/2/files/upload", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${await token()}`,
          "Content-Type": "application/octet-stream",
          "Dropbox-API-Arg": headerJson({ path: `/${name}`, mode, autorename: false, mute: true }),
        },
        body: new TextEncoder().encode(text),
      }), "dropbox upload");
      const { rev: written } = await res.json();
      // The next continue reports this write; known, it is not a remote change.
      remember(listing, name, written);
      return written;
    },
    async remove(name) {
      try {
        await rpc("files/delete_v2", { path: `/${name}` });
      } catch (err) {
        if (!/not_found/.test(err.message)) throw err;
      }
      forget(listing, name);
    },
    /**
     * Waits (up to `timeout` s) for a change after the stored cursor. No token:
     * the notify endpoint takes none. Resolves { changes, backoff }.
     */
    async waitForChange(timeout, signal) {
      if (!listing) return { changes: true, backoff: 0 };
      const res = await fetch("https://notify.dropboxapi.com/2/files/list_folder/longpoll", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cursor: listing.cursor, timeout }),
        signal,
      });
      if (!res.ok) throw new Error(`dropbox longpoll: ${res.status}`);
      const json = await res.json();
      return { changes: Boolean(json.changes), backoff: Number(json.backoff) || 0 };
    },
  };
}

// ------------------------------------------------------------- Google Drive

const FOLDER_TYPE = "application/vnd.google-apps.folder";
const DRIVE = "https://www.googleapis.com/drive/v3/files";
const DRIVE_UPLOAD = "https://www.googleapis.com/upload/drive/v3/files";

function gdrive(account, saveAccount) {
  const auth = () => {
    if (!account.access || account.expires < Date.now() + 30_000) throw new AuthError("gdrive: token expired");
    return { Authorization: `Bearer ${account.access}` };
  };
  const call = async (url, init = {}) => check(await fetch(url, { ...init, headers: { ...auth(), ...init.headers } }), "gdrive");
  const query = async (q, fields = "id,name,version") => {
    const out = [];
    let pageToken = "";
    do {
      const params = new URLSearchParams({ q, fields: `nextPageToken,files(${fields})`, pageSize: "1000", orderBy: "createdTime", spaces: "drive" });
      if (pageToken) params.set("pageToken", pageToken);
      const page = await (await call(`${DRIVE}?${params}`)).json();
      out.push(...page.files);
      pageToken = page.nextPageToken;
    } while (pageToken);
    return out;
  };
  async function folder(name, parent) {
    const [found] = await query(`name = '${name}' and mimeType = '${FOLDER_TYPE}' and '${parent}' in parents and trashed = false`, "id");
    if (found) return found.id;
    const res = await call(`${DRIVE}?fields=id`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, mimeType: FOLDER_TYPE, parents: [parent] }),
    });
    return (await res.json()).id;
  }
  // name ("notes/x.md", "folders.json") -> file id, from the last list().
  const ids = new Map();
  async function dirs() {
    if (!account.root) {
      account.root = await folder("Misstype", "root");
      account.notesDir = await folder("notes", account.root);
      saveAccount();
    }
    return account;
  }
  return {
    async list() {
      const { root, notesDir } = await dirs();
      const files = await query(`('${root}' in parents or '${notesDir}' in parents) and mimeType != '${FOLDER_TYPE}' and trashed = false`,
        "id,name,version,parents");
      ids.clear();
      const out = [];
      for (const f of files) {
        const name = f.parents?.includes(notesDir) ? `notes/${f.name}` : f.name;
        if (ids.has(name)) continue; // a duplicate from two devices racing; the oldest wins
        ids.set(name, f.id);
        out.push({ name, rev: String(f.version) });
      }
      return out;
    },
    async read(name) {
      return (await call(`${DRIVE}/${ids.get(name)}?alt=media`)).text();
    },
    // Drive has no conditional write: `rev` is not checked here (see docs/editor.md).
    async write(name, text) {
      const id = ids.get(name);
      if (id) {
        const res = await call(`${DRIVE_UPLOAD}/${id}?uploadType=media&fields=version`, {
          method: "PATCH", headers: { "Content-Type": "text/markdown; charset=utf-8" }, body: text,
        });
        return String((await res.json()).version);
      }
      const { root, notesDir } = await dirs();
      const notes = name.startsWith("notes/");
      const boundary = `misstype${random(12)}`;
      const meta = { name: notes ? name.slice(6) : name, parents: [notes ? notesDir : root] };
      const body = `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${JSON.stringify(meta)}\r\n`
        + `--${boundary}\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n${text}\r\n--${boundary}--`;
      const res = await call(`${DRIVE_UPLOAD}?uploadType=multipart&fields=id,version`, {
        method: "POST", headers: { "Content-Type": `multipart/related; boundary=${boundary}` }, body,
      });
      const json = await res.json();
      ids.set(name, json.id);
      return String(json.version);
    },
    // Trashed, not deleted: Drive keeps it for 30 days.
    async remove(name) {
      const id = ids.get(name);
      if (!id) return;
      await call(`${DRIVE}/${id}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ trashed: true }) });
      ids.delete(name);
    },
  };
}

// ------------------------------------------------------------------ sign-in

/** Opens the provider's sign-in. Call from a click so the popup is allowed. */
export async function connect(provider) {
  // Opened before any await, while the click still counts as a user gesture.
  const popup = window.open("", "misstype-oauth", "popup,width=520,height=680");
  const state = random(16);
  const pending = { provider, state, at: Date.now() };
  let url;
  if (provider === "dropbox") {
    pending.verifier = random(48);
    url = `https://www.dropbox.com/oauth2/authorize?${new URLSearchParams({
      client_id: DROPBOX_KEY,
      response_type: "code",
      redirect_uri: redirectUri(),
      code_challenge: await challenge(pending.verifier),
      code_challenge_method: "S256",
      token_access_type: "offline",
      state,
    })}`;
  } else {
    url = `https://accounts.google.com/o/oauth2/v2/auth?${new URLSearchParams({
      client_id: GOOGLE_ID,
      response_type: "token",
      redirect_uri: redirectUri(),
      scope: "https://www.googleapis.com/auth/drive.file",
      include_granted_scopes: "true",
      state,
    })}`;
  }
  pending.popup = Boolean(popup);
  writeJson(PENDING_KEY, pending);
  if (popup) popup.location.href = url;
  else location.assign(url);
}

/** The answer oauth.html left, as a connected account, or null. Throws if sign-in failed. */
async function takeAuthResult() {
  const result = readJson(RESULT_KEY);
  if (!result) return null;
  writeJson(RESULT_KEY, null);
  const pending = readJson(PENDING_KEY);
  writeJson(PENDING_KEY, null);
  if (!pending || result.state !== pending.state || Date.now() - pending.at > 15 * 60_000) return null;
  if (result.error) throw new Error(result.error_description || result.error);
  if (pending.provider === "dropbox") {
    const res = await check(await fetch("https://api.dropboxapi.com/oauth2/token", {
      method: "POST",
      body: new URLSearchParams({
        grant_type: "authorization_code",
        code: result.code,
        client_id: DROPBOX_KEY,
        redirect_uri: redirectUri(),
        code_verifier: pending.verifier,
      }),
    }), "dropbox sign-in");
    const json = await res.json();
    return { provider: "dropbox", id: json.account_id, refresh: json.refresh_token, access: json.access_token, expires: Date.now() + json.expires_in * 1000 };
  }
  // Which Google account, so signing in to another one starts over instead of reusing the sync state.
  const about = await check(await fetch("https://www.googleapis.com/drive/v3/about?fields=user(permissionId)", {
    headers: { Authorization: `Bearer ${result.access_token}` },
  }), "gdrive sign-in");
  const { user } = await about.json();
  return { provider: "gdrive", id: user.permissionId, access: result.access_token, expires: Date.now() + Number(result.expires_in || 3600) * 1000 };
}

// ------------------------------------------------------------------ session

/**
 * The connected account and its sync state, kept in localStorage (the
 * Dropbox refresh token too, next to the notes it unlocks).
 * `onChange(status)` hears every change: { provider, busy, error, needsSignIn, last, report }.
 */
export function createCloud({ notes, workspace, content, busy, onChange }) {
  const status = { provider: null, busy: false, error: "", needsSignIn: false, last: 0, report: null };
  const load = () => readJson(STATE_KEY);
  const publish = () => {
    const state = load();
    status.provider = state?.account?.provider ?? null;
    status.last = state?.last ?? 0;
    onChange({ ...status });
  };

  async function run() {
    const state = load();
    if (!state?.account) return null;
    const save = () => writeJson(STATE_KEY, state);
    const remote = (state.account.provider === "dropbox" ? dropbox : gdrive)(state.account, save);
    const { base, report } = await syncNotes({ store: notes, remote, base: state.base, busy, workspace, content });
    // Disconnected (or switched account) while this pass ran: drop it.
    if (load()?.account?.connected !== state.account.connected) return null;
    Object.assign(state, { base, last: Date.now() });
    save();
    return report;
  }

  let running = null;
  /** One pass; tabs take turns (Web Locks) so two never upload the same note. Resolves to the report or null. */
  function sync() {
    if (!load()?.account) return Promise.resolve(null);
    if (running) return running;
    status.busy = true;
    status.error = "";
    publish();
    running = locked(run).then((report) => {
      status.needsSignIn = false;
      status.report = report;
      return report;
    }, (err) => {
      console.warn("sync failed", err);
      status.needsSignIn = err instanceof AuthError;
      status.error = status.needsSignIn ? "需要重新登入" : navigator.onLine === false ? "離線中" : "同步失敗";
      return null;
    }).finally(() => {
      running = null;
      status.busy = false;
      publish();
    });
    return running;
  }

  const locked = (fn) => (navigator.locks ? navigator.locks.request("misstype-sync", fn) : fn());

  /**
   * Lists the remote (Dropbox: only what changed since the stored cursor) and
   * says whether anything is new to this device. Its own uploads are not.
   * Shows nothing; a sync follows only when this returns true.
   */
  async function peekRun() {
    const state = load();
    if (state?.account?.provider !== "dropbox") return true;
    const remote = dropbox(state.account, () => writeJson(STATE_KEY, state));
    await remote.list();
    if (load()?.account?.connected !== state.account.connected) return false;
    writeJson(STATE_KEY, state);
    return remote.changed;
  }
  const peek = () => locked(peekRun).catch(() => true);

  // Dropbox longpoll: hear another device's change within seconds instead of
  // at the next 2-minute pass. One loop at a time; `generation` retires a
  // stopped loop that is still waiting or sleeping.
  let generation = 0;
  let abort = null;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  function watch(onRemoteChange) {
    if (abort) return;
    const mine = ++generation;
    const controller = new AbortController();
    abort = controller;
    const done = () => { if (generation === mine) abort = null; };
    (async () => {
      while (generation === mine) {
        const state = load();
        if (state?.account?.provider !== "dropbox" || !storedListing(state.account.listing) || status.needsSignIn) break;
        let result;
        try {
          result = await dropbox(state.account, () => {}).waitForChange(120, controller.signal);
        } catch {
          if (generation !== mine) break;
          await sleep(60_000);
          continue;
        }
        if (generation !== mine) break;
        if (result.changes && await peek() && generation === mine) onRemoteChange();
        if (result.backoff) await sleep(result.backoff * 1000);
      }
      done();
    })();
  }
  function unwatch() {
    generation++;
    abort?.abort();
    abort = null;
  }

  return {
    get provider() { return load()?.account?.provider ?? null; },
    get status() { return { ...status }; },
    connect,
    /** Finishes a sign-in oauth.html reported; true when an account was connected. */
    async finish() {
      let account;
      try {
        // Every open tab hears the answer; only one may spend the one-time code.
        account = await (navigator.locks ? navigator.locks.request("misstype-oauth", takeAuthResult) : takeAuthResult());
      } catch (err) {
        status.error = `連結失敗：${err.message}`;
        publish();
        return false;
      }
      if (!account) return false;
      account.connected = Date.now();
      const old = load();
      // Signing in again to the same account keeps what was synced; another account starts over.
      const keep = old?.account?.provider === account.provider && old.account.id === account.id;
      if (keep && account.provider === "gdrive") Object.assign(account, { root: old.account.root, notesDir: old.account.notesDir });
      writeJson(STATE_KEY, { account, base: keep ? old.base : {}, last: keep ? old.last : 0 });
      status.needsSignIn = false;
      status.error = "";
      publish();
      return true;
    },
    disconnect() {
      unwatch();
      writeJson(STATE_KEY, null);
      Object.assign(status, { error: "", needsSignIn: false, report: null });
      publish();
    },
    sync,
    publish,
    /** Starts listening for remote changes (Dropbox; no-op elsewhere or if already listening). */
    watch,
    unwatch,
  };
}
