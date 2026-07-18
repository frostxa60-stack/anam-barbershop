-- ============================================================
--  ANAM BARBERSHOP — UPGRADE V2 (2026 modern security)
--  Idempoten. Aman dijalankan berulang kali.
--  Jalankan di Supabase → SQL Editor → paste → Run
--
--  Yang diperbaiki/ditambah:
--   1. CEGAH ROLE ESCALATION (customer gak bisa jadiin diri admin/developer)
--   2. Customer hanya bisa BATALKAN booking sendiri (gak bisa set status lain)
--   3. Validasi input booking (tanggal gak boleh lewat, jam 09:00–17:00)
--   4. Tabel audit_log (siapa ngapain kapan)
--   5. RPC create_booking() — input validation server-side
--   6. RPC cancel_my_booking() — pembatalan aman
--   7. RPC set_user_role() — hanya developer yang bisa ubah role
--   8. Trigger guard_profile_role / guard_booking_update
-- ============================================================

-- ============================================================
-- 1) AUDIT LOG TABLE (append-only, hanya staff yang baca)
-- ============================================================
create table if not exists public.audit_log (
  id bigserial primary key,
  actor uuid references auth.users(id) on delete set null,
  action text not null,
  table_name text not null,
  row_id text,
  old jsonb,
  new jsonb,
  created_at timestamptz default now()
);
alter table public.audit_log enable row level security;
drop policy if exists "audit_staff_read" on public.audit_log;
create policy "audit_staff_read" on public.audit_log
  for select using (public.is_staff());
-- Tidak ada policy INSERT untuk user langsung — hanya via SECURITY DEFINER fn
revoke insert on public.audit_log from anon, authenticated;

-- ============================================================
-- 2) HELPER: log_action() — SECURITY DEFINER (bypass RLS untuk insert audit)
-- ============================================================
create or replace function public.log_action(p_action text, p_table text, p_row_id text, p_old jsonb default null, p_new jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_log (actor, action, table_name, row_id, old, new)
  values (auth.uid(), p_action, p_table, p_row_id, p_old, p_new);
exception when others then null; -- audit gagal gak boleh block operasi utama
end; $$;

-- ============================================================
-- 3) GUARD: cegah role escalation
--    Customer gak bisa ubah role sendiri jadi admin/developer.
--    Hanya admin/developer yang bisa ubah role user lain.
-- ============================================================
create or replace function public.guard_profile_role()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  caller_role text;
begin
  -- Kalau role berubah, cek hak
  if new.role is distinct from old.role then
    select role into caller_role from public.profiles where id = auth.uid();
    if caller_role not in ('admin','developer') then
      raise exception 'Akses ditolak: hanya admin/developer yang dapat mengubah role';
    end if;
    -- log perubahan role
    perform public.log_action('role_change','profiles',new.id::text,
      jsonb_build_object('role',old.role), jsonb_build_object('role',new.role));
  end if;
  return new;
end; $$;

drop trigger if exists trg_guard_profile_role on public.profiles;
create trigger trg_guard_profile_role
  before update of role on public.profiles
  for each row execute function public.guard_profile_role();

-- ============================================================
-- 4) GUARD: validasi insert booking
--    - booking_date tidak boleh di masa lalu
--    - booking_time harus 09:00–17:00 (jam buka)
--    - user_id harus = auth.uid()
--    - status baru harus 'pending'
-- ============================================================
create or replace function public.validate_booking_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  caller_role text;
begin
  -- staff/barber boleh insert untuk testing/manual, tapi user_id harus = caller
  if new.user_id is distinct from auth.uid() then
    select role into caller_role from public.profiles where id = auth.uid();
    if caller_role not in ('admin','developer') then
      raise exception 'Akses ditolak: user_id harus sama dengan akun login';
    end if;
  end if;
  -- tanggal tidak boleh lewat
  if new.booking_date < current_date then
    raise exception 'Tanggal booking tidak boleh di masa lalu';
  end if;
  -- jam harus 09:00–17:00
  if new.booking_time::text < '09:00' or new.booking_time::text > '17:00' then
    raise exception 'Jam booking harus antara 09:00 dan 17:00';
  end if;
  -- status default 'pending'
  if new.status is null or new.status = '' then new.status := 'pending'; end if;
  if new.status <> 'pending' then
    raise exception 'Booking baru harus berstatus pending';
  end if;
  return new;
end; $$;

drop trigger if exists trg_validate_booking_insert on public.bookings;
create trigger trg_validate_booking_insert
  before insert on public.bookings
  for each row execute function public.validate_booking_insert();

-- ============================================================
-- 5) GUARD: update booking
--    Customer hanya bisa MEMBATALKAN booking sendiri (pending/confirmed → cancelled)
--    Staff/barber bebas update status
-- ============================================================
create or replace function public.guard_booking_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  caller_role text;
  is_owner boolean;
begin
  if auth.uid() is null then
    raise exception 'Akses ditolak: harus login';
  end if;
  select role into caller_role from public.profiles where id = auth.uid();
  is_owner := (old.user_id = auth.uid());

  -- staff/barber bebas update
  if caller_role in ('admin','developer','barber') then
    perform public.log_action('status_update','bookings',old.id::text,
      jsonb_build_object('status',old.status), jsonb_build_object('status',new.status));
    return new;
  end if;

  -- owner hanya bisa batal, dan cuma dari pending/confirmed
  if is_owner then
    if new.status = 'cancelled' and old.status in ('pending','confirmed')
       and new.user_id = old.user_id
       and new.booking_date = old.booking_date
       and new.booking_time = old.booking_time
       and new.service = old.service then
      perform public.log_action('cancel','bookings',old.id::text,
        jsonb_build_object('status',old.status), jsonb_build_object('status','cancelled'));
      return new;
    end if;
    raise exception 'Pelanggan hanya dapat membatalkan booking sendiri (status: pending/confirmed)';
  end if;

  raise exception 'Akses ditolak: bukan pemilik booking ini';
end; $$;

drop trigger if exists trg_guard_booking_update on public.bookings;
create trigger trg_guard_booking_update
  before update on public.bookings
  for each row execute function public.guard_booking_update();

-- ============================================================
-- 6) GUARD: delete booking
--    Hanya staff yang boleh hapus (customer tidak bisa hapus riwayat)
-- ============================================================
create or replace function public.guard_booking_delete()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  caller_role text;
begin
  select role into caller_role from public.profiles where id = auth.uid();
  if caller_role not in ('admin','developer') then
    raise exception 'Akses ditolak: hanya admin/developer yang dapat menghapus booking';
  end if;
  perform public.log_action('delete','bookings',old.id::text,
    to_jsonb(old), null);
  return old;
end; $$;

drop trigger if exists trg_guard_booking_delete on public.bookings;
create trigger trg_guard_booking_delete
  before delete on public.bookings
  for each row execute function public.guard_booking_delete();

-- ============================================================
-- 7) GUARD: products — hanya staff tulis (sudah ada RLS, double protection)
-- ============================================================
create or replace function public.guard_product_write()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  caller_role text;
begin
  select role into caller_role from public.profiles where id = auth.uid();
  if caller_role not in ('admin','developer') then
    raise exception 'Akses ditolak: hanya admin/developer yang dapat mengelola produk';
  end if;
  if TG_OP = 'DELETE' then
    perform public.log_action('delete','products',old.id::text,to_jsonb(old),null);
    return old;
  end if;
  if TG_OP = 'UPDATE' then
    perform public.log_action('update','products',new.id::text,to_jsonb(old),to_jsonb(new));
    return new;
  end if;
  perform public.log_action('insert','products',new.id::text,null,to_jsonb(new));
  return new;
end; $$;

drop trigger if exists trg_guard_product_insert on public.products;
create trigger trg_guard_product_insert
  before insert on public.products
  for each row execute function public.guard_product_write();
drop trigger if exists trg_guard_product_update on public.products;
create trigger trg_guard_product_update
  before update on public.products
  for each row execute function public.guard_product_write();
drop trigger if exists trg_guard_product_delete on public.products;
create trigger trg_guard_product_delete
  before delete on public.products
  for each row execute function public.guard_product_write();

-- ============================================================
-- 8) RPC: create_booking() — input validation server-side
--    Frontend bisa panggil ini sebagai alternatif insert langsung.
-- ============================================================
create or replace function public.create_booking(
  p_name text,
  p_phone text,
  p_service text,
  p_booking_date date,
  p_booking_time time,
  p_note text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  new_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Harus login terlebih dahulu';
  end if;
  if p_booking_date < current_date then
    raise exception 'Tanggal booking tidak boleh di masa lalu';
  end if;
  if p_booking_time::text < '09:00' or p_booking_time::text > '17:00' then
    raise exception 'Jam booking harus 09:00–17:00';
  end if;
  insert into public.bookings (user_id, name, phone, service, booking_date, booking_time, note, status)
    values (auth.uid(), p_name, p_phone, p_service, p_booking_date, p_booking_time, p_note, 'pending')
    returning id into new_id;
  perform public.log_action('create','bookings',new_id::text,null,
    jsonb_build_object('service',p_service,'date',p_booking_date,'time',p_booking_time));
  return new_id;
end; $$;

grant execute on function public.create_booking(text,text,text,date,time,text) to authenticated;

-- ============================================================
-- 9) RPC: cancel_my_booking() — pembatalan aman oleh owner
-- ============================================================
create or replace function public.cancel_my_booking(p_booking_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  bk record;
  caller_role text;
begin
  select * into bk from public.bookings where id = p_booking_id;
  if not found then
    raise exception 'Booking tidak ditemukan';
  end if;
  select role into caller_role from public.profiles where id = auth.uid();
  -- owner atau staff
  if bk.user_id = auth.uid() or caller_role in ('admin','developer','barber') then
    if bk.status not in ('pending','confirmed') then
      raise exception 'Booking dengan status % tidak dapat dibatalkan', bk.status;
    end if;
    update public.bookings set status = 'cancelled' where id = p_booking_id;
    return true;
  end if;
  raise exception 'Akses ditolak: bukan pemilik booking';
end; $$;

grant execute on function public.cancel_my_booking(uuid) to authenticated;

-- ============================================================
-- 10) RPC: set_user_role() — hanya developer
-- ============================================================
create or replace function public.set_user_role(p_user_id uuid, p_role text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  caller_role text;
  valid_roles text[] := array['customer','barber','admin','developer'];
begin
  select role into caller_role from public.profiles where id = auth.uid();
  if caller_role <> 'developer' then
    raise exception 'Akses ditolak: hanya developer yang dapat mengubah role user';
  end if;
  if not (p_role = any(valid_roles)) then
    raise exception 'Role tidak valid: %', p_role;
  end if;
  update public.profiles set role = p_role where id = p_user_id;
  return true;
end; $$;

grant execute on function public.set_user_role(uuid,text) to authenticated;

-- ============================================================
-- 11) INDEX untuk audit_log (query cepat)
-- ============================================================
create index if not exists audit_log_created_at_idx on public.audit_log (created_at desc);
create index if not exists audit_log_actor_idx on public.audit_log (actor);
create index if not exists audit_log_table_idx on public.audit_log (table_name);

-- ============================================================
-- 12) Update RLS policies bookings (perketat)
--    - Customer: INSERT own, SELECT own, UPDATE own (trigger batasi cancel only)
--    - Barber: SELECT all, UPDATE status only (trigger cek)
--    - Staff: SELECT/INSERT/UPDATE/DELETE all
-- ============================================================
drop policy if exists "bookings_self_all" on public.bookings;
drop policy if exists "bookings_staff_all" on public.bookings;

-- Customer: baca & insert & update booking sendiri (delete via trigger block)
create policy "bookings_self_select" on public.bookings
  for select using (auth.uid() = user_id);
create policy "bookings_self_insert" on public.bookings
  for insert with check (auth.uid() = user_id);
create policy "bookings_self_update" on public.bookings
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Barber: lihat semua booking, update status
create policy "bookings_barber_select" on public.bookings
  for select using (exists(select 1 from public.profiles where id=auth.uid() and role='barber'));
create policy "bookings_barber_update" on public.bookings
  for update using (exists(select 1 from public.profiles where id=auth.uid() and role='barber'));

-- Staff: akses penuh
create policy "bookings_staff_select" on public.bookings
  for select using (public.is_staff());
create policy "bookings_staff_insert" on public.bookings
  for insert with check (public.is_staff());
create policy "bookings_staff_update" on public.bookings
  for update using (public.is_staff());
create policy "bookings_staff_delete" on public.bookings
  for delete using (public.is_staff());

-- ============================================================
-- 13) Realtime: aktifkan juga untuk audit_log (opsional, biar admin live-lihat)
-- ============================================================
do $$
begin
  execute 'alter publication supabase_realtime add table public.audit_log';
exception when others then null;
end $$;

-- ============================================================
-- SELESAI. Verifikasi cepat:
--   select count(*) from public.audit_log;          -- 0 awalnya
--   select proname from pg_proc where proname in ('create_booking','cancel_my_booking','set_user_role','log_action');
-- ============================================================
