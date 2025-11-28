# FX Realtime Dashboard – Twelve Data + OpenAI Vision

Proyek ini adalah **dashboard web untuk latihan trading forex** yang berjalan di **Ruby (Sinatra)** dan bisa dijalankan di **Termux (Android)** atau Linux.

Tujuan utama: membantu pengguna belajar membaca **trend, momentum, dan kondisi market** menggunakan data realtime dan komentar AI, lalu membandingkannya dengan platform seperti **OlympTrade (akun demo)**.

> ⚠️ Proyek ini **bukan robot trading** dan **bukan saran finansial**.  
> Semua fitur ditujukan untuk **EDUKASI & LATIHAN** saja.

---

## ✨ Fitur Utama

- 📡 **Data Realtime 1 Menit (1M)**
  - Mengambil data candlestick 1 menit dari [Twelve Data](https://twelvedata.com/)
  - Pair yang didukung:
    - EUR/USD
    - GBP/USD
    - USD/JPY

- 📊 **Chart Candlestick Interaktif**
  - Candlestick chart dengan:
    - Zoom in/out (scroll / pinch)
    - Pan kiri/kanan (drag)
  - Cocok untuk membaca price action di timeframe pendek.

- 🎯 **Signal & Indikator Teknis**
  - Sinyal sederhana: **BUY / SELL / HOLD** berdasarkan:
    - SMA(5)
    - SMA(20)
    - RSI(14)
  - Menampilkan:
    - Harga terakhir
    - Nilai SMA Fast & Slow
    - Nilai RSI
    - Waktu candle terakhir

- 🤖 **AI Market Insight (Data Realtime)**
  - Analisa kondisi market dari data candle:
    - Uptrend / downtrend / sideways
    - Perubahan harga ±40 candle terakhir
    - Volatilitas (rata-rata range candle)
    - Komentar edukatif untuk latihan entry (bukan sinyal finansial).

- 🖼️ **Upload Screenshot Chart + Analisa AI (OpenAI Vision)**
  - User bisa upload **screenshot chart** (misalnya dari OlympTrade akun demo).
  - Backend mengirim gambar ke **OpenAI API (Vision / Responses API)**.
  - AI memberikan komentar teks:
    - Trend
    - Momentum & volatilitas
    - Saran edukasi untuk latihan (bukan rekomendasi real account).

---

## 🧱 Teknologi

- **Backend**
  - Ruby
  - Sinatra
  - HTTParty

- **Frontend**
  - HTML, CSS
  - Chart.js
  - `chartjs-chart-financial` (candlestick)
  - `chartjs-plugin-zoom`
  - Luxon (time adapter)

- **Data & AI**
  - [Twelve Data](https://twelvedata.com/) – Forex time series
  - [OpenAI API](https://platform.openai.com/) – Vision / Responses API

---

## ⚙️ Setup & Cara Menjalankan (Termux / Linux)

### 1. Clone repository

```bash
git clone https://github.com/dixs-bot/fx-realtime-dashboard.git
cd fx-realtime-dashboard
