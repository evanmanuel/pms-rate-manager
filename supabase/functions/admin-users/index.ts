// Supabase Edge Function: admin-users
// Lets the master admin list, create and remove users from the PMS Admin page.
// The Service Role key is provided by Supabase on the server (never in the website).

import { createClient } from 'npm:@supabase/supabase-js@2';

const MASTER_EMAIL = 'evansen.coliving@gmail.com';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false, autoRefreshToken: false } },
    );

    // Who is calling? Only the master admin may continue.
    const token = (req.headers.get('Authorization') || '').replace('Bearer ', '');
    const { data: { user }, error: userErr } = await admin.auth.getUser(token);
    if (userErr || !user) return json({ error: 'Please sign in again.' }, 401);
    if (user.email !== MASTER_EMAIL) return json({ error: 'Only the administrator can manage users.' }, 403);

    const { action, email, password, userId } = await req.json();

    if (action === 'list') {
      const { data, error } = await admin.auth.admin.listUsers({ perPage: 200 });
      if (error) return json({ error: error.message }, 400);
      return json({
        users: data.users.map((u) => ({
          id: u.id,
          email: u.email,
          created_at: u.created_at,
          last_sign_in_at: u.last_sign_in_at,
        })),
      });
    }

    if (action === 'create') {
      if (!email || !password || String(password).length < 6) {
        return json({ error: 'Email and a password of at least 6 characters are required.' }, 400);
      }
      const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
      if (error) return json({ error: error.message }, 400);
      return json({ user: { id: data.user.id, email: data.user.email } });
    }

    if (action === 'delete') {
      if (!userId) return json({ error: 'userId is required.' }, 400);
      if (userId === user.id) return json({ error: 'You cannot remove your own admin account.' }, 400);
      const { error } = await admin.auth.admin.deleteUser(userId);
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    return json({ error: 'Unknown action.' }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
