# Anam Barbershop — Web Booking + Login (Supabase)

Website barbershop statis (HTML/CSS/JS) dengan sistem login & role via Supabase.
Bisa di-deploy gratis ke GitHub Pages dan diakses pelanggan dari HP mereka.

## Fitur
- Login & Registrasi (Supabase Auth, aman)
- 4 Role: `customer` · `barber` · `admin` · `developer`
  - customer  → booking tersimpan, lihat riwayat sendiri
  - barber    → lihat antrian booking + ubah status
  - admin     → kelola booking, produk (tambah/hapus), user/role
  - developer → sama seperti admin (level tertinggi)
- Katalog produk dari database (bisa ditambah lewat dashboard admin)
- Booking via WhatsApp sebagai alternatif tanpa login
- Estetika barbershop premium 2026 (void-black + amber)

## File
- `index.html`          → web utama (GANTI Supabase URL & key di dalamnya)
- `supabase_setup.sql`  → jalankan di Supabase SQL Editor
- `portfolio.html`      → versi statis lama (tanpa login), bisa diabaikan

## Cara Setup (5 menit)

### 1. Buat project Supabase
- Buka https://supabase.com → New Project (gratis)
- Tunggu siap, lalu buka **SQL Editor**

### 2. Jalankan SQL setup
- Copy isi `supabase_setup.sql`, paste ke SQL Editor, klik **Run**
- Ini membuat tabel `profiles`, `bookings`, `products`, trigger otomatis,
  keamanan (RLS), dan mengisi 8 produk awal.

### 3. Ambil kredensial
- Di Supabase: **Project Settings → API**
- Copy: **Project URL** dan **anon public key**

### 4. Isi ke index.html
Cari bagian paling atas di `<script>`:
```
const SUPABASE_URL = 'https://YOUR-PROJECT-REF.supabase.co';
const SUPABASE_ANON = 'YOUR-ANON-KEY';
```
Ganti dengan URL & key kamu. Simpan.

### 5. Jadikan diri kamu admin/developer
Di Supabase SQL Editor, jalankan (ganti email):
```sql
update public.profiles set role='developer'
where id = (select id from auth.users where email='emailkamu@example.com');
```
(Lakukan SETELAH kamu daftar lewat web supaya profilnya sudah ada.)

### 6. Tes lokal
Jangan buka pakai `file://`. Jalankan server lokal lalu buka di browser:
```
cd ~
python3 -m http.server 8080
```
Buka http://localhost:8080/index.html → Daftar → cek email verifikasi → Masuk.

> Tip: di Supabase **Auth → Providers → Email**, bisa matikan
> "Confirm email" agar langsung bisa login tanpa verifikasi (untuk testing).

## Deploy ke GitHub Pages
1. Buat repo GitHub, upload `index.html` (dan file lain jika perlu).
2. Repo → Settings → Pages → Source: `main` branch, folder `/root`.
3. Tunggu beberapa menit → situs live di `https://username.github.io/repo`.
4. Pelanggan buka link itu, daftar, dan booking dari HP mereka.

## Catatan Keamanan
- Kunci `anon` aman untuk di-publish karena dibatasi oleh RLS (Row Level Security).
- Jangan pernah memasukkan `service_role` key ke frontend.
- Role hanya bisa diubah oleh admin/developer lewat dashboard (dibatasi RLS).
