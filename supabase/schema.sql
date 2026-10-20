-- ============================================================
-- Supabase schema for the chat site + admin panel
-- Paste into Supabase -> SQL Editor -> Run (safe to re-run)
-- ============================================================

-- ---------- helper: is the caller the admin? ----------
create or replace function public.is_admin()
returns boolean language sql stable as $$
  select coalesce(auth.jwt() ->> 'email', '') = 'jadocool0427@gmail.com'
$$;

-- ---------- users (replaces Firestore "users") ----------
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  name          text default '',
  email         text default '',
  photo         text default '',
  created_at    bigint default (extract(epoch from now())*1000)::bigint,
  last_at       bigint default (extract(epoch from now())*1000)::bigint,
  last_seen     bigint default (extract(epoch from now())*1000)::bigint,
  unread        int    default 0,
  last_message  text   default '',
  active_conv   uuid,
  in_call       boolean default false,
  voice_active  boolean default false,
  worm          boolean default false,
  human_until   bigint,
  typing        boolean default false
);

-- ---------- conversations ----------
create table if not exists public.conversations (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  title       text default 'محادثة جديدة',
  created_at  bigint default (extract(epoch from now())*1000)::bigint,
  last_at     bigint default (extract(epoch from now())*1000)::bigint
);
create index if not exists conv_user_idx on public.conversations(user_id, last_at desc);

-- ---------- messages ----------
create table if not exists public.messages (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null references public.profiles(id) on delete cascade,
  conv_id   uuid not null,   -- بدون FK: قد تصل الرسالة قبل إنشاء صف المحادثة
  sender    text not null check (sender in ('user','bot','admin')),
  text      text default '',
  att       jsonb,          -- single attachment  {type, data}
  atts      jsonb,          -- multiple attachments
  at        timestamptz not null default now()
);
create index if not exists msg_conv_idx on public.messages(conv_id, at);

-- ---------- keyword replies (admin-managed) ----------
create table if not exists public.replies (
  id          uuid primary key default gen_random_uuid(),
  keywords    text not null,
  answer      text not null,
  created_at  bigint default (extract(epoch from now())*1000)::bigint
);

-- ---------- settings (menu, fx, worm, ai, notices, welcome, btn_*, sg_*) ----------
create table if not exists public.settings (
  id    text primary key,
  data  jsonb not null default '{}'::jsonb
);

-- ---------- calls / WebRTC signalling ----------
create table if not exists public.calls (
  user_id         uuid primary key references public.profiles(id) on delete cascade,
  status          text,
  cid             text,
  name            text,
  offer           jsonb,
  answer          jsonb,
  admin_offer     jsonb,
  admin_answer    jsonb,
  join_cid        text,
  video_req       jsonb,
  video_declined  bigint,
  video_offer     jsonb,
  video_answer    jsonb,
  video_cid       text,
  video_status    text,
  created_at      bigint
);

create table if not exists public.call_candidates (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null references public.profiles(id) on delete cascade,
  cid       text,
  by        text check (by in ('u','a')),
  cand      jsonb not null,
  at        timestamptz not null default now()
);
create index if not exists cand_user_idx on public.call_candidates(user_id, at);

-- ---------- atomic unread counter (replaces Firestore increment) ----------
create or replace function public.bump_unread(p_user uuid, p_last text)
returns void language sql security definer set search_path = public as $$
  update public.profiles
     set unread = coalesce(unread,0) + 1,
         last_message = p_last,
         last_at = (extract(epoch from now())*1000)::bigint
   where id = p_user and (auth.uid() = p_user or public.is_admin());
$$;

-- ============================================================
-- Row Level Security
-- ============================================================
alter table public.profiles         enable row level security;
alter table public.conversations    enable row level security;
alter table public.messages         enable row level security;
alter table public.replies          enable row level security;
alter table public.settings         enable row level security;
alter table public.calls            enable row level security;
alter table public.call_candidates  enable row level security;

-- profiles
drop policy if exists p_sel on public.profiles;
drop policy if exists p_ins on public.profiles;
drop policy if exists p_upd on public.profiles;
drop policy if exists p_del on public.profiles;
create policy p_sel on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy p_ins on public.profiles for insert with check (id = auth.uid());
create policy p_upd on public.profiles for update using (id = auth.uid() or public.is_admin());
create policy p_del on public.profiles for delete using (public.is_admin());

-- conversations / messages / calls / candidates: owner or admin
do $$
declare t text;
begin
  foreach t in array array['conversations','messages','calls','call_candidates'] loop
    execute format('drop policy if exists %I_all on public.%I', t, t);
    execute format(
      'create policy %I_all on public.%I for all
         using (user_id = auth.uid() or public.is_admin())
         with check (user_id = auth.uid() or public.is_admin())', t, t);
  end loop;
end $$;

-- replies: everyone signed in can read (bot uses them), only admin writes
drop policy if exists r_sel on public.replies;
drop policy if exists r_w   on public.replies;
create policy r_sel on public.replies for select using (auth.role() = 'authenticated');
create policy r_w   on public.replies for all using (public.is_admin()) with check (public.is_admin());

-- settings: everyone signed in can read, only admin writes
drop policy if exists s_sel on public.settings;
drop policy if exists s_w   on public.settings;
create policy s_sel on public.settings for select using (auth.role() = 'authenticated');
create policy s_w   on public.settings for all using (public.is_admin()) with check (public.is_admin());

-- ============================================================
-- Realtime (replaces Firestore onSnapshot)
-- ============================================================
do $$
declare t text;
begin
  foreach t in array array['profiles','conversations','messages','replies','settings','calls','call_candidates'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
    execute format('alter table public.%I replica identity full', t);
  end loop;
end $$;
