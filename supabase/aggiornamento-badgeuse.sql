-- =====================================================================
-- RUSH · aggiornamento: badgeuse (timbrature da tablet con PIN)
-- Da incollare UNA volta in Supabase → SQL Editor → Run.
-- Si può rilanciare senza problemi: non cancella dati.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tabelle ----------

-- Tablet autorizzati a timbrare (uno per ristorante). Il token va nel link del tablet.
create table if not exists public.kiosks (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.orgs(id) on delete cascade,
  name        text not null default 'Tablet' check (char_length(name) between 1 and 40),
  token       uuid not null unique default gen_random_uuid(),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  last_seen   timestamptz
);
create index if not exists kiosks_org_idx on public.kiosks (org_id);
-- Il link funziona su UN solo dispositivo: il primo che lo apre (il tablet) resta collegato.
alter table public.kiosks add column if not exists device_hash text;
alter table public.kiosks add column if not exists paired_at timestamptz;

-- PIN dei dipendenti, solo cifrati (bcrypt). Nessuno può rileggerli, nemmeno l'admin.
create table if not exists public.staff_pins (
  staff_id    uuid primary key references public.staff(id) on delete cascade,
  org_id      uuid not null references public.orgs(id) on delete cascade,
  pin_hash    text not null,
  updated_at  timestamptz not null default now()
);

-- Registro delle timbrature. Non si modifica e non si cancella:
-- le correzioni sono nuove righe (source = 'admin') o annullamenti motivati.
create table if not exists public.punches (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.orgs(id) on delete cascade,
  staff_id     uuid references public.staff(id) on delete set null,   -- resta il nome anche se il dipendente viene eliminato
  staff_name   text not null,
  kind         text not null check (kind in ('in','out')),
  at           timestamptz not null default now(),                  -- ora del server, non del tablet
  source       text not null check (source in ('tablet','admin')),
  kiosk_id     uuid references public.kiosks(id) on delete set null,
  created_at   timestamptz not null default now(),
  created_by   uuid,                                                 -- admin che ha inserito la correzione
  reason       text not null default '' check (char_length(reason) <= 200),
  voided       boolean not null default false,
  voided_at    timestamptz,
  voided_by    uuid,
  void_reason  text not null default '' check (char_length(void_reason) <= 200)
);
create index if not exists punches_org_at_idx   on public.punches (org_id, at);
create index if not exists punches_staff_at_idx on public.punches (staff_id, at);

-- Tentativi di PIN, per bloccare chi prova a indovinare.
create table if not exists public.kiosk_attempts (
  kiosk_id  uuid not null,
  staff_id  uuid not null,
  at        timestamptz not null default now(),
  ok        boolean not null
);
create index if not exists kiosk_attempts_idx on public.kiosk_attempts (staff_id, at);

-- ---------- Funzioni per il tablet (link con token) ----------

-- Ultima timbratura valida di un dipendente.
create or replace function public.last_punch(p_staff uuid)
returns public.punches
language sql stable security definer
set search_path = public
as $$
  select * from public.punches where staff_id = p_staff and not voided order by at desc, created_at desc limit 1;
$$;

-- Controlla il tablet: token valido e dispositivo giusto. Il primo dispositivo che apre il link viene collegato.
drop function if exists public.kiosk_state(uuid);
drop function if exists public.kiosk_punch(uuid, uuid, text);
create or replace function public.kiosk_check(p_kiosk uuid, p_device text)
returns public.kiosks
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_k public.kiosks%rowtype;
  v_h text;
begin
  select * into v_k from public.kiosks where token = p_kiosk and active for update;
  if not found then
    return null;
  end if;
  if p_device is null or p_device !~ '^[0-9a-f]{64}$' then
    v_k.id := null; v_k.device_hash := 'x';
    return v_k;
  end if;
  v_h := encode(extensions.digest(p_device, 'sha256'), 'hex');
  if v_k.device_hash is null then
    update public.kiosks set device_hash = v_h, paired_at = now() where id = v_k.id;
    v_k.device_hash := v_h;
  elsif v_k.device_hash <> v_h then
    v_k.id := null; v_k.device_hash := 'x';    -- segnala "altro dispositivo"
  end if;
  return v_k;
end;
$$;

-- Stato del tablet: nome del locale e dipendenti, con chi è in servizio.
create or replace function public.kiosk_state(p_kiosk uuid, p_device text)
returns json
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_k public.kiosks%rowtype;
begin
  select * into v_k from public.kiosk_check(p_kiosk, p_device);
  if v_k.device_hash is null then
    return null;
  end if;
  if v_k.id is null then
    return json_build_object('error', 'device');
  end if;
  update public.kiosks set last_seen = now() where id = v_k.id;
  return json_build_object(
    'venue', coalesce((select name from public.orgs where id = v_k.org_id), ''),
    'kiosk', v_k.name,
    'now', now(),
    'staff', coalesce((
      select json_agg(json_build_object(
        'id', s.id, 'name', s.name, 'role', s.role,
        'has_pin', exists (select 1 from public.staff_pins p where p.staff_id = s.id),
        'in_since', (select case when l.kind = 'in' and l.at > now() - interval '20 hours' then l.at end
                       from public.last_punch(s.id) l))
        order by s.name)
      from public.staff s
      where s.org_id = v_k.org_id
    ), '[]'::json)
  );
end;
$$;

-- Timbratura: entrata o uscita in base all'ultima timbratura. Errori previsti restituiti come {"error": ...}.
create or replace function public.kiosk_punch(p_kiosk uuid, p_device text, p_staff uuid, p_pin text)
returns json
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_k     public.kiosks%rowtype;
  v_s     public.staff%rowtype;
  v_hash  text;
  v_last  public.punches%rowtype;
  v_kind  text;
  v_at    timestamptz;
begin
  select * into v_k from public.kiosk_check(p_kiosk, p_device);
  if v_k.device_hash is null or v_k.id is null then
    return json_build_object('error', 'tablet');
  end if;
  select * into v_s from public.staff where id = p_staff and org_id = v_k.org_id;
  if not found then
    return json_build_object('error', 'staff');
  end if;
  select pin_hash into v_hash from public.staff_pins where staff_id = v_s.id;
  if v_hash is null then
    return json_build_object('error', 'nopin');
  end if;
  delete from public.kiosk_attempts where at < now() - interval '1 day';
  if (select count(*) from public.kiosk_attempts where staff_id = v_s.id and not ok and at > now() - interval '15 minutes') >= 5
     or (select count(*) from public.kiosk_attempts where kiosk_id = v_k.id and not ok and at > now() - interval '15 minutes') >= 30 then
    return json_build_object('error', 'locked');
  end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$' or extensions.crypt(p_pin, v_hash) <> v_hash then
    insert into public.kiosk_attempts (kiosk_id, staff_id, ok) values (v_k.id, v_s.id, false);
    return json_build_object('error', 'pin');
  end if;
  insert into public.kiosk_attempts (kiosk_id, staff_id, ok) values (v_k.id, v_s.id, true);
  select * into v_last from public.last_punch(v_s.id);
  if v_last.id is not null and v_last.at > now() - interval '60 seconds' then
    return json_build_object('error', 'double', 'kind', v_last.kind, 'at', v_last.at);
  end if;
  v_kind := case when v_last.id is not null and v_last.kind = 'in' and v_last.at > now() - interval '20 hours' then 'out' else 'in' end;
  insert into public.punches (org_id, staff_id, staff_name, kind, source, kiosk_id)
  values (v_k.org_id, v_s.id, v_s.name, v_kind, 'tablet', v_k.id)
  returning at into v_at;
  update public.kiosks set last_seen = now() where id = v_k.id;
  return json_build_object('kind', v_kind, 'at', v_at, 'name', v_s.name,
                           'since', case when v_kind = 'out' then v_last.at end);
end;
$$;

-- ---------- Funzioni per l'admin ----------

create or replace function public.admin_set_pin(p_staff uuid, p_pin text)
returns boolean
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_org uuid;
begin
  select org_id into v_org from public.staff where id = p_staff;
  if v_org is null or not public.is_org_admin(v_org) then
    raise exception 'non autorizzato';
  end if;
  if p_pin is null then
    delete from public.staff_pins where staff_id = p_staff;
    return true;
  end if;
  if p_pin !~ '^[0-9]{4}$' then
    raise exception 'il PIN deve avere 4 cifre';
  end if;
  insert into public.staff_pins (staff_id, org_id, pin_hash, updated_at)
  values (p_staff, v_org, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)), now())
  on conflict (staff_id) do update set pin_hash = excluded.pin_hash, updated_at = now();
  delete from public.kiosk_attempts where staff_id = p_staff;
  return true;
end;
$$;

-- Quali dipendenti hanno un PIN (senza rivelarlo).
create or replace function public.admin_pin_status(p_org uuid)
returns json
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.is_org_admin(p_org) then
    raise exception 'non autorizzato';
  end if;
  return coalesce((select json_agg(json_build_object('staff_id', staff_id, 'updated_at', updated_at)) from public.staff_pins where org_id = p_org), '[]'::json);
end;
$$;

-- Correzione: aggiunge una timbratura dimenticata. Il motivo è obbligatorio.
create or replace function public.admin_punch_add(p_staff uuid, p_kind text, p_at timestamptz, p_reason text)
returns uuid
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_s  public.staff%rowtype;
  v_id uuid;
begin
  select * into v_s from public.staff where id = p_staff;
  if not found or not public.is_org_admin(v_s.org_id) then
    raise exception 'non autorizzato';
  end if;
  if p_kind not in ('in','out') then
    raise exception 'tipo non valido';
  end if;
  if p_at is null or p_at > now() + interval '5 minutes' or p_at < now() - interval '400 days' then
    raise exception 'orario non valido';
  end if;
  if char_length(coalesce(trim(p_reason), '')) < 3 then
    raise exception 'motivo obbligatorio';
  end if;
  insert into public.punches (org_id, staff_id, staff_name, kind, at, source, created_by, reason)
  values (v_s.org_id, v_s.id, v_s.name, p_kind, p_at, 'admin', auth.uid(), left(trim(p_reason), 200))
  returning id into v_id;
  return v_id;
end;
$$;

-- Correzione: annulla una timbratura sbagliata (resta nel registro come annullata).
create or replace function public.admin_punch_void(p_id uuid, p_reason text)
returns boolean
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_p public.punches%rowtype;
begin
  select * into v_p from public.punches where id = p_id for update;
  if not found or not public.is_org_admin(v_p.org_id) then
    raise exception 'non autorizzato';
  end if;
  if v_p.voided then
    raise exception 'già annullata';
  end if;
  if char_length(coalesce(trim(p_reason), '')) < 3 then
    raise exception 'motivo obbligatorio';
  end if;
  update public.punches set voided = true, voided_at = now(), voided_by = auth.uid(), void_reason = left(trim(p_reason), 200)
   where id = p_id;
  return true;
end;
$$;

-- ---------- Sicurezza ----------

alter table public.kiosks         enable row level security;
alter table public.staff_pins     enable row level security;
alter table public.punches        enable row level security;
alter table public.kiosk_attempts enable row level security;

drop policy if exists kiosks_all on public.kiosks;
create policy kiosks_all on public.kiosks for all to authenticated
  using (public.is_org_admin(org_id)) with check (public.is_org_admin(org_id));
drop policy if exists punches_select on public.punches;
create policy punches_select on public.punches for select to authenticated
  using (public.is_org_admin(org_id));

revoke all on public.kiosks, public.staff_pins, public.punches, public.kiosk_attempts from anon;
revoke all on public.kiosks, public.staff_pins, public.punches, public.kiosk_attempts from authenticated;
grant select, insert, update, delete on public.kiosks to authenticated;
grant select on public.punches to authenticated;     -- niente modifiche dirette: solo tramite le funzioni qui sopra

revoke execute on function public.last_punch(uuid) from public;
revoke execute on function public.kiosk_check(uuid, text) from public;
revoke execute on function public.kiosk_state(uuid, text) from public;
revoke execute on function public.kiosk_punch(uuid, text, uuid, text) from public;
revoke execute on function public.admin_set_pin(uuid, text) from public;
revoke execute on function public.admin_pin_status(uuid) from public;
revoke execute on function public.admin_punch_add(uuid, text, timestamptz, text) from public;
revoke execute on function public.admin_punch_void(uuid, text) from public;
grant  execute on function public.kiosk_state(uuid, text) to anon, authenticated;
grant  execute on function public.kiosk_punch(uuid, text, uuid, text) to anon, authenticated;
grant  execute on function public.admin_set_pin(uuid, text) to authenticated;
grant  execute on function public.admin_pin_status(uuid) to authenticated;
grant  execute on function public.admin_punch_add(uuid, text, timestamptz, text) to authenticated;
grant  execute on function public.admin_punch_void(uuid, text) to authenticated;
