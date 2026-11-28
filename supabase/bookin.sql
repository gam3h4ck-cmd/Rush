-- =====================================================================
-- BOOK-IN · prenotazioni tavoli (stesso progetto Supabase di Rush)
-- Da incollare in Supabase → SQL Editor → Run (si può rilanciare senza problemi)
-- Usa le tabelle di Rush: orgs, org_admins, is_org_admin(), ensure_org()
-- Orari salvati in minuti dalla mezzanotte (es. 19:30 = 1170)
-- =====================================================================

-- ---------- Tabelle ----------

create table if not exists public.bk_venues (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id) on delete cascade,
  name        text not null default '' check (char_length(name) <= 80),
  slug        text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{2,40}$'),
  settings    jsonb not null default '{}'::jsonb,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists bk_venues_org_idx on public.bk_venues (org_id);

create table if not exists public.bk_areas (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references public.bk_venues(id) on delete cascade,
  name        text not null default '' check (char_length(name) <= 40),
  sort        int not null default 0
);

create table if not exists public.bk_tables (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references public.bk_venues(id) on delete cascade,
  area_id     uuid references public.bk_areas(id) on delete set null,
  name        text not null check (char_length(name) between 1 and 12),
  min_seats   int not null default 1 check (min_seats between 1 and 50),
  max_seats   int not null default 2 check (max_seats between 1 and 50),
  shape       text not null default 'square' check (shape in ('square','round','rect')),
  x           numeric not null default 40,
  y           numeric not null default 40,
  w           numeric not null default 60,
  h           numeric not null default 60,
  online      boolean not null default true,
  sort        int not null default 0,
  check (min_seats <= max_seats)
);
create index if not exists bk_tables_venue_idx on public.bk_tables (venue_id);

-- tavoli unibili (es. 12+13 per 6 persone)
create table if not exists public.bk_combos (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references public.bk_venues(id) on delete cascade,
  table_ids   uuid[] not null check (cardinality(table_ids) between 2 and 6),
  min_seats   int not null default 1,
  max_seats   int not null check (max_seats between 1 and 80),
  online      boolean not null default true
);

-- turni (pranzo, cena…): giorni, primo e ultimo orario prenotabile, limite coperti ogni 15 minuti
create table if not exists public.bk_shifts (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references public.bk_venues(id) on delete cascade,
  name        text not null default '' check (char_length(name) <= 30),
  days        int[] not null default '{1,2,3,4,5,6,7}',
  first_min   int not null check (first_min between 0 and 1800),
  last_min    int not null check (last_min between 0 and 1800),
  pacing      int check (pacing is null or pacing between 1 and 500),
  sort        int not null default 0,
  check (first_min <= last_min)
);

-- giorni o turni chiusi (ferie, eventi privati)
create table if not exists public.bk_closures (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references public.bk_venues(id) on delete cascade,
  day         date not null,
  shift_id    uuid references public.bk_shifts(id) on delete cascade,
  note        text not null default '' check (char_length(note) <= 120)
);
create index if not exists bk_closures_idx on public.bk_closures (venue_id, day);

create table if not exists public.bk_guests (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references public.bk_venues(id) on delete cascade,
  first_name  text not null default '' check (char_length(first_name) <= 60),
  last_name   text not null default '' check (char_length(last_name) <= 60),
  phone       text not null default '' check (char_length(phone) <= 30),
  email       text not null default '' check (char_length(email) <= 120),
  tags        text[] not null default '{}',
  notes       text not null default '' check (char_length(notes) <= 1000),
  lang        text not null default '' check (char_length(lang) <= 5),
  created_at  timestamptz not null default now()
);
create index if not exists bk_guests_venue_idx on public.bk_guests (venue_id);
create index if not exists bk_guests_phone_idx on public.bk_guests (venue_id, phone);

create table if not exists public.bk_reservations (
  id           uuid primary key default gen_random_uuid(),
  venue_id     uuid not null references public.bk_venues(id) on delete cascade,
  guest_id     uuid references public.bk_guests(id) on delete set null,
  day          date not null,
  start_min    int not null check (start_min between 0 and 1800),
  duration     int not null default 90 check (duration between 15 and 600),
  party        int not null check (party between 1 and 80),
  table_ids    uuid[] not null default '{}',
  status       text not null default 'prenotata' check (status in
                 ('attesa','prenotata','confermata','parziale','seduta','conto','pagata','finita','no_show','annullata')),
  source       text not null default 'staff' check (source in ('online','telefono','walkin','staff')),
  guest_note   text not null default '' check (char_length(guest_note) <= 500),
  staff_note   text not null default '' check (char_length(staff_note) <= 500),
  tags         text[] not null default '{}',
  quoted_wait  int,
  manage_token uuid not null default gen_random_uuid() unique,
  seated_at    timestamptz,
  finished_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists bk_res_day_idx on public.bk_reservations (venue_id, day);
create index if not exists bk_res_guest_idx on public.bk_reservations (guest_id);

-- ---------- Sicurezza: ogni locale vede solo i propri dati ----------

create or replace function public.bk_is_venue_admin(p_venue uuid)
returns boolean language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.bk_venues v
                 where v.id = p_venue and public.is_org_admin(v.org_id));
$$;

alter table public.bk_venues enable row level security;
alter table public.bk_areas enable row level security;
alter table public.bk_tables enable row level security;
alter table public.bk_combos enable row level security;
alter table public.bk_shifts enable row level security;
alter table public.bk_closures enable row level security;
alter table public.bk_guests enable row level security;
alter table public.bk_reservations enable row level security;

drop policy if exists bk_venues_admin on public.bk_venues;
create policy bk_venues_admin on public.bk_venues for all to authenticated
  using (public.is_org_admin(org_id)) with check (public.is_org_admin(org_id));

do $$
declare t text;
begin
  foreach t in array array['bk_areas','bk_tables','bk_combos','bk_shifts','bk_closures','bk_guests','bk_reservations'] loop
    execute format('drop policy if exists %I on public.%I', t || '_admin', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.bk_is_venue_admin(venue_id)) with check (public.bk_is_venue_admin(venue_id))', t || '_admin', t);
  end loop;
end $$;

revoke all on public.bk_venues, public.bk_areas, public.bk_tables, public.bk_combos, public.bk_shifts,
  public.bk_closures, public.bk_guests, public.bk_reservations from anon;
grant select, insert, update, delete on public.bk_venues, public.bk_areas, public.bk_tables, public.bk_combos,
  public.bk_shifts, public.bk_closures, public.bk_guests, public.bk_reservations to authenticated;

-- updated_at automatico
create or replace function public.bk_touch() returns trigger language plpgsql
set search_path = public
as $$ begin new.updated_at := now(); return new; end; $$;
drop trigger if exists bk_res_touch on public.bk_reservations;
create trigger bk_res_touch before update on public.bk_reservations for each row execute function public.bk_touch();

-- ---------- Impostazioni del locale (con valori di partenza) ----------

-- durata del tavolo in minuti per numero di persone; impostabile in settings.durations, es. {"2":75,"4":90,"6":120}
create or replace function public.bk_duration(p_settings jsonb, p_party int)
returns int language sql immutable
set search_path = public
as $$
  select coalesce(
    (select (value)::int from jsonb_each_text(coalesce(p_settings->'durations', '{}'::jsonb))
      where key ~ '^[0-9]+$' and key::int >= p_party order by key::int limit 1),
    (select (value)::int from jsonb_each_text(coalesce(p_settings->'durations', '{}'::jsonb))
      where key ~ '^[0-9]+$' order by key::int desc limit 1),
    case when (p_settings->>'duration') ~ '^[0-9]+$' then (p_settings->>'duration')::int end,
    90);
$$;

create or replace function public.bk_setting_int(p_settings jsonb, p_key text, p_default int)
returns int language sql immutable
set search_path = public
as $$
  select case when (p_settings->>p_key) ~ '^[0-9]+$' then (p_settings->>p_key)::int else p_default end;
$$;

-- ---------- Motore di disponibilità ----------

-- Un insieme di tavoli è libero in [start, start+duration)?
create or replace function public.bk_tables_free(p_venue uuid, p_day date, p_start int, p_duration int, p_tables uuid[], p_skip uuid)
returns boolean language sql stable
set search_path = public
as $$
  select not exists (
    select 1 from public.bk_reservations r
    where r.venue_id = p_venue and r.day = p_day and r.id is distinct from p_skip
      and r.status not in ('annullata','no_show','finita','attesa')
      and r.table_ids && p_tables
      and r.start_min < p_start + p_duration and p_start < r.start_min + r.duration);
$$;

-- Miglior tavolo (o combinazione) libero: il più piccolo che basta; null se nessuno.
create or replace function public.bk_pick_tables(p_venue uuid, p_day date, p_start int, p_duration int, p_party int, p_online_only boolean, p_skip uuid)
returns uuid[] language plpgsql stable
set search_path = public
as $$
declare
  r record;
begin
  for r in
    select array[t.id] as ids, t.max_seats as cap, 0 as kind, t.sort
    from public.bk_tables t
    where t.venue_id = p_venue and p_party between t.min_seats and t.max_seats and (t.online or not p_online_only)
    union all
    select c.table_ids, c.max_seats, 1, 0
    from public.bk_combos c
    where c.venue_id = p_venue and p_party between c.min_seats and c.max_seats and (c.online or not p_online_only)
    order by cap, kind, sort
  loop
    if public.bk_tables_free(p_venue, p_day, p_start, p_duration, r.ids, p_skip) then
      return r.ids;
    end if;
  end loop;
  return null;
end;
$$;

-- Il giorno/turno è aperto? Restituisce il turno che contiene l'orario.
create or replace function public.bk_shift_at(p_venue uuid, p_day date, p_start int)
returns uuid language sql stable
set search_path = public
as $$
  select s.id from public.bk_shifts s
  where s.venue_id = p_venue and extract(isodow from p_day)::int = any(s.days)
    and p_start between s.first_min and s.last_min
    and not exists (select 1 from public.bk_closures c where c.venue_id = p_venue and c.day = p_day
                    and (c.shift_id is null or c.shift_id = s.id))
  order by s.sort, s.first_min limit 1;
$$;

-- Coperti che iniziano nella fascia di 15 minuti (pacing)
create or replace function public.bk_covers_in_slot(p_venue uuid, p_day date, p_start int, p_skip uuid)
returns int language sql stable
set search_path = public
as $$
  select coalesce(sum(r.party), 0)::int from public.bk_reservations r
  where r.venue_id = p_venue and r.day = p_day and r.id is distinct from p_skip
    and r.status not in ('annullata','no_show','attesa')
    and r.start_min >= (p_start / 15) * 15 and r.start_min < (p_start / 15) * 15 + 15;
$$;

-- Ora locale del ristorante (Bruxelles)
create or replace function public.bk_now_local() returns timestamp language sql stable
as $$ select now() at time zone 'Europe/Brussels'; $$;

-- Orari prenotabili online per un giorno e un numero di persone
create or replace function public.bk_available_times(p_venue uuid, p_day date, p_party int)
returns table (start_min int, shift_id uuid)
language plpgsql stable
set search_path = public
as $$
declare
  v_set jsonb;
  v_dur int;
  v_now timestamp := public.bk_now_local();
  v_min_adv int;
  v_max_days int;
  s record;
  t int;
begin
  select settings into v_set from public.bk_venues where id = p_venue and active;
  if v_set is null then return; end if;
  v_min_adv := public.bk_setting_int(v_set, 'minAdvanceMin', 60);
  v_max_days := public.bk_setting_int(v_set, 'maxDaysAhead', 60);
  if p_party < 1 or p_party > public.bk_setting_int(v_set, 'maxPartyOnline', 8) then return; end if;
  if p_day < v_now::date or p_day > v_now::date + v_max_days then return; end if;
  v_dur := public.bk_duration(v_set, p_party);
  for s in
    select * from public.bk_shifts sh
    where sh.venue_id = p_venue and extract(isodow from p_day)::int = any(sh.days)
      and not exists (select 1 from public.bk_closures c where c.venue_id = p_venue and c.day = p_day
                      and (c.shift_id is null or c.shift_id = sh.id))
    order by sh.first_min
  loop
    t := s.first_min;
    while t <= s.last_min loop
      if (p_day + make_interval(mins => t)) >= v_now + make_interval(mins => v_min_adv)
         and (s.pacing is null or public.bk_covers_in_slot(p_venue, p_day, t, null) + p_party <= s.pacing)
         and public.bk_pick_tables(p_venue, p_day, t, v_dur, p_party, true, null) is not null then
        start_min := t; shift_id := s.id;
        return next;
      end if;
      t := t + 15;
    end loop;
  end loop;
end;
$$;

-- ---------- Pagina pubblica (senza login, tramite lo slug del locale) ----------

create or replace function public.bk_public_venue(p_slug text)
returns json language sql stable security definer
set search_path = public
as $$
  select json_build_object(
    'name', v.name,
    'maxParty', public.bk_setting_int(v.settings, 'maxPartyOnline', 8),
    'maxDaysAhead', public.bk_setting_int(v.settings, 'maxDaysAhead', 60),
    'phone', coalesce(v.settings->>'phone', ''),
    'address', coalesce(v.settings->>'address', ''),
    'message', coalesce(v.settings->>'publicMessage', ''),
    'lang', coalesce(v.settings->>'defaultLang', 'fr'),
    'accent', coalesce(v.settings->>'accent', ''),
    'days', (select coalesce(json_agg(distinct d), '[]'::json) from public.bk_shifts s, unnest(s.days) d where s.venue_id = v.id))
  from public.bk_venues v where v.slug = lower(p_slug) and v.active;
$$;

create or replace function public.bk_public_times(p_slug text, p_day date, p_party int)
returns json language plpgsql stable security definer
set search_path = public
as $$
declare v_id uuid;
begin
  select id into v_id from public.bk_venues where slug = lower(p_slug) and active;
  if v_id is null then return null; end if;
  return coalesce((select json_agg(a.start_min order by a.start_min) from public.bk_available_times(v_id, p_day, p_party) a), '[]'::json);
end;
$$;

create or replace function public.bk_norm_phone(p text)
returns text language sql immutable
set search_path = public
as $$
  select case
    when x ~ '^00' then '+' || substr(x, 3)
    when x ~ '^0[0-9]' then '+32' || substr(x, 2)
    else x end
  from (select regexp_replace(coalesce(p, ''), '[^0-9+]', '', 'g') as x) q;
$$;

create or replace function public.bk_public_book(
  p_slug text, p_day date, p_start int, p_party int,
  p_first text, p_last text, p_phone text, p_email text, p_note text, p_lang text)
returns json language plpgsql volatile security definer
set search_path = public
as $$
declare
  v public.bk_venues%rowtype;
  v_phone text := public.bk_norm_phone(p_phone);
  v_email text := lower(trim(coalesce(p_email, '')));
  v_dur int;
  v_tables uuid[];
  v_guest uuid;
  r public.bk_reservations%rowtype;
begin
  select * into v from public.bk_venues where slug = lower(p_slug) and active;
  if not found then raise exception 'locale non trovato'; end if;
  if char_length(trim(coalesce(p_first, ''))) < 1 or char_length(v_phone) < 8 then
    raise exception 'dati mancanti';
  end if;
  if v_email <> '' and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'email non valida'; end if;
  -- serializza le prenotazioni dello stesso locale per evitare doppie assegnazioni
  perform pg_advisory_xact_lock(hashtext(v.id::text));
  if not exists (select 1 from public.bk_available_times(v.id, p_day, p_party) a where a.start_min = p_start) then
    raise exception 'orario non disponibile';
  end if;
  -- massimo 3 prenotazioni future attive per numero di telefono
  if (select count(*) from public.bk_reservations x join public.bk_guests g on g.id = x.guest_id
      where x.venue_id = v.id and g.phone = v_phone and x.day >= public.bk_now_local()::date
        and x.status in ('prenotata','confermata')) >= 3 then
    raise exception 'troppe prenotazioni';
  end if;
  v_dur := public.bk_duration(v.settings, p_party);
  v_tables := public.bk_pick_tables(v.id, p_day, p_start, v_dur, p_party, true, null);
  select id into v_guest from public.bk_guests where venue_id = v.id and phone = v_phone order by created_at limit 1;
  if v_guest is null then
    insert into public.bk_guests(venue_id, first_name, last_name, phone, email, lang)
    values (v.id, left(trim(p_first), 60), left(trim(coalesce(p_last, '')), 60), v_phone, left(v_email, 120), left(coalesce(p_lang, ''), 5))
    returning id into v_guest;
  else
    update public.bk_guests set email = case when v_email <> '' then left(v_email, 120) else email end,
      lang = case when coalesce(p_lang, '') <> '' then left(p_lang, 5) else lang end
    where id = v_guest;
  end if;
  insert into public.bk_reservations(venue_id, guest_id, day, start_min, duration, party, table_ids, status, source, guest_note)
  values (v.id, v_guest, p_day, p_start, v_dur, p_party, coalesce(v_tables, '{}'), 'prenotata', 'online', left(coalesce(p_note, ''), 500))
  returning * into r;
  return json_build_object('token', r.manage_token, 'day', r.day, 'start', r.start_min, 'party', r.party, 'name', v.name);
end;
$$;

-- Il cliente vede / annulla la propria prenotazione dal link ricevuto
create or replace function public.bk_public_manage(p_token uuid)
returns json language sql stable security definer
set search_path = public
as $$
  select json_build_object('day', r.day, 'start', r.start_min, 'party', r.party, 'status', r.status,
    'name', v.name, 'slug', v.slug, 'phone', coalesce(v.settings->>'phone', ''),
    'first_name', coalesce(g.first_name, ''),
    'can_cancel', r.status in ('prenotata','confermata')
       and (r.day + make_interval(mins => r.start_min)) > public.bk_now_local())
  from public.bk_reservations r join public.bk_venues v on v.id = r.venue_id
  left join public.bk_guests g on g.id = r.guest_id
  where r.manage_token = p_token;
$$;

create or replace function public.bk_public_cancel(p_token uuid)
returns boolean language plpgsql volatile security definer
set search_path = public
as $$
begin
  update public.bk_reservations set status = 'annullata'
   where manage_token = p_token and status in ('prenotata','confermata')
     and (day + make_interval(mins => start_min)) > public.bk_now_local();
  return found;
end;
$$;

-- ---------- Admin ----------

-- Crea il primo locale dell'account (riusa l'organizzazione di Rush, se c'è)
create or replace function public.bk_create_venue(p_name text, p_slug text)
returns uuid language plpgsql volatile security definer
set search_path = public
as $$
declare v_org uuid; v_id uuid;
begin
  if auth.uid() is null then raise exception 'non autorizzato'; end if;
  v_org := public.ensure_org();
  insert into public.bk_venues(org_id, name, slug, settings)
  values (v_org, left(trim(p_name), 80), lower(trim(p_slug)),
          '{"durations":{"2":90,"4":90,"6":120,"20":150},"maxPartyOnline":8,"minAdvanceMin":60,"maxDaysAhead":60,"defaultLang":"fr"}')
  returning id into v_id;
  insert into public.bk_areas(venue_id, name, sort) values (v_id, 'Sala', 0);
  insert into public.bk_shifts(venue_id, name, days, first_min, last_min, pacing, sort) values
    (v_id, 'Pranzo', '{1,2,3,4,5,6,7}', 720, 840, null, 0),
    (v_id, 'Cena', '{1,2,3,4,5,6,7}', 1110, 1320, null, 1);
  return v_id;
end;
$$;

-- Tavolo migliore per lo staff (anche tavoli non prenotabili online)
create or replace function public.bk_suggest_tables(p_venue uuid, p_day date, p_start int, p_duration int, p_party int, p_skip uuid)
returns uuid[] language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.bk_is_venue_admin(p_venue) then raise exception 'non autorizzato'; end if;
  return public.bk_pick_tables(p_venue, p_day, p_start, p_duration, p_party, false, p_skip);
end;
$$;

-- Statistiche cliente (visite, no-show, ultima visita)
create or replace function public.bk_guest_stats(p_venue uuid)
returns table (guest_id uuid, visits int, no_shows int, cancels int, last_visit date, next_visit date)
language sql stable security definer
set search_path = public
as $$
  select r.guest_id,
    count(*) filter (where r.status in ('seduta','conto','pagata','finita'))::int,
    count(*) filter (where r.status = 'no_show')::int,
    count(*) filter (where r.status = 'annullata')::int,
    max(r.day) filter (where r.status in ('seduta','conto','pagata','finita')),
    min(r.day) filter (where r.day >= public.bk_now_local()::date and r.status in ('prenotata','confermata'))
  from public.bk_reservations r
  where r.venue_id = p_venue and r.guest_id is not null and public.bk_is_venue_admin(p_venue)
  group by r.guest_id;
$$;

-- ---------- Permessi ----------

revoke execute on function public.bk_is_venue_admin(uuid) from public, anon;
revoke execute on function public.bk_tables_free(uuid, date, int, int, uuid[], uuid) from public, anon, authenticated;
revoke execute on function public.bk_pick_tables(uuid, date, int, int, int, boolean, uuid) from public, anon, authenticated;
revoke execute on function public.bk_available_times(uuid, date, int) from public, anon, authenticated;
revoke execute on function public.bk_covers_in_slot(uuid, date, int, uuid) from public, anon, authenticated;
revoke execute on function public.bk_shift_at(uuid, date, int) from public, anon, authenticated;
revoke execute on function public.bk_create_venue(text, text) from public, anon;
revoke execute on function public.bk_suggest_tables(uuid, date, int, int, int, uuid) from public, anon;
revoke execute on function public.bk_guest_stats(uuid) from public, anon;
revoke execute on function public.bk_public_venue(text) from public;
revoke execute on function public.bk_public_times(text, date, int) from public;
revoke execute on function public.bk_public_book(text, date, int, int, text, text, text, text, text, text) from public;
revoke execute on function public.bk_public_manage(uuid) from public;
revoke execute on function public.bk_public_cancel(uuid) from public;

grant execute on function public.bk_is_venue_admin(uuid) to authenticated;
grant execute on function public.bk_create_venue(text, text) to authenticated;
grant execute on function public.bk_suggest_tables(uuid, date, int, int, int, uuid) to authenticated;
grant execute on function public.bk_guest_stats(uuid) to authenticated;
grant execute on function public.bk_public_venue(text) to anon, authenticated;
grant execute on function public.bk_public_times(text, date, int) to anon, authenticated;
grant execute on function public.bk_public_book(text, date, int, int, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.bk_public_manage(uuid) to anon, authenticated;
grant execute on function public.bk_public_cancel(uuid) to anon, authenticated;
