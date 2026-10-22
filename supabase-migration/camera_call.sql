-- تشغّل هذا مرة واحدة في: Supabase Dashboard -> SQL Editor -> New query -> Run

create table if not exists public.calls (
  id uuid primary key references public.profiles(id) on delete cascade,
  video_req jsonb,
  video_declined bigint,
  video_offer jsonb,
  video_cid text,
  video_answer jsonb,
  video_status text,
  updated_at timestamptz default now()
);

create table if not exists public.call_candidates (
  id bigserial primary key,
  call_id uuid references public.calls(id) on delete cascade,
  cid text,
  by text,
  cand jsonb,
  created_at timestamptz default now()
);

alter table public.calls enable row level security;
alter table public.call_candidates enable row level security;

drop policy if exists "calls_select" on public.calls;
create policy "calls_select" on public.calls for select
  using (auth.uid() = id or (auth.jwt() ->> 'email') = 'jadocool0427@gmail.com');

drop policy if exists "calls_insert" on public.calls;
create policy "calls_insert" on public.calls for insert
  with check (auth.uid() = id or (auth.jwt() ->> 'email') = 'jadocool0427@gmail.com');

drop policy if exists "calls_update" on public.calls;
create policy "calls_update" on public.calls for update
  using (auth.uid() = id or (auth.jwt() ->> 'email') = 'jadocool0427@gmail.com');

drop policy if exists "cand_select" on public.call_candidates;
create policy "cand_select" on public.call_candidates for select
  using (exists (
    select 1 from public.calls c
    where c.id = call_candidates.call_id
      and (c.id = auth.uid() or (auth.jwt() ->> 'email') = 'jadocool0427@gmail.com')
  ));

drop policy if exists "cand_insert" on public.call_candidates;
create policy "cand_insert" on public.call_candidates for insert
  with check (exists (
    select 1 from public.calls c
    where c.id = call_candidates.call_id
      and (c.id = auth.uid() or (auth.jwt() ->> 'email') = 'jadocool0427@gmail.com')
  ));

alter publication supabase_realtime add table public.calls;
alter publication supabase_realtime add table public.call_candidates;
