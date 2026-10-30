-- =====================================================================
-- ChainLog database: chain motor inspections, load tests, faults, spare parts
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------- People & roles ----------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text,
  email       text,
  role        text not null default 'pending' check (role in ('pending','tech','admin')),
  created_at  timestamptz not null default now()
);

create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('tech','admin'));
$$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- First account becomes admin; everyone after is pending until approved
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name, role)
  values (new.id, new.email,
          coalesce(nullif(new.raw_user_meta_data->>'name', ''), split_part(new.email, '@', 1)),
          case when exists (select 1 from public.profiles) then 'pending' else 'admin' end);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.guard_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.role is distinct from old.role and auth.uid() is not null and not public.is_admin() then
    raise exception 'Only admins can change access levels';
  end if;
  return new;
end $$;
create trigger profiles_guard_role before update on public.profiles for each row execute function public.guard_role();

-- ---------- Motors (and controllers) ----------
create table public.assets (
  id                 uuid primary key default gen_random_uuid(),
  tag                text not null,            -- the value in the QR sticker
  serial             text,
  category           text not null default 'Chain motor',
  make               text,
  model              text,
  wll_kg             numeric,                  -- working load limit
  chain_length_m     numeric,                  -- usable lift
  speed              text,                     -- e.g. 4 m/min
  voltage            text,                     -- e.g. 400V 3ph / D8+
  gauge_max_mm       numeric,                  -- chain wear limit: max length over the gauge links (from the manual)
  gauge_links        int default 11,
  location           text,
  status             text not null default 'OK' check (status in ('OK','Faulty','In repair','Out of service','Retired')),
  faulty_since       timestamptz,
  notes              text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  updated_by         uuid references public.profiles(id) on delete set null
);
create unique index assets_tag_unique on public.assets (lower(tag));
create index assets_updated_by_idx on public.assets (updated_by);

create or replace function public.assets_track_status() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.status in ('Faulty','In repair','Out of service') then
    if tg_op = 'UPDATE' and old.status in ('Faulty','In repair','Out of service') then
      new.faulty_since := coalesce(old.faulty_since, now());
    elsif tg_op = 'UPDATE' then
      new.faulty_since := now();
    else
      new.faulty_since := coalesce(new.faulty_since, now());
    end if;
  else
    new.faulty_since := null;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger assets_status before insert or update on public.assets for each row execute function public.assets_track_status();

-- ---------- Inspections & load tests ----------
create table public.inspections (
  id              uuid primary key default gen_random_uuid(),
  asset_id        uuid not null references public.assets(id) on delete cascade,
  kind            text not null check (kind in ('Periodic','Load test')),
  inspected_on    date not null default current_date,
  checklist       jsonb not null default '{}'::jsonb,   -- { "Hook & latch": "pass" | "fail" | "na", ... }
  gauge_mm        numeric,                               -- measured length over gauge links
  gauge_max_mm    numeric,                               -- limit used at the time
  test_load_kg    numeric,
  held            boolean,                               -- load test: held load, brake held, no slip
  result          text not null check (result in ('Pass','Fail')),
  notes           text,
  photos          text[] not null default '{}',
  inspector_name  text,
  created_by      uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at      timestamptz not null default now()
);
create index inspections_asset_idx on public.inspections (asset_id, inspected_on desc);
create index inspections_created_by_idx on public.inspections (created_by);

-- ---------- Maintenance log ----------
create table public.logs (
  id            uuid primary key default gen_random_uuid(),
  asset_id      uuid not null references public.assets(id) on delete cascade,
  kind          text not null check (kind in ('Fault','Repair','Service','Inspection','Note')),
  title         text not null,
  details       text,
  parts         text,
  location      text,
  status_after  text,
  inspection_id uuid references public.inspections(id) on delete set null,
  photos        text[] not null default '{}',
  tech_name     text,
  source        text,
  created_by    uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at    timestamptz not null default now()
);
create index logs_asset_idx on public.logs (asset_id, created_at desc);
create index logs_created_by_idx on public.logs (created_by);
create index logs_inspection_idx on public.logs (inspection_id);

-- ---------- Manuals ----------
create table public.manuals (
  id          uuid primary key default gen_random_uuid(),
  make        text not null,
  model       text,
  title       text not null,
  url         text,
  file_path   text,
  created_by  uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at  timestamptz not null default now()
);
create index manuals_created_by_idx on public.manuals (created_by);

-- ---------- Spare parts ----------
create table public.parts (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  make           text,
  part_number    text,
  supplier_code  text,
  fits           text,
  quantity       int  not null default 0 check (quantity >= 0),
  min_qty        int  not null default 0 check (min_qty >= 0),
  condition      text,
  unit_price     numeric,
  location       text,
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create table public.part_moves (
  id           uuid primary key default gen_random_uuid(),
  part_id      uuid not null references public.parts(id) on delete cascade,
  change       int  not null check (change <> 0),
  kind         text not null check (kind in ('checkout','restock','return','adjust')),
  person_name  text,
  person_id    uuid references public.profiles(id) on delete set null,
  asset_id     uuid references public.assets(id) on delete set null,
  unit_price   numeric,
  notes        text,
  created_by   uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at   timestamptz not null default now()
);
create index part_moves_part_idx       on public.part_moves (part_id, created_at desc);
create index part_moves_asset_idx      on public.part_moves (asset_id);
create index part_moves_person_idx     on public.part_moves (person_id);
create index part_moves_created_by_idx on public.part_moves (created_by);

create or replace function public.part_moves_apply() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.parts set quantity = quantity + new.change, updated_at = now() where id = new.part_id;
    return new;
  else
    update public.parts set quantity = quantity - old.change, updated_at = now() where id = old.part_id;
    return old;
  end if;
exception when check_violation then
  raise exception 'Not enough in stock for that.' using errcode = '23514';
end $$;
create trigger part_moves_stock after insert or delete on public.part_moves for each row execute function public.part_moves_apply();

-- ---------- Access rules ----------
grant select, insert, update, delete on public.profiles, public.assets, public.inspections, public.logs, public.manuals, public.parts, public.part_moves to authenticated;
alter table public.profiles    enable row level security;
alter table public.assets      enable row level security;
alter table public.inspections enable row level security;
alter table public.logs        enable row level security;
alter table public.manuals     enable row level security;
alter table public.parts       enable row level security;
alter table public.part_moves  enable row level security;

create policy "profiles: read"   on public.profiles for select to authenticated using ((select public.is_member()) or id = (select auth.uid()));
create policy "profiles: update" on public.profiles for update to authenticated using (id = (select auth.uid()) or (select public.is_admin()));
create policy "profiles: delete" on public.profiles for delete to authenticated using ((select public.is_admin()));

create policy "assets: read"   on public.assets for select to authenticated using ((select public.is_member()));
create policy "assets: add"    on public.assets for insert to authenticated with check ((select public.is_member()));
create policy "assets: edit"   on public.assets for update to authenticated using ((select public.is_member()));
create policy "assets: delete" on public.assets for delete to authenticated using ((select public.is_admin()));

-- inspections are a legal record: members add them, nobody but an admin can change or remove one
create policy "inspections: read"   on public.inspections for select to authenticated using ((select public.is_member()));
create policy "inspections: add"    on public.inspections for insert to authenticated with check ((select public.is_member()) and created_by = (select auth.uid()));
create policy "inspections: edit"   on public.inspections for update to authenticated using ((select public.is_admin()));
create policy "inspections: delete" on public.inspections for delete to authenticated using ((select public.is_admin()));

create policy "logs: read"   on public.logs for select to authenticated using ((select public.is_member()));
create policy "logs: add"    on public.logs for insert to authenticated with check ((select public.is_member()) and created_by = (select auth.uid()));
create policy "logs: edit"   on public.logs for update to authenticated using ((select public.is_admin()) or created_by = (select auth.uid()));
create policy "logs: delete" on public.logs for delete to authenticated using ((select public.is_admin()));

create policy "manuals: read"   on public.manuals for select to authenticated using ((select public.is_member()));
create policy "manuals: add"    on public.manuals for insert to authenticated with check ((select public.is_member()));
create policy "manuals: edit"   on public.manuals for update to authenticated using ((select public.is_admin()));
create policy "manuals: delete" on public.manuals for delete to authenticated using ((select public.is_admin()));

create policy "parts: read"   on public.parts for select to authenticated using ((select public.is_member()));
create policy "parts: add"    on public.parts for insert to authenticated with check ((select public.is_member()));
create policy "parts: edit"   on public.parts for update to authenticated using ((select public.is_member()));
create policy "parts: delete" on public.parts for delete to authenticated using ((select public.is_admin()));

create policy "moves: read"   on public.part_moves for select to authenticated using ((select public.is_member()));
create policy "moves: add"    on public.part_moves for insert to authenticated with check ((select public.is_member()) and created_by = (select auth.uid()));
create policy "moves: delete" on public.part_moves for delete to authenticated using ((select public.is_admin()));

-- internal functions are not callable from outside
revoke execute on function public.guard_role()          from public, anon, authenticated;
revoke execute on function public.handle_new_user()     from public, anon, authenticated;
revoke execute on function public.part_moves_apply()    from public, anon, authenticated;
revoke execute on function public.assets_track_status() from public, anon, authenticated;
revoke execute on function public.is_member() from public, anon;
revoke execute on function public.is_admin()  from public, anon;
grant  execute on function public.is_member() to authenticated;
grant  execute on function public.is_admin()  to authenticated;

-- ---------- File storage (photos & manual PDFs) ----------
insert into storage.buckets (id, name, public) values ('photos','photos',false), ('manuals','manuals',false) on conflict (id) do nothing;
create policy "files: read"   on storage.objects for select to authenticated using (bucket_id in ('photos','manuals') and (select public.is_member()));
create policy "files: upload" on storage.objects for insert to authenticated with check (bucket_id in ('photos','manuals') and (select public.is_member()));
create policy "files: delete" on storage.objects for delete to authenticated using (bucket_id in ('photos','manuals') and (select public.is_admin()));

-- ---------- Motor record form fields (added) ----------
alter table public.inspections add column if not exists item_notes jsonb not null default '{}'::jsonb;
alter table public.inspections add column if not exists brake_gap_mm numeric;
alter table public.inspections add column if not exists roadcase text;
alter table public.inspections add column if not exists flagged boolean not null default false;
alter table public.inspections add column if not exists refer_to text;
alter table public.inspections add column if not exists flag_resolved_at timestamptz;
alter table public.inspections add column if not exists service_label boolean;
alter table public.inspections add column if not exists chain_length_m numeric;
create policy "inspections: resolve flag" on public.inspections for update to authenticated
  using ((select public.is_member()) and flagged) with check ((select public.is_member()) and flagged);
create or replace function public.guard_inspection_edit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if (to_jsonb(new) - 'flag_resolved_at') is distinct from (to_jsonb(old) - 'flag_resolved_at') then
      raise exception 'Inspections can''t be changed once saved — ask an admin';
    end if;
  end if;
  return new;
end $$;
create trigger inspections_guard before update on public.inspections for each row execute function public.guard_inspection_edit();
revoke execute on function public.guard_inspection_edit() from public, anon, authenticated;
