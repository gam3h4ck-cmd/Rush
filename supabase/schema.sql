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


-- =====================================================================
-- Richieste di ferie / giorni liberi e disponibilità studenti
-- (stesso contenuto di aggiornamento-richieste.sql)
-- =====================================================================

-- ---------- Tabelle ----------

-- Richieste di ferie o giorno libero.
create table if not exists public.time_off (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id) on delete cascade,
  staff_id    uuid not null,
  kind        text not null check (kind in ('ferie','libero')),
  start_day   date not null,
  end_day     date not null,
  note        text not null default '' check (char_length(note) <= 200),
  status      text not null default 'attesa' check (status in ('attesa','approvata','rifiutata')),
  admin_note  text not null default '' check (char_length(admin_note) <= 200),
  created_at  timestamptz not null default now(),
  decided_at  timestamptz,
  check (end_day >= start_day and end_day - start_day <= 60),
  foreign key (staff_id, org_id) references public.staff(id, org_id) on delete cascade
);
create index if not exists time_off_org_idx   on public.time_off (org_id, start_day);
create index if not exists time_off_staff_idx on public.time_off (staff_id, start_day);

-- Disponibilità degli studenti, giorno per giorno.
create table if not exists public.availability (
  org_id      uuid not null references public.orgs(id) on delete cascade,
  staff_id    uuid not null,
  day         date not null,
  slot        text not null check (slot in ('tutto','pranzo','cena','no')),
  updated_at  timestamptz not null default now(),
  primary key (staff_id, day),
  foreign key (staff_id, org_id) references public.staff(id, org_id) on delete cascade
);
create index if not exists availability_org_idx on public.availability (org_id, day);

-- Nota e data di invio della disponibilità, per settimana (week_start = lunedì).
create table if not exists public.availability_weeks (
  org_id      uuid not null references public.orgs(id) on delete cascade,
  staff_id    uuid not null,
  week_start  date not null check (extract(isodow from week_start) = 1),
  note        text not null default '' check (char_length(note) <= 200),
  updated_at  timestamptz not null default now(),
  primary key (staff_id, week_start),
  foreign key (staff_id, org_id) references public.staff(id, org_id) on delete cascade
);

-- ---------- Funzioni per la pagina del dipendente (link segreto) ----------

-- Dati della pagina: statuto, richieste e disponibilità. Niente tariffe.
create or replace function public.staff_portal(p_token uuid, p_from date, p_to date)
returns json
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_staff public.staff%rowtype;
  v_from  date := coalesce(p_from, current_date - 7);
  v_to    date := coalesce(p_to,   current_date + 90);
begin
  if v_to < v_from or v_to - v_from > 120 then
    raise exception 'range not allowed';
  end if;
  select * into v_staff from public.staff where access_token = p_token and link_active;
  if not found then
    return null;
  end if;
  return json_build_object(
    'status', v_staff.status,
    'requests', coalesce((
      select json_agg(json_build_object(
        'id', t.id, 'kind', t.kind, 'start', t.start_day, 'end', t.end_day, 'note', t.note,
        'status', t.status, 'admin_note', t.admin_note, 'created_at', t.created_at)
        order by t.start_day desc, t.created_at desc)
      from public.time_off t
      where t.staff_id = v_staff.id and t.end_day >= current_date - 180
    ), '[]'::json),
    'availability', coalesce((
      select json_agg(json_build_object('day', a.day, 'slot', a.slot) order by a.day)
      from public.availability a
      where a.staff_id = v_staff.id and a.day between v_from and v_to
    ), '[]'::json),
    'weeks', coalesce((
      select json_agg(json_build_object('week_start', w.week_start, 'note', w.note, 'updated_at', w.updated_at) order by w.week_start)
      from public.availability_weeks w
      where w.staff_id = v_staff.id and w.week_start between v_from - 6 and v_to
    ), '[]'::json)
  );
end;
$$;

-- Nuova richiesta di ferie o giorno libero.
create or replace function public.staff_request_create(p_token uuid, p_kind text, p_start date, p_end date, p_note text)
returns uuid
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_staff public.staff%rowtype;
  v_id    uuid;
  v_end   date := coalesce(p_end, p_start);
begin
  select * into v_staff from public.staff where access_token = p_token and link_active;
  if not found then
    raise exception 'link non valido';
  end if;
  if p_kind not in ('ferie','libero') then
    raise exception 'tipo non valido';
  end if;
  if p_start is null or p_start < current_date then
    raise exception 'data nel passato';
  end if;
  if v_end < p_start or v_end - p_start > 60 then
    raise exception 'periodo non valido';
  end if;
  if p_start > current_date + 400 then
    raise exception 'data troppo lontana';
  end if;
  if (select count(*) from public.time_off where staff_id = v_staff.id and status = 'attesa') >= 20 then
    raise exception 'troppe richieste in attesa';
  end if;
  insert into public.time_off (org_id, staff_id, kind, start_day, end_day, note)
  values (v_staff.org_id, v_staff.id, p_kind, p_start, v_end, left(coalesce(trim(p_note), ''), 200))
  returning id into v_id;
  return v_id;
end;
$$;

-- Annulla una richiesta ancora in attesa.
create or replace function public.staff_request_cancel(p_token uuid, p_id uuid)
returns boolean
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_staff public.staff%rowtype;
begin
  select * into v_staff from public.staff where access_token = p_token and link_active;
  if not found then
    raise exception 'link non valido';
  end if;
  delete from public.time_off where id = p_id and staff_id = v_staff.id and status = 'attesa';
  return found;
end;
$$;

-- Salva la disponibilità di una settimana (solo studenti).
-- p_slots: 7 valori da lunedì a domenica: 'tutto', 'pranzo', 'cena', 'no' oppure '' (non indicato).
create or replace function public.staff_availability_set(p_token uuid, p_week_start date, p_slots text[], p_note text)
returns boolean
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_staff public.staff%rowtype;
  v_slot  text;
  i       int;
begin
  select * into v_staff from public.staff where access_token = p_token and link_active;
  if not found then
    raise exception 'link non valido';
  end if;
  if v_staff.status <> 'studente' then
    raise exception 'solo per studenti';
  end if;
  if p_week_start is null or extract(isodow from p_week_start) <> 1 then
    raise exception 'la settimana deve iniziare di lunedì';
  end if;
  if p_week_start < current_date - 6 or p_week_start > current_date + 120 then
    raise exception 'settimana non modificabile';
  end if;
  if p_slots is null or coalesce(array_length(p_slots, 1), 0) <> 7 then
    raise exception 'servono 7 giorni';
  end if;
  for i in 1..7 loop
    v_slot := coalesce(p_slots[i], '');
    if v_slot = '' then
      delete from public.availability where staff_id = v_staff.id and day = p_week_start + (i - 1);
    elsif v_slot in ('tutto','pranzo','cena','no') then
      insert into public.availability (org_id, staff_id, day, slot, updated_at)
      values (v_staff.org_id, v_staff.id, p_week_start + (i - 1), v_slot, now())
      on conflict (staff_id, day) do update set slot = excluded.slot, updated_at = now();
    else
      raise exception 'valore non valido';
    end if;
  end loop;
  insert into public.availability_weeks (org_id, staff_id, week_start, note, updated_at)
  values (v_staff.org_id, v_staff.id, p_week_start, left(coalesce(trim(p_note), ''), 200), now())
  on conflict (staff_id, week_start) do update set note = excluded.note, updated_at = now();
  return true;
end;
$$;

-- ---------- Sicurezza (Row Level Security): solo gli admin del locale ----------

alter table public.time_off           enable row level security;
alter table public.availability       enable row level security;
alter table public.availability_weeks enable row level security;

drop policy if exists time_off_all on public.time_off;
create policy time_off_all on public.time_off for all to authenticated
  using (public.is_org_admin(org_id)) with check (public.is_org_admin(org_id));

drop policy if exists availability_all on public.availability;
create policy availability_all on public.availability for all to authenticated
  using (public.is_org_admin(org_id)) with check (public.is_org_admin(org_id));

drop policy if exists availability_weeks_all on public.availability_weeks;
create policy availability_weeks_all on public.availability_weeks for all to authenticated
  using (public.is_org_admin(org_id)) with check (public.is_org_admin(org_id));

-- Permessi: i visitatori anonimi passano solo dalle funzioni con il link segreto.
revoke all on public.time_off, public.availability, public.availability_weeks from anon;
revoke execute on function public.staff_portal(uuid, date, date) from public;
revoke execute on function public.staff_request_create(uuid, text, date, date, text) from public;
revoke execute on function public.staff_request_cancel(uuid, uuid) from public;
revoke execute on function public.staff_availability_set(uuid, date, text[], text) from public;
grant  execute on function public.staff_portal(uuid, date, date) to anon, authenticated;
grant  execute on function public.staff_request_create(uuid, text, date, date, text) to anon, authenticated;
grant  execute on function public.staff_request_cancel(uuid, uuid) to anon, authenticated;
grant  execute on function public.staff_availability_set(uuid, date, text[], text) to anon, authenticated;
grant  select, insert, update, delete on public.time_off, public.availability, public.availability_weeks to authenticated;


-- =====================================================================
-- Cambi turno tra colleghi
-- (stesso contenuto di aggiornamento-cambi.sql)
-- =====================================================================

-- ---------- Tabella ----------

-- Un cambio: chi chiede (from_staff) cede il suo turno (shift_id) a un collega (to_staff).
-- Se other_day è valorizzato è uno scambio: il collega gli dà in cambio il turno other_shift_id.
-- Stati: attesa_collega → (rifiutata_collega | attesa_admin) → (approvata | rifiutata); annullata se chi chiede ritira.
create table if not exists public.shift_swaps (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.orgs(id) on delete cascade,
  from_staff      uuid not null,
  to_staff        uuid not null,
  shift_id        uuid references public.shifts(id) on delete set null,   -- null se il turno è stato poi eliminato
  other_shift_id  uuid references public.shifts(id) on delete set null,
  shift_day       date not null,
  shift_start     text not null,
  shift_end       text not null,
  other_day       date,
  other_start     text,
  other_end       text,
  note            text not null default '' check (char_length(note) <= 200),
  status          text not null default 'attesa_collega'
                  check (status in ('attesa_collega','rifiutata_collega','attesa_admin','approvata','rifiutata','annullata')),
  admin_note      text not null default '' check (char_length(admin_note) <= 200),
  created_at      timestamptz not null default now(),
  colleague_at    timestamptz,
  decided_at      timestamptz,
  check (from_staff <> to_staff),
  check (other_shift_id is null or other_shift_id <> shift_id),
  foreign key (from_staff, org_id) references public.staff(id, org_id) on delete cascade,
  foreign key (to_staff, org_id)   references public.staff(id, org_id) on delete cascade
);
create index if not exists shift_swaps_org_idx  on public.shift_swaps (org_id, created_at);
create index if not exists shift_swaps_from_idx on public.shift_swaps (from_staff);
create index if not exists shift_swaps_to_idx   on public.shift_swaps (to_staff);

-- ---------- Funzioni per la pagina del dipendente (link segreto) ----------

-- Dati per i cambi: i miei prossimi turni, i colleghi dello stesso reparto con i loro prossimi turni, i cambi che mi riguardano.
create or replace function public.staff_swap_data(p_token uuid)
returns json
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_staff public.staff%rowtype;
begin
  select * into v_staff from public.staff where access_token = p_token and link_active;
  if not found then
    return null;
  end if;
  return json_build_object(
    'role', v_staff.role,
    'my_shifts', coalesce((
      select json_agg(json_build_object('id', s.id, 'day', s.day, 'start', s.start_time, 'end', s.end_time) order by s.day, s.start_time)
      from public.shifts s
      where s.staff_id = v_staff.id and s.day between current_date and current_date + 42
    ), '[]'::json),
    'colleagues', coalesce((
      select json_agg(json_build_object(
        'id', c.id, 'name', c.name,
        'shifts', coalesce((
          select json_agg(json_build_object('id', s.id, 'day', s.day, 'start', s.start_time, 'end', s.end_time) order by s.day, s.start_time)
          from public.shifts s
          where s.staff_id = c.id and s.day between current_date and current_date + 42
        ), '[]'::json)) order by c.name)
      from public.staff c
      where c.org_id = v_staff.org_id and c.id <> v_staff.id and c.role = v_staff.role and c.link_active
    ), '[]'::json),
    'swaps', coalesce((
      select json_agg(json_build_object(
        'id', w.id, 'mine', w.from_staff = v_staff.id, 'shift_id', w.shift_id, 'other_shift_id', w.other_shift_id,
        'from_name', f.name, 'to_name', t.name,
        'shift_day', w.shift_day, 'shift_start', w.shift_start, 'shift_end', w.shift_end,
        'other_day', w.other_day, 'other_start', w.other_start, 'other_end', w.other_end,
        'note', w.note, 'status', w.status, 'admin_note', w.admin_note, 'created_at', w.created_at)
        order by w.created_at desc)
      from public.shift_swaps w
      join public.staff f on f.id = w.from_staff
      join public.staff t on t.id = w.to_staff
      where (w.from_staff = v_staff.id or w.to_staff = v_staff.id)
        and (w.status in ('attesa_collega','attesa_admin') or w.created_at >= now() - interval '60 days')
    ), '[]'::json)
  );
end;
$$;

-- Nuova richiesta di cambio. p_other_shift = null → cessione; altrimenti scambio.
create or replace function public.staff_swap_create(p_token uuid, p_shift uuid, p_to_staff uuid, p_other_shift uuid, p_note text)
returns uuid
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_me    public.staff%rowtype;
  v_to    public.staff%rowtype;
  v_s     public.shifts%rowtype;
  v_o     public.shifts%rowtype;
  v_id    uuid;
begin
  select * into v_me from public.staff where access_token = p_token and link_active;
  if not found then
    raise exception 'link non valido';
  end if;
  select * into v_s from public.shifts where id = p_shift and staff_id = v_me.id;
  if not found then
    raise exception 'turno non trovato';
  end if;
  if v_s.day < current_date then
    raise exception 'turno passato';
  end if;
  select * into v_to from public.staff where id = p_to_staff and org_id = v_me.org_id and link_active;
  if not found or v_to.id = v_me.id then
    raise exception 'collega non valido';
  end if;
  if v_to.role <> v_me.role then
    raise exception 'reparto diverso';
  end if;
  if p_other_shift is not null then
    select * into v_o from public.shifts where id = p_other_shift and staff_id = v_to.id;
    if not found then
      raise exception 'turno del collega non trovato';
    end if;
    if v_o.day < current_date then
      raise exception 'turno passato';
    end if;
  end if;
  if exists (select 1 from public.shift_swaps
             where status in ('attesa_collega','attesa_admin')
               and (shift_id in (p_shift, p_other_shift) or other_shift_id in (p_shift, p_other_shift))) then
    raise exception 'cambio già in corso';
  end if;
  if (select count(*) from public.shift_swaps where from_staff = v_me.id and status in ('attesa_collega','attesa_admin')) >= 10 then
    raise exception 'troppe richieste aperte';
  end if;
  insert into public.shift_swaps (org_id, from_staff, to_staff, shift_id, other_shift_id,
    shift_day, shift_start, shift_end, other_day, other_start, other_end, note)
  values (v_me.org_id, v_me.id, v_to.id, v_s.id, v_o.id,
    v_s.day, v_s.start_time, v_s.end_time, v_o.day, v_o.start_time, v_o.end_time,
    left(coalesce(trim(p_note), ''), 200))
  returning id into v_id;
  return v_id;
end;
$$;

-- Il collega accetta o rifiuta.
create or replace function public.staff_swap_respond(p_token uuid, p_id uuid, p_accept boolean)
returns boolean
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_me public.staff%rowtype;
begin
  select * into v_me from public.staff where access_token = p_token and link_active;
  if not found then
    raise exception 'link non valido';
  end if;
  update public.shift_swaps
     set status = case when p_accept then 'attesa_admin' else 'rifiutata_collega' end,
         colleague_at = now()
   where id = p_id and to_staff = v_me.id and status = 'attesa_collega';
  return found;
end;
$$;

-- Chi ha chiesto ritira la richiesta (finché non è decisa).
create or replace function public.staff_swap_cancel(p_token uuid, p_id uuid)
returns boolean
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_me public.staff%rowtype;
begin
  select * into v_me from public.staff where access_token = p_token and link_active;
  if not found then
    raise exception 'link non valido';
  end if;
  update public.shift_swaps set status = 'annullata'
   where id = p_id and from_staff = v_me.id and status in ('attesa_collega','attesa_admin');
  return found;
end;
$$;

-- ---------- Funzione per l'admin ----------

-- Approva o rifiuta. Se approva, sposta i turni in un'unica operazione.
create or replace function public.admin_swap_decide(p_id uuid, p_approve boolean, p_note text)
returns boolean
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_w public.shift_swaps%rowtype;
begin
  select * into v_w from public.shift_swaps where id = p_id for update;
  if not found or not public.is_org_admin(v_w.org_id) then
    raise exception 'non autorizzato';
  end if;
  if v_w.status <> 'attesa_admin' then
    raise exception 'cambio non in attesa';
  end if;
  if p_approve then
    if not exists (select 1 from public.shifts where id = v_w.shift_id and staff_id = v_w.from_staff) then
      raise exception 'turni cambiati';
    end if;
    if v_w.other_day is not null
       and not exists (select 1 from public.shifts where id = v_w.other_shift_id and staff_id = v_w.to_staff) then
      raise exception 'turni cambiati';
    end if;
    update public.shifts set staff_id = v_w.to_staff where id = v_w.shift_id;
    if v_w.other_shift_id is not null then
      update public.shifts set staff_id = v_w.from_staff where id = v_w.other_shift_id;
    end if;
    update public.shift_swaps set status = 'approvata', admin_note = left(coalesce(trim(p_note), ''), 200), decided_at = now()
     where id = p_id;
    -- altri cambi aperti sugli stessi turni non hanno più senso
    update public.shift_swaps set status = 'annullata'
     where id <> p_id and status in ('attesa_collega','attesa_admin')
       and (shift_id in (v_w.shift_id, v_w.other_shift_id) or other_shift_id in (v_w.shift_id, v_w.other_shift_id));
  else
    update public.shift_swaps set status = 'rifiutata', admin_note = left(coalesce(trim(p_note), ''), 200), decided_at = now()
     where id = p_id;
  end if;
  return true;
end;
$$;

-- ---------- Sicurezza ----------

alter table public.shift_swaps enable row level security;
drop policy if exists shift_swaps_select on public.shift_swaps;
create policy shift_swaps_select on public.shift_swaps for select to authenticated
  using (public.is_org_admin(org_id));
drop policy if exists shift_swaps_delete on public.shift_swaps;
create policy shift_swaps_delete on public.shift_swaps for delete to authenticated
  using (public.is_org_admin(org_id));

revoke all on public.shift_swaps from anon;
revoke all on public.shift_swaps from authenticated;
grant select, delete on public.shift_swaps to authenticated;

revoke execute on function public.staff_swap_data(uuid) from public;
revoke execute on function public.staff_swap_create(uuid, uuid, uuid, uuid, text) from public;
revoke execute on function public.staff_swap_respond(uuid, uuid, boolean) from public;
revoke execute on function public.staff_swap_cancel(uuid, uuid) from public;
revoke execute on function public.admin_swap_decide(uuid, boolean, text) from public;
grant  execute on function public.staff_swap_data(uuid) to anon, authenticated;
grant  execute on function public.staff_swap_create(uuid, uuid, uuid, uuid, text) to anon, authenticated;
grant  execute on function public.staff_swap_respond(uuid, uuid, boolean) to anon, authenticated;
grant  execute on function public.staff_swap_cancel(uuid, uuid) to anon, authenticated;
grant  execute on function public.admin_swap_decide(uuid, boolean, text) to authenticated;
