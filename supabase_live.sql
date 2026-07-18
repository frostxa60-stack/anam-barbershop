-- ============================================================
--  ANAM BARBERSHOP — FITUR ANTREAN LIVE
--  Jalankan SEKALI di Supabase: SQL Editor -> paste -> Run
-- ============================================================

-- 1) Fungsi publik: HANYA kembalikan jam + status (tanpa nama/WA)
--    agar privasi pelanggan aman. SECURITY DEFINER => bypass RLS,
--    tapi cuma 2 kolom yang dikirim ke browser.
create or replace function public.get_public_bookings(p_date date)
returns table (booking_time text, status text)
language sql
security definer
set search_path = public
as $$
  select booking_time, status
  from public.bookings
  where booking_date = p_date
    and status in ('pending','confirmed')   -- hanya yang masih aktif
  order by booking_time;
$$;

grant execute on function public.get_public_bookings(date) to anon, authenticated;

-- 2) Cegah 2 booking AKTIF di jam yang SAMA (1 kursi cukur).
--    Slot otomatis "kosong" lagi kalau booking dibatalkan/selesai.
drop index if exists public.bookings_active_slot_uniq;
create unique index bookings_active_slot_uniq
  on public.bookings (booking_date, booking_time)
  where status in ('pending','confirmed');

-- 3) Aktifkan Realtime pada tabel bookings (biar update push langsung).
do $$
begin
  execute 'alter publication supabase_realtime add table public.bookings';
exception when others then null;  -- sudah terdaftar: abaikan
end $$;
