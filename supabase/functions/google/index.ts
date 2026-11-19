// Supabase Edge Function: google
// Connects the business Google account (admin only), stores booking documents in Google Drive,
// and sends guest confirmation / cancellation emails through Gmail.
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
const CATEGORIES = ['Passport', 'Payment slip', 'Other', 'Invoice'];

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

/* ── Guest emails (confirmation / cancellation) ────────────── */
const BRAND = 'Evansen Co Living';
const TAGLINE = 'your safest haven after a long day';
const LOGO_URL = APP_URL + 'email-logo.png';
const WHATSAPP_URL = 'https://wa.me/6287778332828';
const WHATSAPP_LABEL = '0877 7833 2828';
const MAP_URL = 'https://maps.app.goo.gl/JRCRdbyF3VHVRysS8';
const ADDRESS = 'Gang Palapa Jl. Nusa Dua, Ungasan, Badung, Bali.';
const ROOM_COLORS = [
  { c: '#0F382A', l: '#E3EFE9' }, { c: '#1E4B72', l: '#E1EEF8' },
  { c: '#733D14', l: '#FAEFE7' }, { c: '#502568', l: '#F4ECF8' },
  { c: '#0E5E5E', l: '#E0F2F1' }, { c: '#7A2E46', l: '#F8E8EE' },
];
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const idr = (n: unknown) => 'IDR ' + Math.round(Number(n || 0)).toLocaleString('id-ID');
const nightsOf = (a: string, d: string) => Math.max(0, Math.round((Date.parse(d) - Date.parse(a)) / 86400000));
const longDate = (iso: string) => new Date(iso + 'T00:00:00Z').toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' });
const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? '' : 's'}`;

type Kind = 'confirmation' | 'cancellation';

async function buildEmail(reservationId: string, kind: Kind) {
  const { data: r } = await db.from('reservations').select('*').eq('id', reservationId).maybeSingle();
  if (!r) throw new Error('Reservation not found.');
  const to = String(r.guest_email || '').trim();
  if (!to) throw new Error('This booking has no guest email.');
  if (!EMAIL_RE.test(to)) throw new Error('The guest email address does not look valid.');
  const cancelled = r.status === 'Cancelled';
  if (kind === 'confirmation' && cancelled) throw new Error('This booking is cancelled — send the cancellation email instead.');
  if (kind === 'cancellation' && !cancelled) throw new Error('Cancel the booking first, then send the cancellation email.');

  const { data: rooms } = await db.from('rooms').select('name, description').order('created_at');
  const idx = Math.max(0, (rooms || []).findIndex(x => x.name === r.room_name));
  const room = (rooms || [])[idx];
  const col = ROOM_COLORS[idx % ROOM_COLORS.length];
  const nights = Number(r.room_night) || nightsOf(r.arrival_date, r.departure_date);
  const guests = Number(r.guests) || 1;
  const total = Number(r.room_revenue || 0);
  const paid = Math.min(total, Number(r.amount_paid || 0));
  const balance = Math.max(0, total - paid);
  const name = esc(r.guest_name || 'Guest');
  const conf = esc(r.confirmation_number);

  const subject = kind === 'confirmation'
    ? `Booking Confirmed – ${r.confirmation_number} | ${BRAND}`
    : `Booking Cancelled – ${r.confirmation_number} | ${BRAND}`;

  const F = `font-family:Inter,'Segoe UI',Helvetica,Arial,sans-serif;`;
  const label = (t: string) => `<div style="${F}font-size:10px;line-height:14px;letter-spacing:.08em;font-weight:600;text-transform:uppercase;color:#4B5563;">${t}</div>`;
  const btn = (href: string, text: string, bg: string) =>
    `<a href="${href}" target="_blank" style="display:block;${F}background:${bg};color:#ffffff;text-decoration:none;font-size:13px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;text-align:center;padding:14px 12px;border-radius:12px;">${text}</a>`;

  const heroTitle = kind === 'confirmation' ? 'Booking Confirmed!' : 'Booking Cancelled';
  const heroText = kind === 'confirmation'
    ? `Dear ${name}, your stay has been confirmed. We look forward to welcoming you to ${BRAND}.`
    : `Dear ${name}, this email confirms that your booking below has been cancelled. We hope to welcome you at ${BRAND} another time.`;
  const heroIcon = kind === 'confirmation' ? '&#10003;' : '&#10005;';

  const rateLine = r.rate_type === 'total'
    ? `Room rate (total stay, ${plural(nights, 'night')})`
    : `Room rate (${plural(nights, 'night')} × ${idr(r.rate)})`;
  const payRow = (l: string, v: string) =>
    `<tr><td style="${F}font-size:13px;line-height:18px;color:#4B5563;padding:5px 0;">${l}</td><td align="right" style="${F}font-size:13px;line-height:18px;color:#111827;font-weight:500;padding:5px 0;white-space:nowrap;">${v}</td></tr>`;
  const payment = kind !== 'confirmation' ? '' : `
  <tr><td style="padding:0 32px 24px;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #E5E7EB;border-radius:20px;border-collapse:separate;overflow:hidden;">
      <tr><td style="background:#F3F4F1;padding:12px 20px;border-bottom:1px solid #E5E7EB;${F}font-size:15px;font-weight:600;color:#111827;">Payment Summary</td></tr>
      <tr><td style="padding:16px 20px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
          ${payRow(esc(rateLine), idr(total))}
          ${payRow('Paid', idr(paid))}
          <tr><td colspan="2" style="border-top:1px solid #E5E7EB;padding-top:10px;"></td></tr>
          <tr><td style="${F}font-size:15px;font-weight:700;color:#111827;">${balance > 0 ? 'Balance Due' : 'Payment Status'}</td>
              <td align="right" style="${F}font-size:18px;font-weight:700;color:#0F382A;white-space:nowrap;">${balance > 0 ? idr(balance) : 'Fully paid'}</td></tr>
        </table>
      </td></tr>
    </table>
  </td></tr>`;

  const infoItem = (t: string, d: string) =>
    `<tr><td style="${F}font-size:12px;line-height:18px;color:#111827;padding:4px 0;"><span style="color:#0F382A;">&#9679;</span>&nbsp; <strong>${t}</strong> ${d}</td></tr>`;
  const arrival = kind !== 'confirmation' ? '' : `
  <tr><td style="padding:0 32px 24px;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#EEF5F1;border:1px solid #DCE8E1;border-radius:20px;border-collapse:separate;">
      <tr><td style="padding:18px 20px;">
        <div style="${F}font-size:15px;font-weight:700;color:#0F382A;padding-bottom:8px;">Important Arrival Information</div>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
          ${infoItem('Arranging Your Arrival:', 'Please contact our team via email or WhatsApp to arrange your arrival.')}
          ${infoItem('High-speed Wi-Fi:', 'Complimentary fiber internet is active throughout all rooms and shared workspaces.')}
          ${infoItem('Property Address:', esc(ADDRESS))}
        </table>
      </td></tr>
    </table>
  </td></tr>`;

  const buttons = kind === 'confirmation'
    ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
         <td width="50%" style="padding-right:6px;">${btn(WHATSAPP_URL, 'Chat on WhatsApp', '#25D366')}</td>
         <td width="50%" style="padding-left:6px;">${btn(MAP_URL, 'View Location', '#0F382A')}</td></tr></table>`
    : btn(WHATSAPP_URL, 'Chat on WhatsApp', '#25D366');

  const html = `<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light"><meta name="supported-color-schemes" content="light"><title>${esc(subject)}</title></head>
<body style="margin:0;padding:0;background:#F8F8F4;">
<div style="display:none;max-height:0;overflow:hidden;">${kind === 'confirmation' ? `Your stay at ${BRAND} is confirmed · ${conf}` : `Your booking ${conf} has been cancelled`}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F8F8F4;"><tr><td align="center" style="padding:24px 12px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:640px;background:#ffffff;border:1px solid #E5E7EB;border-radius:28px;border-collapse:separate;overflow:hidden;">
  <tr><td align="center" style="padding:32px 32px 22px;border-bottom:1px solid #EEF0EC;">
    <img src="${LOGO_URL}" width="80" height="80" alt="${BRAND}" style="display:block;border:0;width:80px;height:80px;margin:0 auto 12px;">
    <div style="${F}font-size:18px;line-height:24px;font-weight:700;color:#0F382A;">${BRAND}</div>
    <div style="${F}font-size:10px;line-height:14px;letter-spacing:.12em;text-transform:uppercase;color:#4B5563;padding-top:2px;">${TAGLINE}</div>
  </td></tr>
  <tr><td align="center" style="background:${kind === 'confirmation' ? '#0F382A' : '#5B2121'};padding:28px 32px;">
    <div style="width:44px;height:44px;line-height:44px;border-radius:22px;background:${kind === 'confirmation' ? '#1A523E' : '#7A2E2E'};color:#ffffff;font-size:22px;font-weight:700;margin:0 auto 12px;${F}">${heroIcon}</div>
    <div style="${F}font-size:20px;line-height:26px;font-weight:700;color:#ffffff;">${heroTitle}</div>
    <div style="${F}font-size:13px;line-height:19px;color:${kind === 'confirmation' ? '#D7E9DE' : '#F3D9D9'};padding-top:6px;max-width:440px;margin:0 auto;">${heroText}</div>
    <table role="presentation" cellpadding="0" cellspacing="0" style="margin:16px auto 0;"><tr>
      <td style="background:${kind === 'confirmation' ? '#1A523E' : '#7A2E2E'};border-radius:12px;padding:7px 14px;${F}font-size:10px;letter-spacing:.08em;text-transform:uppercase;color:${kind === 'confirmation' ? '#D7E9DE' : '#F3D9D9'};">Confirmation number&nbsp;&nbsp;<span style="font-family:'SFMono-Regular',Menlo,Consolas,monospace;font-size:12px;font-weight:700;color:#ffffff;letter-spacing:.04em;">${conf}</span></td>
    </tr></table>
  </td></tr>
  <tr><td style="padding:32px 32px 24px;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F8F8F4;border:1px solid #E5E7EB;border-radius:28px;border-collapse:separate;">
      <tr><td style="padding:20px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-bottom:1px solid #E5E7EB;"><tr>
          <td style="padding-bottom:12px;" valign="middle">
            <div style="${F}font-size:15px;line-height:20px;font-weight:700;color:#111827;"><span style="display:inline-block;width:12px;height:12px;border-radius:6px;background:${col.c};vertical-align:middle;margin-right:8px;"></span>${kind === 'confirmation' ? 'Room Confirmation' : 'Cancelled Booking'} – ${esc(r.room_name)}</div>
            ${room?.description ? `<div style="${F}font-size:11px;line-height:16px;color:#4B5563;padding:2px 0 0 20px;">${esc(room.description)}</div>` : ''}
          </td>
        </tr></table>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:16px;"><tr>
          <td width="50%" style="padding-right:6px;"><div style="background:#ffffff;border:1px solid #E5E7EB;border-radius:12px;padding:14px;">${label('Check-in')}<div style="${F}font-size:15px;line-height:20px;font-weight:700;color:#111827;padding-top:4px;">${longDate(r.arrival_date)}</div></div></td>
          <td width="50%" style="padding-left:6px;"><div style="background:#ffffff;border:1px solid #E5E7EB;border-radius:12px;padding:14px;">${label('Check-out')}<div style="${F}font-size:15px;line-height:20px;font-weight:700;color:#111827;padding-top:4px;">${longDate(r.departure_date)}</div></div></td>
        </tr></table>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-top:14px;"><tr>
          <td style="${F}font-size:12px;color:#4B5563;">Total Duration: <strong style="color:#111827;">${plural(nights, 'Night')}</strong></td>
          <td align="right" style="${F}font-size:12px;color:#4B5563;">Guests: <strong style="color:#111827;">${plural(guests, 'Guest')}</strong></td>
        </tr></table>
      </td></tr>
    </table>
  </td></tr>
  ${payment}
  ${arrival}
  <tr><td style="padding:0 32px 32px;">${buttons}</td></tr>
  <tr><td align="center" style="background:#F8F8F4;border-top:1px solid #EEF0EC;padding:24px 32px;">
    <div style="${F}font-size:11px;line-height:17px;color:#4B5563;">Questions about your reservation? Contact our team at
      <a href="mailto:${MASTER_EMAIL}" style="color:#0F382A;font-weight:600;">${MASTER_EMAIL}</a> or WhatsApp <a href="${WHATSAPP_URL}" style="color:#0F382A;font-weight:600;">${WHATSAPP_LABEL}</a></div>
    <div style="${F}font-size:10px;letter-spacing:.08em;text-transform:uppercase;color:#6B7280;padding-top:8px;">© ${new Date().getFullYear()} ${BRAND}. All rights reserved.</div>
  </td></tr>
</table></td></tr></table></body></html>`;

  const text = [
    kind === 'confirmation' ? 'BOOKING CONFIRMED' : 'BOOKING CANCELLED',
    '', `Dear ${r.guest_name || 'Guest'},`,
    kind === 'confirmation' ? `Your stay has been confirmed. We look forward to welcoming you to ${BRAND}.`
                            : `This email confirms that your booking below has been cancelled.`,
    '', `Confirmation number: ${r.confirmation_number}`,
    `Room: ${r.room_name}${room?.description ? ' – ' + room.description : ''}`,
    `Check-in: ${longDate(r.arrival_date)}`, `Check-out: ${longDate(r.departure_date)}`,
    `Duration: ${plural(nights, 'night')} · ${plural(guests, 'guest')}`,
    ...(kind === 'confirmation' ? ['', `${rateLine}: ${idr(total)}`, `Paid: ${idr(paid)}`, balance > 0 ? `Balance due: ${idr(balance)}` : 'Fully paid',
      '', `Address: ${ADDRESS}`, `Location: ${MAP_URL}`] : []),
    '', `WhatsApp: ${WHATSAPP_URL}`, `Email: ${MASTER_EMAIL}`, '', BRAND,
  ].join('\n');

  return { reservation: r, to, subject, html, text };
}

function b64(bytes: Uint8Array) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
const wrap76 = (s: string) => s.replace(/.{1,76}/g, '$&\r\n');

async function sendGmail(at: string, to: string, subject: string, html: string, text: string) {
  const boundary = 'ecl' + crypto.randomUUID().replace(/-/g, '');
  const mime = [
    `From: =?UTF-8?B?${b64(enc.encode(BRAND))}?= <${MASTER_EMAIL}>`,
    `To: <${to}>`,
    `Reply-To: ${MASTER_EMAIL}`,
    `Subject: =?UTF-8?B?${b64(enc.encode(subject))}?=`,
    'MIME-Version: 1.0',
    `Content-Type: multipart/alternative; boundary="${boundary}"`,
    '',
    `--${boundary}`, 'Content-Type: text/plain; charset=UTF-8', 'Content-Transfer-Encoding: base64', '', wrap76(b64(enc.encode(text))),
    `--${boundary}`, 'Content-Type: text/html; charset=UTF-8', 'Content-Transfer-Encoding: base64', '', wrap76(b64(enc.encode(html))),
    `--${boundary}--`, '',
  ].join('\r\n');
  const raw = b64(enc.encode(mime)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const r = await fetch('https://gmail.googleapis.com/gmail/v1/users/me/messages/send', {
    method: 'POST', headers: { Authorization: `Bearer ${at}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ raw }),
  });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) {
    if (r.status === 403) throw new Error('Google did not allow sending email. An admin should disconnect and reconnect Google in Settings, and tick the Gmail permission.');
    throw new Error('Gmail error: ' + (body?.error?.message || r.status));
  }
  return body.id as string;
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
        if (category === 'Invoice') {
          // Keep only the newest invoice: older invoice files go to Drive trash
          const { data: olds } = await db.from('reservation_files').select('id, drive_file_id')
            .eq('reservation_id', res.id).eq('category', 'Invoice').neq('id', row.id);
          for (const o of olds || []) {
            await drive(at, `files/${o.drive_file_id}`, { method: 'PATCH', body: JSON.stringify({ trashed: true }) }).catch(() => null);
            await db.from('reservation_files').delete().eq('id', o.id);
          }
          await logHistory(res.id, who, 'Invoice generated', row.name);
        } else {
          await logHistory(res.id, who, 'File uploaded', `${category} · ${row.name}`);
        }
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

      case 'email-preview':
      case 'email-send': {
        const kind = body.kind === 'cancellation' ? 'cancellation' : 'confirmation';
        let mail;
        try { mail = await buildEmail(String(body.reservation_id || ''), kind); }
        catch (e) { return fail(String((e as Error).message)); }
        if (action === 'email-preview') return json({ to: mail.to, subject: mail.subject, html: mail.html });
        const at = await accessToken();
        const id = await sendGmail(at, mail.to, mail.subject, mail.html, mail.text);
        await db.from('reservation_history').insert({
          reservation_id: mail.reservation.id, changed_by: who,
          action: kind === 'confirmation' ? 'Confirmation email sent' : 'Cancellation email sent',
          changes: { sent_to: { old: null, new: mail.to } },
        });
        return json({ ok: true, id, to: mail.to });
      }

      default:
        return fail('Unknown action.');
    }
  } catch (e) {
    return fail(String((e as Error)?.message || e), 500);
  }
});
