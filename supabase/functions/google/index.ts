// Supabase Edge Function: google
// Connects the business Google account (admin only) and stores booking documents in Google Drive.
// The Google secret and the account's refresh token stay on Supabase's servers — never in the website.
//
// Needs these Edge Function secrets (Supabase → Edge Functions → Secrets):
//   GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET
// Google OAuth redirect URI to register:  <SUPABASE_URL>/functions/v1/google
// Deploy with "Verify JWT" OFF (Google's redirect has no Supabase login); every other action
// checks the signed-in user itself.

import { createClient } from 'npm:@supabase/supabase-js@2';

const MASTER_EMAIL = 'evansen.coliving@gmail.com';
const APP_URL = 'https://evanmanuel.github.io/pms-rate-manager/';
const ROOT_FOLDER_NAME = 'ECL Booker Folder';
const SCOPES = ['openid', 'email',
  'https://www.googleapis.com/auth/drive.file',
  'https://www.googleapis.com/auth/gmail.send'];
const MAX_BYTES = 10 * 1024 * 1024;
const ALLOWED_EXT = ['pdf', 'jpg', 'jpeg', 'png', 'heic', 'heif', 'doc', 'docx', 'xls', 'xlsx'];
const CATEGORIES = ['Passport', 'Payment slip', 'Other'];

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const CLIENT_ID = Deno.env.get('GOOGLE_CLIENT_ID') || '';
const CLIENT_SECRET = Deno.env.get('GOOGLE_CLIENT_SECRET') || '';
const REDIRECT_URI = `${SUPABASE_URL}/functions/v1/google`;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Expose-Headers': 'content-disposition, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const fail = (msg: string, status = 400) => json({ error: msg }, status);

const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

/* ── small helpers ─────────────────────────────────────────── */
const enc = new TextEncoder();
const b64url = (buf: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
async function hmac(data: string) {
  const key = await crypto.subtle.importKey('raw', enc.encode(CLIENT_SECRET + SERVICE_KEY), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return b64url(await crypto.subtle.sign('HMAC', key, enc.encode(data)));
}
async function makeState(email: string) {
  const payload = b64url(enc.encode(JSON.stringify({ u: email, t: Date.now() })));
  return `${payload}.${await hmac(payload)}`;
}
async function readState(state: string) {
  const [payload, sig] = (state || '').split('.');
  if (!payload || !sig || sig !== await hmac(payload)) return null;
  const data = JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')));
  if (Date.now() - data.t > 15 * 60 * 1000) return null;   // link valid for 15 minutes
  return data as { u: string; t: number };
}
const backToApp = (params: Record<string, string>) =>
  new Response(null, { status: 302, headers: { Location: `${APP_URL}?${new URLSearchParams(params)}` } });

async function getConnection() {
  const { data } = await db.from('google_connection').select('*').eq('id', 1).maybeSingle();
  return data;
}

async function accessToken(): Promise<string> {
  const conn = await getConnection();
  if (!conn?.refresh_token) throw new Error('Google Drive is not connected. An admin can connect it in Settings.');
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: CLIENT_ID, client_secret: CLIENT_SECRET, refresh_token: conn.refresh_token, grant_type: 'refresh_token' }),
  });
  const t = await r.json();
  if (!r.ok || !t.access_token) {
    if (t.error === 'invalid_grant') throw new Error('The Google connection has expired. An admin needs to reconnect it in Settings.');
    throw new Error('Could not reach Google: ' + (t.error_description || t.error || r.status));
  }
  return t.access_token;
}

async function drive(at: string, path: string, init: RequestInit = {}) {
  const r = await fetch(`https://www.googleapis.com/drive/v3/${path}`, {
    ...init, headers: { Authorization: `Bearer ${at}`, 'Content-Type': 'application/json', ...(init.headers || {}) },
  });
  if (r.status === 404) return null;
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error('Google Drive error: ' + (body?.error?.message || r.status));
  return body;
}
async function folderAlive(at: string, id?: string | null) {
  if (!id) return false;
  const f = await drive(at, `files/${id}?fields=id,trashed`);
  return !!f && !f.trashed;
}
async function createFolder(at: string, name: string, parent?: string) {
  const f = await drive(at, 'files?fields=id', {
    method: 'POST',
    body: JSON.stringify({ name, mimeType: 'application/vnd.google-apps.folder', ...(parent ? { parents: [parent] } : {}) }),
  });
  return f.id as string;
}
async function rootFolder(at: string) {
  const conn = await getConnection();
  if (await folderAlive(at, conn?.root_folder_id)) return conn!.root_folder_id as string;
  const id = await createFolder(at, ROOT_FOLDER_NAME);
  await db.from('google_connection').update({ root_folder_id: id }).eq('id', 1);
  return id;
}
const folderName = (r: { confirmation_number: string; guest_name: string }) =>
  `${r.confirmation_number} - ${(r.guest_name || 'Guest').replace(/[\\/]/g, ' ').trim()}`;

async function bookingFolder(at: string, res: { id: string; confirmation_number: string; guest_name: string }) {
  const { data: row } = await db.from('reservation_drive_folders').select('folder_id').eq('reservation_id', res.id).maybeSingle();
  if (await folderAlive(at, row?.folder_id)) return row!.folder_id as string;
  const id = await createFolder(at, folderName(res), await rootFolder(at));
  await db.from('reservation_drive_folders').upsert({ reservation_id: res.id, folder_id: id });
  return id;
}
async function logHistory(reservationId: string, who: string, action: string, file: string, removed = false) {
  await db.from('reservation_history').insert({
    reservation_id: reservationId, changed_by: who, action,
    changes: { file: removed ? { old: file, new: null } : { old: null, new: file } },
  });
}

/* ── Google redirect after the admin approves access ───────── */
async function handleCallback(url: URL) {
  if (url.searchParams.get('error')) return backToApp({ google: 'error', msg: url.searchParams.get('error')! });
  const st = await readState(url.searchParams.get('state') || '');
  if (!st || st.u !== MASTER_EMAIL) return backToApp({ google: 'error', msg: 'expired_or_invalid_request' });
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ code: url.searchParams.get('code') || '', client_id: CLIENT_ID, client_secret: CLIENT_SECRET, redirect_uri: REDIRECT_URI, grant_type: 'authorization_code' }),
  });
  const t = await r.json();
  if (!r.ok || !t.refresh_token) return backToApp({ google: 'error', msg: t.error_description || t.error || 'no_refresh_token' });
  const info = await (await fetch('https://openidconnect.googleapis.com/v1/userinfo', { headers: { Authorization: `Bearer ${t.access_token}` } })).json();
  const prev = await getConnection();
  await db.from('google_connection').upsert({
    id: 1, email: info.email || null, refresh_token: t.refresh_token, scopes: t.scope || SCOPES.join(' '),
    root_folder_id: prev && prev.email === info.email ? prev.root_folder_id : null,
    connected_at: new Date().toISOString(), connected_by: st.u,
  });
  return backToApp({ google: 'connected' });
}

/* ── Main ──────────────────────────────────────────────────── */
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const url = new URL(req.url);
  try {
    if (req.method === 'GET' && (url.searchParams.has('code') || url.searchParams.has('error'))) return await handleCallback(url);

    // Everything else needs a signed-in PMS user
    const token = (req.headers.get('Authorization') || '').replace('Bearer ', '');
    const { data: { user } } = await db.auth.getUser(token);
    if (!user) return fail('Please sign in again.', 401);
    const who = user.email || 'unknown';
    const isAdmin = user.email === MASTER_EMAIL;

    const isForm = (req.headers.get('content-type') || '').includes('multipart/form-data');
    const form = isForm ? await req.formData() : null;
    const body = isForm ? {} : await req.json().catch(() => ({}));
    const action = String(form ? form.get('action') : body.action || '');

    switch (action) {
      case 'status': {
        const c = await getConnection();
        return json({ configured: !!(CLIENT_ID && CLIENT_SECRET), connected: !!c?.refresh_token, email: c?.email || null,
                      connected_at: c?.connected_at || null, can_manage: isAdmin });
      }
      case 'auth-url': {
        if (!isAdmin) return fail('Only the administrator can connect Google.', 403);
        if (!CLIENT_ID || !CLIENT_SECRET) return fail('Google client ID/secret are not set in Supabase secrets yet.');
        const p = new URLSearchParams({
          client_id: CLIENT_ID, redirect_uri: REDIRECT_URI, response_type: 'code', scope: SCOPES.join(' '),
          access_type: 'offline', prompt: 'consent', include_granted_scopes: 'true',
          login_hint: MASTER_EMAIL, state: await makeState(who),
        });
        return json({ url: `https://accounts.google.com/o/oauth2/v2/auth?${p}` });
      }
      case 'disconnect': {
        if (!isAdmin) return fail('Only the administrator can disconnect Google.', 403);
        const c = await getConnection();
        if (c?.refresh_token) await fetch(`https://oauth2.googleapis.com/revoke?token=${encodeURIComponent(c.refresh_token)}`, { method: 'POST' }).catch(() => {});
        await db.from('google_connection').update({ refresh_token: null, connected_at: null }).eq('id', 1);
        return json({ ok: true });
      }

      case 'upload': {
        const file = form?.get('file');
        const reservationId = String(form?.get('reservation_id') || '');
        const category = String(form?.get('category') || 'Other');
        if (!(file instanceof File)) return fail('No file received.');
        if (!CATEGORIES.includes(category)) return fail('Unknown category.');
        const ext = (file.name.split('.').pop() || '').toLowerCase();
        if (!ALLOWED_EXT.includes(ext)) return fail('This file type is not allowed. Use PDF, JPG, PNG, HEIC, Word or Excel.');
        if (file.size > MAX_BYTES) return fail('File is larger than 10 MB.');
        const { data: res } = await db.from('reservations').select('id, confirmation_number, guest_name').eq('id', reservationId).maybeSingle();
        if (!res) return fail('Reservation not found.', 404);

        const at = await accessToken();
        const folderId = await bookingFolder(at, res);
        const boundary = 'ecl' + crypto.randomUUID();
        const meta = JSON.stringify({ name: file.name, parents: [folderId] });
        const payload = new Blob([
          `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${meta}\r\n--${boundary}\r\nContent-Type: ${file.type || 'application/octet-stream'}\r\n\r\n`,
          new Uint8Array(await file.arrayBuffer()),
          `\r\n--${boundary}--`,
        ]);
        const up = await fetch('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,mimeType,size', {
          method: 'POST', headers: { Authorization: `Bearer ${at}`, 'Content-Type': `multipart/related; boundary=${boundary}` }, body: payload,
        });
        const g = await up.json();
        if (!up.ok) return fail('Google Drive upload failed: ' + (g?.error?.message || up.status), 502);
        const { data: row, error } = await db.from('reservation_files').insert({
          reservation_id: res.id, drive_file_id: g.id, name: g.name || file.name, mime_type: g.mimeType || file.type,
          size_bytes: Number(g.size || file.size), category, uploaded_by: who,
        }).select().single();
        if (error) return fail(error.message, 500);
        await logHistory(res.id, who, 'File uploaded', `${category} · ${row.name}`);
        return json({ file: row });
      }

      case 'download': {
        const { data: f } = await db.from('reservation_files').select('*').eq('id', body.file_id || '').maybeSingle();
        if (!f) return fail('File not found.', 404);
        const at = await accessToken();
        const r = await fetch(`https://www.googleapis.com/drive/v3/files/${f.drive_file_id}?alt=media`, { headers: { Authorization: `Bearer ${at}` } });
        if (!r.ok) return fail(r.status === 404 ? 'This file is no longer in Google Drive.' : 'Could not open the file from Google Drive.', r.status === 404 ? 404 : 502);
        return new Response(r.body, { headers: { ...cors,
          'Content-Type': f.mime_type || 'application/octet-stream',
          'Content-Disposition': `inline; filename*=UTF-8''${encodeURIComponent(f.name)}` } });
      }

      case 'delete': {
        const { data: f } = await db.from('reservation_files').select('*').eq('id', body.file_id || '').maybeSingle();
        if (!f) return fail('File not found.', 404);
        const at = await accessToken();
        await drive(at, `files/${f.drive_file_id}`, { method: 'PATCH', body: JSON.stringify({ trashed: true }) });  // to Drive trash (30 days)
        await db.from('reservation_files').delete().eq('id', f.id);
        await logHistory(f.reservation_id, who, 'File deleted', `${f.category} · ${f.name}`, true);
        return json({ ok: true });
      }

      case 'rename-folder': {
        const { data: row } = await db.from('reservation_drive_folders').select('folder_id').eq('reservation_id', body.reservation_id || '').maybeSingle();
        if (!row) return json({ ok: true, skipped: 'no folder yet' });
        const { data: res } = await db.from('reservations').select('id, confirmation_number, guest_name').eq('id', body.reservation_id).maybeSingle();
        if (!res) return fail('Reservation not found.', 404);
        const at = await accessToken();
        await drive(at, `files/${row.folder_id}`, { method: 'PATCH', body: JSON.stringify({ name: folderName(res) }) });
        return json({ ok: true });
      }

      default:
        return fail('Unknown action.');
    }
  } catch (e) {
    return fail(String((e as Error)?.message || e), 500);
  }
});
