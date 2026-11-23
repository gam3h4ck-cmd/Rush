-- =====================================================================
-- RUSH · aggiornamento: richieste di ferie / giorni liberi e disponibilità studenti
-- Da incollare UNA volta in Supabase → SQL Editor → Run.
-- Si può rilanciare senza problemi: non cancella dati.
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
