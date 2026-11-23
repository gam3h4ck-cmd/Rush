-- =====================================================================
-- RUSH · schema del database (Supabase / Postgres)
-- Da incollare una sola volta in Supabase → SQL Editor → Run
-- =====================================================================

-- ---------- Tabelle ----------

-- Un locale (ristorante). Pronto per più locali e più clienti.
create table if not exists public.orgs (
  id          uuid primary key default gen_random_uuid(),
  name        text not null default '' check (char_length(name) <= 80),
  settings    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

-- Chi gestisce il locale (gli admin, con login email + password).
create table if not exists public.org_admins (
  org_id      uuid not null references public.orgs(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (org_id, user_id)
);

-- Il personale. Tariffe e massimi sono visibili solo agli admin.
create table if not exists public.staff (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.orgs(id) on delete cascade,
  name          text not null check (char_length(name) between 1 and 60),
  role          text not null default 'sala' check (role in ('sala','cucina','bar')),
  status        text not null default 'fisso' check (status in ('fisso','studente','indipendente')),
  rate          numeric(10,2) not null default 0 check (rate >= 0),
  contract      numeric(5,2)  not null default 0 check (contract >= 0),
  max_hours     numeric(5,2)  not null default 0 check (max_hours >= 0),
  prior_hours   numeric(7,2)  not null default 0 check (prior_hours >= 0),
  access_token  uuid not null unique default gen_random_uuid(),  -- link segreto del dipendente
  link_active   boolean not null default true,
  created_at    timestamptz not null default now(),
  unique (id, org_id)
);

-- I turni.
create table if not exists public.shifts (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id) on delete cascade,
  staff_id    uuid not null,
  day         date not null,
  start_time  text not null check (start_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  end_time    text not null check (end_time   ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  pause       integer not null default 0 check (pause between 0 and 600),
  note        text not null default '' check (char_length(note) <= 60),
  updated_at  timestamptz not null default now(),
  foreign key (staff_id, org_id) references public.staff(id, org_id) on delete cascade
);
create index if not exists shifts_org_day_idx   on public.shifts (org_id, day);
create index if not exists shifts_staff_day_idx on public.shifts (staff_id, day);
create index if not exists staff_org_idx        on public.staff (org_id);

-- ---------- Funzioni di supporto ----------

-- L'utente collegato è admin di questo locale?
create or replace function public.is_org_admin(p_org uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.org_admins
    where org_id = p_org and user_id = auth.uid()
  );
$$;

-- Al primo accesso crea il locale dell'utente; dopo restituisce sempre lo stesso.
create or replace function public.ensure_org()
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare v_org uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select org_id into v_org from public.org_admins where user_id = auth.uid() order by created_at limit 1;
  if v_org is null then
    insert into public.orgs (name) values ('') returning id into v_org;
    insert into public.org_admins (org_id, user_id) values (v_org, auth.uid());
  end if;
  return v_org;
end;
$$;

-- Pagina del dipendente: con il link segreto restituisce SOLO
-- il suo nome, il nome del locale, i suoi turni e chi lavora negli stessi giorni.
-- Niente tariffe, budget o massimi.
create or replace function public.staff_schedule(p_token uuid, p_from date, p_to date)
returns json
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_staff public.staff%rowtype;
  v_venue text;
  v_from  date := coalesce(p_from, current_date - 7);
  v_to    date := coalesce(p_to,   current_date + 21);
begin
  if v_to < v_from or v_to - v_from > 70 then
    raise exception 'range not allowed';
  end if;
  select * into v_staff from public.staff where access_token = p_token and link_active;
  if not found then
    return null;
  end if;
  select name into v_venue from public.orgs where id = v_staff.org_id;
  return json_build_object(
    'name',  v_staff.name,
    'venue', coalesce(v_venue, ''),
    'shifts', coalesce((
      select json_agg(json_build_object('day', s.day, 'start', s.start_time, 'end', s.end_time, 'pause', s.pause, 'note', s.note) order by s.day, s.start_time)
      from public.shifts s
      where s.staff_id = v_staff.id and s.day between v_from and v_to
    ), '[]'::json),
    'team', coalesce((
      select json_agg(json_build_object('day', s.day, 'start', s.start_time, 'end', s.end_time, 'name', st.name) order by s.day, s.start_time)
      from public.shifts s
      join public.staff st on st.id = s.staff_id
      where s.org_id = v_staff.org_id
        and s.staff_id <> v_staff.id
        and s.day in (select day from public.shifts where staff_id = v_staff.id and day between v_from and v_to)
    ), '[]'::json)
  );
end;
$$;

-- Aggiorna updated_at a ogni modifica di un turno.
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end;
$$;
drop trigger if exists shifts_touch on public.shifts;
create trigger shifts_touch before update on public.shifts
for each row execute function public.touch_updated_at();

-- ---------- Sicurezza (Row Level Security) ----------

alter table public.orgs       enable row level security;
alter table public.org_admins enable row level security;
alter table public.staff      enable row level security;
alter table public.shifts     enable row level security;

drop policy if exists orgs_select on public.orgs;
drop policy if exists orgs_update on public.orgs;
create policy orgs_select on public.orgs for select to authenticated using (public.is_org_admin(id));
create policy orgs_update on public.orgs for update to authenticated using (public.is_org_admin(id)) with check (public.is_org_admin(id));

drop policy if exists org_admins_select on public.org_admins;
create policy org_admins_select on public.org_admins for select to authenticated using (user_id = auth.uid());

drop policy if exists staff_all on public.staff;
create policy staff_all on public.staff for all to authenticated
  using (public.is_org_admin(org_id)) with check (public.is_org_admin(org_id));

drop policy if exists shifts_all on public.shifts;
create policy shifts_all on public.shifts for all to authenticated
  using (public.is_org_admin(org_id)) with check (public.is_org_admin(org_id));

-- Permessi: i visitatori anonimi possono solo chiamare staff_schedule.
revoke all on public.orgs, public.org_admins, public.staff, public.shifts from anon;
revoke execute on function public.ensure_org() from public, anon;
revoke execute on function public.is_org_admin(uuid) from public, anon;
revoke execute on function public.staff_schedule(uuid, date, date) from public;
grant  execute on function public.ensure_org() to authenticated;
grant  execute on function public.is_org_admin(uuid) to authenticated;
grant  execute on function public.staff_schedule(uuid, date, date) to anon, authenticated;
grant  select, insert, update, delete on public.staff, public.shifts to authenticated;
grant  select, update on public.orgs to authenticated;
grant  select on public.org_admins to authenticated;
