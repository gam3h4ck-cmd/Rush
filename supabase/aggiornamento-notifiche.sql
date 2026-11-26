-- =====================================================================
-- RUSH · aggiornamento: notifiche push sul telefono + ferie in giorni lavorativi
-- Da incollare in Supabase → SQL Editor → Run (si può rilanciare senza problemi)
-- =====================================================================

-- ---------- Tabelle ----------

-- I telefoni su cui un dipendente ha attivato le notifiche (uno per browser/telefono).
create table if not exists public.push_subs (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id) on delete cascade,
  staff_id    uuid not null,
  endpoint    text not null unique check (endpoint ~ '^https://' and char_length(endpoint) <= 1000),
  p256dh      text not null check (char_length(p256dh) between 80 and 100),
  auth        text not null check (char_length(auth) between 16 and 30),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  foreign key (staff_id, org_id) references public.staff(id, org_id) on delete cascade
);
create index if not exists push_subs_staff_idx on public.push_subs (staff_id);

-- Registro degli avvisi già inviati (evita doppioni).
create table if not exists public.push_log (
  kind        text not null,
  ref         text not null,
  staff_id    uuid not null references public.staff(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (kind, ref, staff_id)
);

-- Ultima versione del planning comunicata a ogni dipendente, per settimana.
create table if not exists public.push_planning_state (
  staff_id    uuid not null references public.staff(id) on delete cascade,
  week_start  date not null,
  hash        text not null,
  notified_at timestamptz not null default now(),
  primary key (staff_id, week_start)
);

alter table public.push_subs enable row level security;
alter table public.push_log enable row level security;
alter table public.push_planning_state enable row level security;
revoke all on public.push_subs, public.push_log, public.push_planning_state from anon, authenticated;

-- ---------- Formattazione (italiano) ----------

create or replace function public.rush_fmt_day(d date, with_dow boolean default false)
returns text language sql immutable
set search_path = public
as $$
  select case when with_dow then (array['lun','mar','mer','gio','ven','sab','dom'])[extract(isodow from d)::int] || ' ' else '' end
      || extract(day from d)::int || ' '
      || (array['gen','feb','mar','apr','mag','giu','lug','ago','set','ott','nov','dic'])[extract(month from d)::int];
$$;

create or replace function public.rush_fmt_range(a date, b date)
returns text language sql immutable
set search_path = public
as $$
  select case
    when a = b then public.rush_fmt_day(a, true)
    when date_trunc('month', a) = date_trunc('month', b)
      then extract(day from a)::int || '–' || public.rush_fmt_day(b)
    else public.rush_fmt_day(a) || ' – ' || public.rush_fmt_day(b)
  end;
$$;

create or replace function public.rush_fmt_hours(h numeric)
returns text language sql immutable
set search_path = public
as $$
  select replace(trim(trailing '.' from trim(trailing '0' from round(h, 2)::text)), '.', ',') || ' h';
$$;

-- Ore nette di un turno (gestisce i turni che finiscono dopo mezzanotte).
create or replace function public.rush_shift_hours(p_start text, p_end text, p_pause int)
returns numeric language sql immutable
set search_path = public
as $$
  select greatest(0, (
    ((split_part(p_end,':',1)::int*60 + split_part(p_end,':',2)::int)
     - (split_part(p_start,':',1)::int*60 + split_part(p_start,':',2)::int)
     + case when (split_part(p_end,':',1)::int*60 + split_part(p_end,':',2)::int)
              <= (split_part(p_start,':',1)::int*60 + split_part(p_start,':',2)::int) then 1440 else 0 end)
    - coalesce(p_pause,0))::numeric / 60);
$$;

-- Messaggi da inviare a un dipendente: un elemento per ogni telefono attivo.
create or replace function public.push_msgs_for(p_staff uuid, p_title text, p_body text, p_tag text)
returns jsonb language sql stable
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'sub', p.id, 'endpoint', p.endpoint, 'p256dh', p.p256dh, 'auth', p.auth,
           'title', p_title, 'body', p_body, 'tag', p_tag,
           'url', 'staff.html#' || s.access_token)), '[]'::jsonb)
  from public.push_subs p join public.staff s on s.id = p.staff_id
  where p.staff_id = p_staff and s.link_active;
$$;

-- Segna come inviato; restituisce false se era già stato inviato.
create or replace function public.push_once(p_kind text, p_ref text, p_staff uuid)
returns boolean language plpgsql volatile
set search_path = public
as $$
begin
  insert into public.push_log(kind, ref, staff_id) values (p_kind, p_ref, p_staff) on conflict do nothing;
  return found;
end;
$$;

-- ---------- Pagina del dipendente: attiva / disattiva ----------

create or replace function public.staff_push_subscribe(p_token uuid, p_endpoint text, p_p256dh text, p_auth text)
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
  insert into public.push_subs(org_id, staff_id, endpoint, p256dh, auth)
  values (v_staff.org_id, v_staff.id, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set org_id = excluded.org_id, staff_id = excluded.staff_id, p256dh = excluded.p256dh,
        auth = excluded.auth, updated_at = now();
  -- al massimo 5 telefoni per persona: tiene i più recenti
  delete from public.push_subs where id in (
    select id from public.push_subs where staff_id = v_staff.id order by updated_at desc offset 5);
  return true;
end;
$$;

create or replace function public.staff_push_unsubscribe(p_token uuid, p_endpoint text)
returns boolean
language plpgsql volatile security definer
set search_path = public
as $$
begin
  delete from public.push_subs p using public.staff s
   where p.endpoint = p_endpoint and p.staff_id = s.id and s.access_token = p_token;
  return found;
end;
$$;

-- staff_portal: aggiunge il regime di lavoro (giorni per settimana) per contare le ferie.
create or replace function public.staff_portal(p_token uuid, p_from date, p_to date)
returns json
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_staff public.staff%rowtype;
  v_wd    int;
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
  select case when (o.settings->>'workDays') ~ '^[1-7]$' then (o.settings->>'workDays')::int else 5 end
    into v_wd from public.orgs o where o.id = v_staff.org_id;
  return json_build_object(
    'status', v_staff.status,
    'work_days', coalesce(v_wd, 5),
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

-- ---------- Planning: chi ha novità da ricevere ----------

-- Settimane da oggi a +8: impronta dei turni di ogni dipendente, confrontata con l'ultima comunicata.
create or replace function public.push_planning_diff(p_org uuid)
returns table (staff_id uuid, week_start date, hash text, is_new boolean, n_shifts int, hours numeric)
language sql stable
set search_path = public
as $$
  with wk as (
    select (date_trunc('week', (now() at time zone 'Europe/Brussels')::date))::date as w0
  ), cur as (
    select sh.staff_id, (date_trunc('week', sh.day))::date as week_start,
           md5(string_agg(sh.day || ' ' || sh.start_time || '-' || sh.end_time || ' ' || sh.pause || ' ' || sh.note,
                          '|' order by sh.day, sh.start_time, sh.end_time)) as hash,
           count(*)::int as n_shifts,
           sum(public.rush_shift_hours(sh.start_time, sh.end_time, sh.pause)) as hours
    from public.shifts sh, wk
    where sh.org_id = p_org and sh.day between wk.w0 and wk.w0 + 62
    group by 1, 2
  ), old as (
    select ps.staff_id, ps.week_start, ps.hash
    from public.push_planning_state ps join public.staff s on s.id = ps.staff_id, wk
    where s.org_id = p_org and ps.week_start between wk.w0 and wk.w0 + 56
  )
  select coalesce(c.staff_id, o.staff_id), coalesce(c.week_start, o.week_start),
         coalesce(c.hash, 'vuoto'), o.hash is null, coalesce(c.n_shifts, 0), coalesce(c.hours, 0)
  from cur c full join old o on o.staff_id = c.staff_id and o.week_start = c.week_start
  join public.staff s on s.id = coalesce(c.staff_id, o.staff_id) and s.link_active
  where o.hash is distinct from coalesce(c.hash, 'vuoto');
$$;

-- Per il bottone dell'admin: quante persone hanno novità e quante hanno le notifiche attive.
create or replace function public.admin_planning_pending(p_org uuid)
returns json
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.is_org_admin(p_org) then
    raise exception 'non autorizzato';
  end if;
  return (
    select json_build_object(
      'people', count(distinct d.staff_id),
      'with_push', count(distinct d.staff_id) filter (where exists (select 1 from public.push_subs p where p.staff_id = d.staff_id)),
      'subscribed', (select count(distinct p.staff_id) from public.push_subs p where p.org_id = p_org))
    from public.push_planning_diff(p_org) d
  );
end;
$$;

-- ---------- Costruzione dei messaggi (solo per la funzione "notify", con chiave di servizio) ----------

create or replace function public.push_user_is_admin(p_user uuid, p_org uuid)
returns boolean language sql stable
set search_path = public
as $$
  select exists (select 1 from public.org_admins where user_id = p_user and org_id = p_org);
$$;

-- Planning pubblicato / modificato: messaggi per chi ha novità, poi segna tutto come comunicato.
create or replace function public.push_planning_msgs(p_user uuid, p_org uuid)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  r record;
  v_out jsonb := '[]'::jsonb;
  v_title text; v_body text;
  v_people int := 0;
begin
  if not public.push_user_is_admin(p_user, p_org) then
    raise exception 'non autorizzato';
  end if;
  for r in
    select staff_id, count(*) as n_weeks, bool_and(is_new) as all_new,
           min(week_start) as w, (array_agg(n_shifts order by week_start))[1] as n_shifts,
           (array_agg(hours order by week_start))[1] as hours,
           string_agg(public.rush_fmt_day(week_start), ', ' order by week_start) as weeks
    from public.push_planning_diff(p_org) group by staff_id
  loop
    v_people := v_people + 1;
    if r.n_weeks = 1 then
      v_title := case when r.all_new then 'Planning pubblicato' else 'Planning modificato' end;
      v_body := 'Settimana dal ' || public.rush_fmt_day(r.w) || ': '
             || case when r.n_shifts = 0 then 'nessun turno.'
                     else case when r.all_new then '' else 'ora ' end
                          || r.n_shifts || case when r.n_shifts = 1 then ' turno, ' else ' turni, ' end
                          || public.rush_fmt_hours(r.hours) || '.' end;
    else
      v_title := case when r.all_new then 'Planning pubblicato' else 'Planning aggiornato' end;
      v_body := 'Novità per le settimane dal ' || r.weeks || '.';
    end if;
    v_out := v_out || public.push_msgs_for(r.staff_id, v_title, v_body, 'planning');
  end loop;

  insert into public.push_planning_state(staff_id, week_start, hash, notified_at)
  select d.staff_id, d.week_start, d.hash, now() from public.push_planning_diff(p_org) d
  on conflict (staff_id, week_start) do update set hash = excluded.hash, notified_at = now();

  return jsonb_build_object('people', v_people, 'msgs', v_out);
end;
$$;

-- Risposta a una richiesta di ferie / giorno libero.
create or replace function public.push_request_msgs(p_user uuid, p_id uuid)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  t public.time_off%rowtype;
  v_title text; v_body text;
begin
  select * into t from public.time_off where id = p_id;
  if not found or not public.push_user_is_admin(p_user, t.org_id) then
    raise exception 'non autorizzato';
  end if;
  if t.status = 'attesa' or not public.push_once('req', t.id || ':' || t.status, t.staff_id) then
    return '[]'::jsonb;
  end if;
  v_title := case t.kind when 'ferie' then 'Ferie' else 'Giorno libero' end || ' '
          || case t.status when 'approvata' then case t.kind when 'ferie' then 'approvate' else 'approvato' end
                           else case t.kind when 'ferie' then 'rifiutate' else 'rifiutato' end end;
  v_body := public.rush_fmt_range(t.start_day, t.end_day)
         || case when t.admin_note <> '' then ' · ' || t.admin_note else '' end;
  return public.push_msgs_for(t.staff_id, v_title, v_body, 'req-' || t.id);
end;
$$;

-- Testo di un turno: "ven 5 dic 18:00–23:00"
create or replace function public.rush_fmt_shift(d date, a text, b text)
returns text language sql immutable
set search_path = public
as $$ select public.rush_fmt_day(d, true) || ' ' || a || '–' || b; $$;

-- Cambi turno: avvisa chi deve agire o chi aspetta una risposta, in base allo stato attuale.
-- p_user (admin) oppure p_token (dipendente coinvolto) devono essere validi.
create or replace function public.push_swap_msgs(p_user uuid, p_token uuid, p_id uuid)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  w public.shift_swaps%rowtype;
  v_me uuid;
  a_name text; b_name text;
  v_mine text; v_other text;
  v_out jsonb := '[]'::jsonb;
begin
  select * into w from public.shift_swaps where id = p_id;
  if not found then
    raise exception 'non autorizzato';
  end if;
  if p_user is not null then
    if not public.push_user_is_admin(p_user, w.org_id) then
      raise exception 'non autorizzato';
    end if;
  else
    select id into v_me from public.staff where access_token = p_token and link_active and id in (w.from_staff, w.to_staff);
    if v_me is null then
      raise exception 'non autorizzato';
    end if;
  end if;
  select name into a_name from public.staff where id = w.from_staff;
  select name into b_name from public.staff where id = w.to_staff;
  v_mine := public.rush_fmt_shift(w.shift_day, w.shift_start, w.shift_end);
  v_other := case when w.other_day is not null then public.rush_fmt_shift(w.other_day, w.other_start, w.other_end) end;

  if w.status = 'attesa_collega' and (p_user is not null or v_me = w.from_staff) then
    if public.push_once('swap', w.id || ':' || w.status, w.to_staff) then
      v_out := public.push_msgs_for(w.to_staff, 'Richiesta di cambio',
        case when v_other is null then a_name || ' ti chiede di prendere il suo turno di ' || v_mine || '.'
             else a_name || ' propone uno scambio: il suo turno di ' || v_mine || ' con il tuo di ' || v_other || '.' end,
        'swap-' || w.id);
    end if;
  elsif w.status in ('attesa_admin', 'rifiutata_collega') and (p_user is not null or v_me = w.to_staff) then
    if public.push_once('swap', w.id || ':' || w.status, w.from_staff) then
      v_out := public.push_msgs_for(w.from_staff,
        case when w.status = 'attesa_admin' then 'Cambio accettato' else 'Cambio rifiutato' end,
        case when w.status = 'attesa_admin' then b_name || ' ha accettato (' || v_mine || '). Ora decide il responsabile.'
             else b_name || ' ha rifiutato il cambio di ' || v_mine || '.' end,
        'swap-' || w.id);
    end if;
  elsif w.status in ('approvata', 'rifiutata') and p_user is not null then
    if public.push_once('swap', w.id || ':' || w.status, w.from_staff) then
      v_out := v_out || public.push_msgs_for(w.from_staff,
        case when w.status = 'approvata' then 'Cambio approvato' else 'Cambio non approvato' end,
        case when w.status = 'approvata'
             then 'Il turno di ' || v_mine || ' ora è di ' || b_name || coalesce('; tu fai ' || v_other, '') || '.'
             else v_mine || case when w.admin_note <> '' then ' · ' || w.admin_note else ' resta tuo.' end end,
        'swap-' || w.id);
    end if;
    if public.push_once('swap', w.id || ':' || w.status, w.to_staff) then
      v_out := v_out || public.push_msgs_for(w.to_staff,
        case when w.status = 'approvata' then 'Cambio approvato' else 'Cambio non approvato' end,
        case when w.status = 'approvata'
             then 'Ora fai tu il turno di ' || v_mine || coalesce('; ' || a_name || ' fa ' || v_other, '') || '.'
             else 'Il cambio con ' || a_name || ' (' || v_mine || ') non è stato approvato' || case when w.admin_note <> '' then ': ' || w.admin_note else '' end || '.' end,
        'swap-' || w.id);
    end if;
  end if;
  return v_out;
end;
$$;

-- Promemoria la sera prima (default 18:00, impostazione "reminderHour" del locale).
-- Chiamata ogni ora: invia a chi lavora domani e non l'ha ancora ricevuto (recupera anche un'ora saltata).
create or replace function public.push_reminder_msgs()
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  r record;
  v_out jsonb := '[]'::jsonb;
  v_now timestamp := now() at time zone 'Europe/Brussels';
  v_tom date := (now() at time zone 'Europe/Brussels')::date + 1;
begin
  for r in
    select sh.staff_id,
           string_agg(sh.start_time || '–' || sh.end_time, ' e ' order by sh.start_time) as times
    from public.shifts sh
    join public.staff s on s.id = sh.staff_id and s.link_active
    join public.orgs o on o.id = sh.org_id
    where sh.day = v_tom
      and extract(hour from v_now) >= case when (o.settings->>'reminderHour') ~ '^([0-9]|1[0-9]|2[0-2])$'
                                           then (o.settings->>'reminderHour')::int else 18 end
      and exists (select 1 from public.push_subs p where p.staff_id = sh.staff_id)
    group by sh.staff_id
  loop
    if public.push_once('rem', v_tom::text, r.staff_id) then
      v_out := v_out || public.push_msgs_for(r.staff_id, 'Domani lavori',
        upper(left(public.rush_fmt_day(v_tom, true), 1)) || substr(public.rush_fmt_day(v_tom, true), 2) || ': ' || r.times || '.', 'rem-' || v_tom);
    end if;
  end loop;
  -- pulizia del registro (oltre 120 giorni)
  delete from public.push_log where created_at < now() - interval '120 days';
  return v_out;
end;
$$;

-- Notifica di prova dalla pagina del dipendente (una al minuto).
create or replace function public.push_test_msgs(p_token uuid)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.staff where access_token = p_token and link_active;
  if v_id is null then
    raise exception 'non autorizzato';
  end if;
  if not public.push_once('test', to_char(now(), 'YYYYMMDDHH24MI'), v_id) then
    return '[]'::jsonb;
  end if;
  return public.push_msgs_for(v_id, 'Notifiche attive', 'Riceverai qui planning, risposte e promemoria.', 'test');
end;
$$;

-- Telefoni non più validi (notifiche disattivate o app disinstallata).
create or replace function public.push_gone(p_ids uuid[])
returns void language sql volatile security definer
set search_path = public
as $$ delete from public.push_subs where id = any(p_ids); $$;

-- ---------- Permessi ----------

revoke execute on function public.staff_push_subscribe(uuid, text, text, text) from public, anon, authenticated;
revoke execute on function public.staff_push_unsubscribe(uuid, text) from public, anon, authenticated;
revoke execute on function public.admin_planning_pending(uuid) from public, anon, authenticated;
revoke execute on function public.push_planning_diff(uuid) from public, anon, authenticated;
revoke execute on function public.push_msgs_for(uuid, text, text, text) from public, anon, authenticated;
revoke execute on function public.push_once(text, text, uuid) from public, anon, authenticated;
revoke execute on function public.push_user_is_admin(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.push_planning_msgs(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.push_request_msgs(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.push_swap_msgs(uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.push_reminder_msgs() from public, anon, authenticated;
revoke execute on function public.push_test_msgs(uuid) from public, anon, authenticated;
revoke execute on function public.push_gone(uuid[]) from public, anon, authenticated;

grant execute on function public.staff_push_subscribe(uuid, text, text, text) to anon, authenticated;
grant execute on function public.staff_push_unsubscribe(uuid, text) to anon, authenticated;
grant execute on function public.admin_planning_pending(uuid) to authenticated;
-- solo la funzione "notify" (chiave di servizio) costruisce e invia i messaggi
grant execute on function public.push_planning_msgs(uuid, uuid) to service_role;
grant execute on function public.push_request_msgs(uuid, uuid) to service_role;
grant execute on function public.push_swap_msgs(uuid, uuid, uuid) to service_role;
grant execute on function public.push_reminder_msgs() to service_role;
grant execute on function public.push_test_msgs(uuid) to service_role;
grant execute on function public.push_gone(uuid[]) to service_role;
grant select, insert, update, delete on public.push_subs, public.push_log, public.push_planning_state to service_role;
