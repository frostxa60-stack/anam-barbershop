-- ============================================================
--  ANAM BARBERSHOP — Supabase Setup (VERSI AMAN / IDEMPOTEN)
--  Bisa dijalankan berulang kali tanpa error duplicate.
--  Jalankan di Supabase → SQL Editor → Run
-- ============================================================

-- 1) TABEL (IF NOT EXISTS = aman dijalankan ulang)
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  role text not null default 'customer',
  created_at timestamptz default now()
);

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  name text,
  phone text,
  service text,
  booking_date date,
  booking_time time,
  note text,
  status text not null default 'pending',
  created_at timestamptz default now()
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  price int not null,
  emoji text,
  badge text,
  created_at timestamptz default now()
);

-- 2) TRIGGER: otomatis buat profile + role 'customer' saat daftar
--    CREATE OR REPLACE = aman dijalankan ulang
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone, role)
  values (new.id, '', '', 'customer')
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 3) ENABLE ROW LEVEL SECURITY
alter table public.profiles enable row level security;
alter table public.bookings enable row level security;
alter table public.products enable row level security;

-- helper: cek apakah user adalah staff (admin/developer)
create or replace function public.is_staff()
returns boolean language sql security definer set search_path = public as $$
  select exists(
    select 1 from public.profiles where id = auth.uid() and role in ('admin','developer')
  );
$$;

-- 4) POLICIES — drop dulu kalau ada, lalu buat ulang (anti duplicate)
drop policy if exists "profiles_self_read"    on public.profiles;
drop policy if exists "profiles_staff_read"   on public.profiles;
drop policy if exists "profiles_self_update"  on public.profiles;
drop policy if exists "profiles_staff_update" on public.profiles;
drop policy if exists "bookings_self_all"     on public.bookings;
drop policy if exists "bookings_staff_all"    on public.bookings;
drop policy if exists "products_public_read"  on public.products;
drop policy if exists "products_staff_write"  on public.products;

create policy "profiles_self_read"    on public.profiles for select using (auth.uid() = id);
create policy "profiles_staff_read"   on public.profiles for select using (public.is_staff());
create policy "profiles_self_update"  on public.profiles for update using (auth.uid() = id);
create policy "profiles_staff_update" on public.profiles for update using (public.is_staff());

create policy "bookings_self_all" on public.bookings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "bookings_staff_all" on public.bookings
  for all using (public.is_staff() or exists(select 1 from public.profiles where id=auth.uid() and role='barber'))
  with check (public.is_staff() or exists(select 1 from public.profiles where id=auth.uid() and role='barber'));

create policy "products_public_read" on public.products for select using (true);
create policy "products_staff_write" on public.products for all using (public.is_staff()) with check (public.is_staff());

-- 5) SEED PRODUK AWAL (hanya kalau tabel produk masih kosong)
do $$
begin
  if (select count(*) from public.products) = 0 then
    insert into public.products (name, description, price, emoji, badge) values
      ('Anam Matte Pomade','Hold kuat, finish matte, gak berminyak.',85000,'🧴','Best'),
      ('Hair Clay 100g','Tekstur natural untuk gaya kasual harian.',75000,'🪞',null),
      ('Shampoo Anti-Dandruff','Rambut bersih & kulit kepala sehat.',65000,'🧼',null),
      ('Aftershave Lotion','Menenangkan kulit setelah cukur.',70000,'🌫️',null),
      ('Professional Comb','Sisir anti-statis untuk fade & detail.',35000,'💇',null),
      ('Hair Tonic 150ml','Menyegarkan & menumbuhkan rambut.',60000,'💧',null),
      ('Beard Oil','Lembutkan & harumkan jenggot.',55000,'🧔',null),
      ('Starter Kit','Pomade + shampoo + sisir hemat.',160000,'🎁',null);
  end if;
end $$;

-- ============================================================
--  SETELAH DAFTAR, jadikan diri kamu ADMIN/DEVELOPER:
--  (ganti email dengan email akun Supabase kamu)
--  update public.profiles set role='developer'
--    where id = (select id from auth.users where email='emailkamu@example.com');
-- ============================================================
