-- =====================================================================
-- RUSH · aggiornamento: cambi turno tra colleghi
-- Da incollare UNA volta in Supabase → SQL Editor → Run.
-- Si può rilanciare senza problemi: non cancella dati.
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
