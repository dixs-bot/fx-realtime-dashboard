# app.rb
require "sinatra"
require "net/http"
require "json"
require "time"
require "uri"

set :bind, "0.0.0.0"
set :port, 4567

TWELVE_KEY = ENV["TWELVEDATA_KEY"]
OPENAI_KEY = ENV["OPENAI_API_KEY"]

# ====================== HELPERS ==========================
helpers do
  # Ambil data candle dari TwelveData
  def fetch_candles(pair_code = "EUR/USD", interval = "1min", limit = 200)
    return [] unless TWELVE_KEY

    uri = URI("https://api.twelvedata.com/time_series")
    params = {
      symbol: pair_code,
      interval: interval,
      outputsize: limit,
      format: "JSON",
      apikey: TWELVE_KEY
    }
    uri.query = URI.encode_www_form(params)

    res = Net::HTTP.get_response(uri)
    puts "TWELVEDATA HTTP #{res.code}"
    return [] unless res.is_a?(Net::HTTPSuccess)

    body = JSON.parse(res.body) rescue nil
    return [] unless body && body["values"]

    body["values"].map do |row|
      {
        time:  Time.parse(row["datetime"]),
        open:  row["open"].to_f,
        high:  row["high"].to_f,
        low:   row["low"].to_f,
        close: row["close"].to_f
      }
    end.reverse # urut dari lama ke terbaru
  end

  # ========= Indikator dasar =========
  def sma(values, length)
    return nil if values.size < length
    values.last(length).sum / length.to_f
  end

  def rsi(values, length = 14)
    return nil if values.size < length + 1
    gains = []
    losses = []
    values.each_cons(2) do |a, b|
      change = b - a
      if change >= 0
        gains << change
      else
        losses << change.abs
      end
    end
    avg_gain = gains.last(length).sum / length.to_f
    avg_loss = losses.last(length).sum / length.to_f
    return 50.0 if avg_loss.zero?

    rs = avg_gain / avg_loss
    100 - (100 / (1 + rs))
  end

  def atr(candles, length = 14)
    return nil if candles.size < length + 1
    trs = []
    (1...candles.size).each do |i|
      h = candles[i][:high]
      l = candles[i][:low]
      pc = candles[i - 1][:close]
      tr = [h - l, (h - pc).abs, (l - pc).abs].max
      trs << tr
    end
    trs.last(length).sum / length.to_f
  end

  def bollinger_band(values, length = 20, mult = 2.0)
    return nil if values.size < length
    slice = values.last(length)
    mean = slice.sum / length.to_f
    variance = slice.map { |v| (v - mean) ** 2 }.sum / length.to_f
    stddev = Math.sqrt(variance)
    {
      middle: mean,
      upper:  mean + mult * stddev,
      lower:  mean - mult * stddev
    }
  end

  # ========= Market Structure HH / HL / LH / LL =========
  def detect_market_structure(candles, sens = 2)
    return {
      trend: "unknown",
      bias: "neutral",
      points: [],
      swings: [],
      comment: "Belum cukup data untuk membaca struktur market."
    } if candles.size < sens * 2 + 5

    swings = []

    (sens...(candles.size - sens)).each do |i|
      c = candles[i]
      left = candles[i - sens]
      right = candles[i + sens]

      # swing high
      if c[:high] > left[:high] && c[:high] > right[:high]
        swings << {
          type:  "swing_high",
          time:  c[:time],
          price: c[:high].to_f,
          index: i
        }
      end

      # swing low
      if c[:low] < left[:low] && c[:low] < right[:low]
        swings << {
          type:  "swing_low",
          time:  c[:time],
          price: c[:low].to_f,
          index: i
        }
      end
    end

    swings.sort_by! { |s| s[:index] }

    points = []
    last_high = nil
    last_low  = nil

    swings.each do |s|
      if s[:type] == "swing_high"
        label =
          if last_high.nil?
            "H"
          else
            s[:price].to_f > last_high[:price].to_f ? "HH" : "LH"
          end
        last_high = s
      else
        label =
          if last_low.nil?
            "L"
          else
            s[:price].to_f > last_low[:price].to_f ? "HL" : "LL"
          end
        last_low = s
      end

      points << s.merge(label: label)
    end

    recent_labels = points.last(8).map { |p| p[:label] }

    up_count   = recent_labels.count("HH") + recent_labels.count("HL")
    down_count = recent_labels.count("LH") + recent_labels.count("LL")

    trend =
      if up_count >= 4 && up_count > down_count
        "uptrend"
      elsif down_count >= 4 && down_count > up_count
        "downtrend"
      else
        "sideways"
      end

    bias, comment =
      case trend
      when "uptrend"
        [
          "buy_bias",
          "Struktur market didominasi HH & HL (uptrend). Latihan: fokus cari peluang BUY setelah koreksi ke area support/SNR, jangan kejar SELL melawan trend."
        ]
      when "downtrend"
        [
          "sell_bias",
          "Struktur market didominasi LH & LL (downtrend). Latihan: fokus cari peluang SELL di area resistance/pullback lemah, hindari BUY melawan arus."
        ]
      else
        [
          "neutral",
          "Struktur market cenderung sideways. Latihan: perhatikan batas atas–bawah range, jangan agresif entry di tengah."
        ]
      end

    {
      trend: trend,
      bias: bias,
      points: points,
      swings: swings,
      comment: comment
    }
  end

  # ========= SNR dari swing label =========
  def build_snr_from_structure(structure)
    points = structure[:points]
    return [] if points.nil? || points.empty?

    key = points.last(6)
    key.map do |p|
      {
        type:  p[:label],
        price: p[:price].to_f,
        time:  p[:time]
      }
    end
  end

  # ========= Break of Structure (BOS) =========
  def detect_bos(structure)
    points = structure[:points]
    return {
      status: "none",
      direction: "none",
      label: nil,
      price: nil,
      time: nil,
      note: "Belum ada swing signifikan untuk membaca BOS."
    } if points.nil? || points.empty?

    last = points.last

    case last[:label]
    when "HH"
      {
        status: "bos_up",
        direction: "up",
        label: last[:label],
        price: last[:price].to_f,
        time:  last[:time],
        note:  "Harga membentuk Higher High baru → indikasi break struktur ke atas (bullish BOS). Latihan: perhatikan peluang BUY setelah koreksi wajar."
      }
    when "LL"
      {
        status: "bos_down",
        direction: "down",
        label: last[:label],
        price: last[:price].to_f,
        time:  last[:time],
        note:  "Harga membentuk Lower Low baru → indikasi break struktur ke bawah (bearish BOS). Latihan: perhatikan peluang SELL setelah pullback lemah."
      }
    else
      {
        status: "none",
        direction: "none",
        label: last[:label],
        price: last[:price].to_f,
        time:  last[:time],
        note:  "Swing terakhir belum HH atau LL. Belum ada BOS jelas, tunggu struktur berikutnya."
      }
    end
  end

  # ========= Deteksi Pola Candlestick (Engulfing, Pin Bar) =========
  def detect_candle_pattern(candles)
    return {
      name: "Tidak ada pola kuat",
      direction: "neutral",
      confidence: 0.0,
      note: "Belum terbentuk pola candlestick yang kuat untuk latihan entry."
    } if candles.size < 3

    c0 = candles[-1] # terakhir
    c1 = candles[-2] # sebelumnya

    body0 = (c0[:close] - c0[:open]).abs
    body1 = (c1[:close] - c1[:open]).abs

    bull0 = c0[:close] > c0[:open]
    bear0 = c0[:close] < c0[:open]
    bull1 = c1[:close] > c1[:open]
    bear1 = c1[:close] < c1[:open]

    # Bullish Engulfing
    if bull0 && bear1 &&
       c0[:close] >= [c1[:close], c1[:open]].max &&
       c0[:open]  <= [c1[:close], c1[:open]].min &&
       body0 > body1 * 1.1
      return {
        name: "Bullish Engulfing",
        direction: "bullish",
        confidence: 0.8,
        note: "Bullish engulfing di akhir penurunan → potensi pembalikan naik. Latihan: perhatikan konfirmasi di candle berikutnya & posisi relatif terhadap SNR."
      }
    end

    # Bearish Engulfing
    if bear0 && bull1 &&
       c0[:close] <= [c1[:close], c1[:open]].min &&
       c0[:open]  >= [c1[:close], c1[:open]].max &&
       body0 > body1 * 1.1
      return {
        name: "Bearish Engulfing",
        direction: "bearish",
        confidence: 0.8,
        note: "Bearish engulfing di akhir kenaikan → potensi pembalikan turun. Latihan: lihat respon harga di SNR / area premium sebelum entry."
      }
    end

    # Bullish Pin Bar (lower wick panjang)
    lower_wick = c0[:open] < c0[:close] ? (c0[:open] - c0[:low]).abs : (c0[:close] - c0[:low]).abs
    upper_wick = c0[:high] - [c0[:open], c0[:close]].max
    if lower_wick > body0 * 2.0 && lower_wick > upper_wick * 1.5
      return {
        name: "Bullish Pin Bar",
        direction: "bullish",
        confidence: 0.6,
        note: "Bullish pin bar (ekor bawah panjang) → penolakan harga dari bawah. Latihan: gunakan sebagai konfirmasi BUY dekat support/SNR, bukan di tengah range."
      }
    end

    # Bearish Pin Bar (upper wick panjang)
    upper_wick2 = c0[:high] - [c0[:open], c0[:close]].max
    lower_wick2 = [c0[:open], c0[:close]].min - c0[:low]
    if upper_wick2 > body0 * 2.0 && upper_wick2 > lower_wick2 * 1.5
      return {
        name: "Bearish Pin Bar",
        direction: "bearish",
        confidence: 0.6,
        note: "Bearish pin bar (ekor atas panjang) → penolakan harga dari atas. Latihan: jadikan sinyal SELL di dekat resistance/SNR, hindari SELL di support."
      }
    end

    {
      name: "Tidak ada pola kuat",
      direction: "neutral",
      confidence: 0.0,
      note: "Belum ada pola engulfing / pin bar yang jelas. Latihan: fokus dulu pada struktur (trend, BOS, SNR) sebelum mengandalkan candlestick."
    }
  end

  # ========= AI Confluence =========
  def build_confluence(trend_signal, structure, bos, indicators, pattern)
    score = 50.0
    reasons = []

    # arah dasar dari MA
    if trend_signal == "BUY"
      score += 8
      reasons << "SMA cepat di atas SMA lambat → bias BUY."
    elsif trend_signal == "SELL"
      score -= 8
      reasons << "SMA cepat di bawah SMA lambat → bias SELL."
    else
      reasons << "SMA belum jelas → WAIT."
    end

    # trend struktur
    case structure[:trend]
    when "uptrend"
      score += 10
      reasons << "Struktur HH & HL dominan (uptrend)."
    when "downtrend"
      score -= 10
      reasons << "Struktur LH & LL dominan (downtrend)."
    else
      reasons << "Struktur sideways, perlu ekstra hati-hati."
    end

    # BOS
    if bos[:status] == "bos_up"
      score += 7
      reasons << "Terjadi BOS ke atas (Higher High baru)."
    elsif bos[:status] == "bos_down"
      score -= 7
      reasons << "Terjadi BOS ke bawah (Lower Low baru)."
    end

    rsi_val = indicators[:rsi]
    if rsi_val
      if rsi_val > 55
        score += 4
        reasons << "RSI di atas 55 → momentum cenderung bullish."
      elsif rsi_val < 45
        score -= 4
        reasons << "RSI di bawah 45 → momentum cenderung bearish."
      else
        reasons << "RSI di area tengah → momentum moderat."
      end
    end

    if indicators[:bb]
      price = indicators[:price] || 0.0
      mid   = indicators[:bb][:middle]
      if price > mid
        score += 2
        reasons << "Harga berada di atas mid BB (cenderung sisi atas)."
      elsif price < mid
        score -= 2
        reasons << "Harga berada di bawah mid BB (cenderung sisi bawah)."
      end
    end

    case pattern[:direction]
    when "bullish"
      score += (pattern[:confidence] * 10.0)
      reasons << "Pola candlestick bullish terdeteksi (#{pattern[:name]})."
    when "bearish"
      score -= (pattern[:confidence] * 10.0)
      reasons << "Pola candlestick bearish terdeteksi (#{pattern[:name]})."
    end

    score = [[score, 0].max, 100].min

    side, label =
      if score >= 80
        base = trend_signal == "SELL" ? "Strong Sell" : "Strong Buy"
        [trend_signal == "SELL" ? "sell" : "buy", base]
      elsif score >= 60
        base = trend_signal == "SELL" ? "Weak Sell" : "Weak Buy"
        [trend_signal == "SELL" ? "sell" : "buy", base]
      elsif score > 40
        ["neutral", "Netral / seimbang"]
      else
        alt = (trend_signal == "BUY" ? "sell" : trend_signal == "SELL" ? "buy" : "sell")
        [alt, "Setup lemah (hindari entry agresif)"]
      end

    coaching =
      case side
      when "buy"
        "Gunakan sinyal ini sebagai latihan mencari BUY searah trend, utamakan entry setelah koreksi ke SNR / support yang jelas."
      when "sell"
        "Gunakan sinyal ini sebagai latihan mencari SELL searah trend, perhatikan area resistance / zona premium sebelum entry."
      else
        "Gunakan momen ini untuk mengamati struktur market tanpa entry dulu. Latihan: tandai SNR & tunggu confluence yang lebih kuat."
      end

    {
      score: score.round(1),
      side: side,
      label: label,
      reasons: reasons,
      coaching: coaching
    }
  end
end

# ========================== API SIGNAL =============================

get "/signal" do
  content_type :json

  pair_param = params["pair"] || "EURUSD"
  tf_param   = params["tf"]   || "1min"

  pair_code =
    case pair_param.upcase
    when "EURUSD" then "EUR/USD"
    when "GBPUSD" then "GBP/USD"
    when "USDJPY" then "USD/JPY"
    else pair_param
    end

  # batasi interval ke yang kita izinkan
  interval =
    case tf_param
    when "1min", "5min", "15min"
      tf_param
    else
      "1min"
    end

  candles = fetch_candles(pair_code, interval, 200)
  halt 500, { error: "Tidak bisa ambil data candle" }.to_json if candles.empty?

  closes = candles.map { |c| c[:close] }

  sma_fast = sma(closes, 7)
  sma_slow = sma(closes, 25)
  rsi_val  = rsi(closes, 14)
  atr_val  = atr(candles, 14)
  bb       = bollinger_band(closes, 20, 2.0)

  trend_signal =
    if sma_fast && sma_slow
      if sma_fast > sma_slow
        "BUY"
      elsif sma_fast < sma_slow
        "SELL"
      else
        "WAIT"
      end
    else
      "WAIT"
    end

  structure   = detect_market_structure(candles)
  snr_levels  = build_snr_from_structure(structure)
  bos_info    = detect_bos(structure)
  pattern     = detect_candle_pattern(candles)

  indicators_hash = {
    sma_fast: sma_fast,
    sma_slow: sma_slow,
    rsi:      rsi_val,
    atr:      atr_val,
    bb:       bb,
    price:    closes.last
  }

  confluence = build_confluence(trend_signal, structure, bos_info, indicators_hash, pattern)

  {
    pair: pair_code,
    timeframe: interval,
    last_price: closes.last,
    last_time: candles.last[:time],
    signal: trend_signal,
    indicators: indicators_hash,
    structure: structure,
    snr:       snr_levels,
    bos:       bos_info,
    pattern:   pattern,
    confluence: confluence,
    candles:   candles
  }.to_json
end

# ========================== API AI INSIGHT =============================

post "/ai_insight" do
  content_type :json
  halt 400, { error: "OPENAI_API_KEY belum diset di environment." }.to_json unless OPENAI_KEY

  body = request.body.read
  payload = JSON.parse(body) rescue {}

  signal      = payload["signal"]
  indicators  = payload["indicators"] || {}
  structure   = payload["structure"]  || {}
  bos         = payload["bos"]        || {}
  pattern     = payload["pattern"]    || {}
  confluence  = payload["confluence"] || {}
  pair        = payload["pair"]       || "EUR/USD"
  timeframe   = payload["timeframe"]  || "1min"

  summary_text = <<~TXT
    Pair: #{pair}, Timeframe: #{timeframe}
    Sinyal indikator utama: #{signal}
    RSI: #{indicators["rsi"]}, ATR: #{indicators["atr"]}, SMA cepat: #{indicators["sma_fast"]}, SMA lambat: #{indicators["sma_slow"]}
    Bollinger Band mid: #{indicators.dig("bb", "middle")}, upper: #{indicators.dig("bb", "upper")}, lower: #{indicators.dig("bb", "lower")}

    Market structure:
    - Trend: #{structure["trend"]}
    - Bias: #{structure["bias"]}
    - Komentar struktur: #{structure["comment"]}

    Break of Structure (BOS):
    - Status: #{bos["status"]}
    - Direction: #{bos["direction"]}
    - Note: #{bos["note"]}

    Pola candlestick:
    - Nama pola: #{pattern["name"]}
    - Arah: #{pattern["direction"]}
    - Confidence: #{pattern["confidence"]}
    - Catatan pola: #{pattern["note"]}

    Confluence engine:
    - Score: #{confluence["score"]}
    - Label: #{confluence["label"]}
    - Side: #{confluence["side"]}
    - Coaching: #{confluence["coaching"]}
  TXT

  uri = URI("https://api.openai.com/v1/chat/completions")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  headers = {
    "Content-Type"  => "application/json",
    "Authorization" => "Bearer #{OPENAI_KEY}"
  }

  request_body = {
    model: "gpt-4.1-mini",
    messages: [
      {
        role: "system",
        content: "Kamu adalah asisten trading berbahasa Indonesia. Fokus edukasi, bukan sinyal pasti profit. Jelaskan kondisi market sederhana, sebutkan hal yang perlu diperhatikan, dan berikan saran latihan (bukan ajakan open posisi). Hindari janji profit, hanya bahas probabilitas & pembelajaran."
      },
      {
        role: "user",
        content: "Berikan analisa edukatif berdasarkan ringkasan data berikut (struktur market, indikator, BOS, pola candlestick, dan confluence) untuk latihan membaca market:\n\n#{summary_text}"
      }
    ],
    temperature: 0.7
  }

  req = Net::HTTP::Post.new(uri.request_uri, headers)
  req.body = request_body.to_json

  begin
    res = http.request(req)
    unless res.is_a?(Net::HTTPSuccess)
      halt 500, { error: "Gagal memanggil OpenAI", details: res.body }.to_json
    end

    data = JSON.parse(res.body) rescue nil
    ai_text =
      if data && data["choices"] && data["choices"][0] && data["choices"][0]["message"]
        data["choices"][0]["message"]["content"]
      else
        "AI tidak mengembalikan respons yang bisa dibaca."
      end

    { ai_comment: ai_text }.to_json
  rescue => e
    halt 500, { error: "Error saat memanggil OpenAI", details: e.message }.to_json
  end
end

# ========================== FRONTEND DASHBOARD =============================

get "/" do
  <<~HTML
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="UTF-8">
    <title>FX Realtime AI Coach</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
      body {
        margin: 0;
        padding: 12px;
        font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        background: #050510;
        color: #f5f5f5;
      }
      .card {
        background: radial-gradient(circle at top, #1b2236, #050510);
        border-radius: 16px;
        padding: 14px 14px 10px 14px;
        margin-bottom: 12px;
        border: 1px solid rgba(255,255,255,0.05);
        box-shadow: 0 0 20px rgba(0,0,0,0.6);
      }
      .title-main {
        font-size: 18px;
        font-weight: 700;
        letter-spacing: 0.08em;
        text-transform: uppercase;
        text-align: center;
        color: #00ffe7;
        margin-bottom: 6px;
      }
      .subtitle {
        text-align: center;
        font-size: 11px;
        color: #9ba7ff;
        margin-bottom: 10px;
      }
      .btn {
        width: 100%;
        padding: 10px;
        border-radius: 999px;
        border: 1px solid #ff004c;
        background: linear-gradient(90deg,#ff004c,#ff6600);
        color: #fff;
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: .08em;
        box-shadow: 0 0 12px rgba(255,0,76,0.6);
      }
      .btn:active {
        transform: scale(0.98);
        opacity: 0.9;
      }
      .label {
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: .12em;
        color: #7c8cff;
      }
      .value {
        font-size: 14px;
        font-weight: 600;
      }
      .pill {
        display:inline-block;
        padding: 2px 8px;
        border-radius: 999px;
        font-size: 10px;
        text-transform: uppercase;
        letter-spacing: .14em;
      }
      .pill-buy { background: rgba(0,255,150,0.08); border:1px solid #00ff96; color:#00ffb7; }
      .pill-sell { background: rgba(255,0,90,0.08); border:1px solid #ff3377; color:#ff5b98; }
      .pill-wait { background: rgba(255,255,255,0.03); border:1px solid #999; color:#ccc; }
      .grid-2 {
        display:grid;
        grid-template-columns: 1fr 1fr;
        gap: 10px;
      }
      .mono { font-family: "JetBrains Mono", monospace; font-size: 11px; }
      .ms-comment {
        font-size: 11px;
        color: #7dd0ff;
        line-height: 1.4;
        margin-top: 6px;
      }
      .badge {
        font-size: 10px;
        padding: 2px 8px;
        border-radius: 999px;
        background: rgba(255,255,255,0.05);
        border: 1px solid rgba(255,255,255,0.09);
      }
      .pattern-note {
        font-size: 11px;
        color: #ffd3a3;
        margin-top: 4px;
      }
      .conf-label {
        font-size: 14px;
        font-weight: 700;
      }
      .conf-score {
        font-size: 22px;
        font-weight: 800;
      }
      .reason-list {
        font-size: 11px;
        margin-top: 4px;
      }
      .input-small {
        width: 100%;
        padding: 4px 6px;
        border-radius: 8px;
        border: 1px solid #333;
        background:#0b0b18;
        color:#fff;
        font-size:11px;
      }
      .hint {
        font-size:10px;
        color:#9ba7ff;
      }
    </style>
  </head>
  <body>
    <div class="card">
      <div class="title-main">FX REALTIME AI COACH</div>
      <div class="subtitle">Latihan baca struktur market, candlestick & confluence dengan data realtime (TwelveData).</div>

      <div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px;">
        <div style="display:flex;gap:8px;">
          <div>
            <div class="label">PAIR</div>
            <select id="pairSelect" class="input-small" style="border-radius:999px;">
              <option value="EURUSD">EUR/USD</option>
              <option value="GBPUSD">GBP/USD</option>
              <option value="USDJPY">USD/JPY</option>
            </select>
          </div>
          <div>
            <div class="label">TIMEFRAME</div>
            <select id="tfSelect" class="input-small" style="border-radius:999px;">
              <option value="1min">1m</option>
              <option value="5min">5m</option>
              <option value="15min">15m</option>
            </select>
          </div>
        </div>
        <div style="text-align:right;">
          <div class="label">LAST UPDATE</div>
          <div class="value mono" id="lastTime">-</div>
        </div>
      </div>

      <button class="btn" onclick="ambilSignal()">⚡ REFRESH SIGNAL</button>

      <button class="btn"
        style="margin-top:6px;background:linear-gradient(90deg,#00ff88,#00d49b);border:1px solid #00ffcc;box-shadow:0 0 12px rgba(0,255,180,.6);padding:8px;font-size:11px;"
        onclick="toggleAutoRefresh()">
        🔄 AUTO REFRESH: <span id="autoState">OFF</span>
      </button>

      <div style="margin-top:8px;display:flex;justify-content:space-between;align-items:center;">
        <div>
          <div class="label">INTERVAL</div>
          <select id="intervalSelect" class="input-small" style="border-radius:999px;">
            <option value="5000">5 detik</option>
            <option value="10000" selected>10 detik</option>
            <option value="30000">30 detik</option>
            <option value="60000">1 menit</option>
          </select>
        </div>
        <div style="text-align:right;">
          <div class="label">PRICE</div>
          <div class="value mono" id="lastPrice">-</div>
          <div style="margin-top:4px;">
            <span id="signalPill" class="pill pill-wait">WAIT</span>
          </div>
        </div>
      </div>
    </div>

    <div class="card">
      <div class="label">INDIKATOR UTAMA</div>
      <div class="grid-2" style="margin-top:6px;">
        <div>
          <div class="label">RSI (14)</div>
          <div class="value" id="rsiVal">-</div>
        </div>
        <div>
          <div class="label">ATR (14)</div>
          <div class="value mono" id="atrVal">-</div>
        </div>
        <div>
          <div class="label">SMA FAST (7)</div>
          <div class="value mono" id="smaFastVal">-</div>
        </div>
        <div>
          <div class="label">SMA SLOW (25)</div>
          <div class="value mono" id="smaSlowVal">-</div>
        </div>
      </div>
      <div style="margin-top:8px;">
        <span class="badge" id="bbInfo">BB: -</span>
      </div>
    </div>

    <!-- PANEL RISK MANAGEMENT ALA OLYM -->
    <div class="card">
      <div class="label">RISK MANAGEMENT (ALA OLYM)</div>
      <div style="margin-top:6px;" class="grid-2">
        <div>
          <div class="label">Saldo Akun (demo)</div>
          <input id="rmBalance" class="input-small" type="number" value="1000" step="1">
          <div class="hint">Contoh: 100, 500, 1000</div>
        </div>
        <div>
          <div class="label">Risk per Trade (%)</div>
          <input id="rmRiskPct" class="input-small" type="number" value="2" step="0.1">
          <div class="hint">Umum: 1 - 3%</div>
        </div>
        <div>
          <div class="label">Payout (%)</div>
          <input id="rmPayout" class="input-small" type="number" value="80" step="1">
          <div class="hint">Olym sering 70–90%</div>
        </div>
        <div>
          <div class="label">Durasi Entry</div>
          <select id="rmDuration" class="input-small">
            <option value="1m">1 Menit</option>
            <option value="2m">2 Menit</option>
            <option value="3m">3 Menit</option>
            <option value="5m">5 Menit</option>
            <option value="15m">15 Menit</option>
          </select>
          <div class="hint">Samakan dengan durasi di Olym</div>
        </div>
      </div>

      <button class="btn" style="margin-top:10px;padding:8px;font-size:11px;" onclick="hitungRisk()">💰 HITUNG AMOUNT & RISK</button>

      <div style="margin-top:8px;" class="grid-2">
        <div>
          <div class="label">Amount Ideal</div>
          <div class="value mono" id="rmAmount">-</div>
        </div>
        <div>
          <div class="label">Max Loss (Jika kalah)</div>
          <div class="value mono" id="rmMaxLoss">-</div>
        </div>
        <div>
          <div class="label">Profit (Jika menang)</div>
          <div class="value mono" id="rmProfit">-</div>
        </div>
        <div>
          <div class="label">Total Kembali</div>
          <div class="value mono" id="rmTotalReturn">-</div>
        </div>
      </div>
      <div class="ms-comment" id="rmNote" style="margin-top:6px;">
        Gunakan panel ini hanya sebagai simulasi / panduan risk saat entry manual di akun demo.
      </div>
    </div>

    <div class="card">
      <div class="label">POLA CANDLESTICK</div>
      <div style="margin-top:6px;">
        <div class="grid-2">
          <div>
            <div class="label">Nama Pola</div>
            <div class="value" id="patName">-</div>
          </div>
          <div>
            <div class="label">Arah</div>
            <div class="value" id="patDir">-</div>
          </div>
        </div>
        <div style="margin-top:6px;">
          <div class="label">Confidence</div>
          <div class="value" id="patConf">-</div>
        </div>
        <div class="pattern-note" id="patNote">
          Menunggu pola candlestick...
        </div>
      </div>
    </div>

    <div class="card">
      <div class="label">AI CONFLUENCE COACH</div>
      <div style="margin-top:6px;">
        <div class="grid-2">
          <div>
            <div class="label">Rating Setup</div>
            <div class="conf-label" id="confLabel">-</div>
          </div>
          <div style="text-align:right;">
            <div class="label">Score</div>
            <div class="conf-score" id="confScore">-</div>
          </div>
        </div>
        <div class="ms-comment" id="confCoach" style="margin-top:6px;">
          Menunggu analisa confluence...
        </div>
        <div class="reason-list" id="confReasons"></div>
      </div>
    </div>

    <div class="card">
      <div class="label">MARKET STRUCTURE (HH / HL / LH / LL)</div>
      <div style="margin-top:6px;">
        <div class="grid-2">
          <div>
            <div class="label">Trend</div>
            <div class="value" id="msTrend">-</div>
          </div>
          <div>
            <div class="label">Bias Latihan</div>
            <div class="value" id="msBias">-</div>
          </div>
        </div>

        <div style="margin-top:6px;">
          <div class="label">Swing Terakhir</div>
          <div class="value mono" id="msLastPoint">-</div>
        </div>

        <div style="margin-top:6px;">
          <div class="label">Break of Structure (BOS)</div>
          <div class="value mono" id="bosInfo">-</div>
        </div>

        <div class="ms-comment" id="msComment">
          Menunggu data struktur market...
        </div>
      </div>
    </div>

    <div class="card">
      <div class="label">SNR DARI STRUCTURE TERBARU</div>
      <div id="snrList" style="margin-top:6px;font-size:11px;" class="mono">-</div>
    </div>

    <div class="card">
      <div class="label">AI PENJELASAN MARKET</div>
      <div style="margin-top:6px;">
        <button class="btn" style="padding:8px;font-size:11px;margin-bottom:8px;" onclick="mintaAI()">🤖 MINTA PENJELASAN AI</button>
        <div id="aiStatus" style="font-size:11px;color:#9ba7ff;margin-bottom:4px;">AI siap membantu menjelaskan kondisi market untuk latihan.</div>
        <div id="aiText" style="font-size:12px;line-height:1.5;color:#f1f1f1;">
          -
        </div>
      </div>
    </div>

    <script>
      let lastSnapshot = null;
      let autoMode = false;
      let autoTimer = null;

      async function ambilSignal() {
        const pair = document.getElementById("pairSelect").value;
        const tf   = document.getElementById("tfSelect").value;

        try {
          const res = await fetch(`/signal?pair=${pair}&tf=${tf}`);
          const data = await res.json();

          lastSnapshot = data;

          document.getElementById("lastPrice").innerText = data.last_price.toFixed(5);
          document.getElementById("lastTime").innerText  = new Date(data.last_time).toLocaleTimeString();

          const sig = data.signal || "WAIT";
          const pill = document.getElementById("signalPill");
          pill.textContent = sig;
          pill.className = "pill " + (sig === "BUY" ? "pill-buy" : (sig === "SELL" ? "pill-sell" : "pill-wait"));

          const ind = data.indicators || {};
          document.getElementById("rsiVal").innerText = ind.rsi ? ind.rsi.toFixed(1) : "-";
          document.getElementById("atrVal").innerText = ind.atr ? ind.atr.toFixed(5) : "-";
          document.getElementById("smaFastVal").innerText = ind.sma_fast ? ind.sma_fast.toFixed(5) : "-";
          document.getElementById("smaSlowVal").innerText = ind.sma_slow ? ind.sma_slow.toFixed(5) : "-";

          const bb = ind.bb;
          document.getElementById("bbInfo").innerText = bb
            ? `BB mid ${bb.middle.toFixed(5)} | up ${bb.upper.toFixed(5)} | low ${bb.lower.toFixed(5)}`
            : "BB: -";

          const pattern = data.pattern || {};
          document.getElementById("patName").innerText = pattern.name || "-";
          document.getElementById("patDir").innerText  = pattern.direction || "-";
          document.getElementById("patConf").innerText =
            pattern.confidence ? (pattern.confidence * 100).toFixed(0) + "%" : "-";
          document.getElementById("patNote").innerText = pattern.note || "";

          const conf = data.confluence || {};
          document.getElementById("confLabel").innerText = conf.label || "-";
          document.getElementById("confScore").innerText = conf.score != null ? conf.score : "-";
          document.getElementById("confCoach").innerText = conf.coaching || "-";
          const reasons = conf.reasons || [];
          document.getElementById("confReasons").innerHTML =
            reasons.length > 0 ? ("• " + reasons.join("<br>• ")) : "";

          const ms = data.structure || {};
          const trendMap = {
            uptrend: "Uptrend (HH & HL dominan)",
            downtrend: "Downtrend (LH & LL dominan)",
            sideways: "Sideways / range",
            unknown: "Unknown"
          };
          const biasMap = {
            buy_bias:  "BUY bias (latihan fokus buy searah trend)",
            sell_bias: "SELL bias (latihan fokus sell searah trend)",
            neutral:   "Netral / tunggu setup jelas"
          };

          document.getElementById("msTrend").innerText = trendMap[ms.trend] || "-";
          document.getElementById("msBias").innerText  = biasMap[ms.bias] || "-";

          let lastPointText = "-";
          if (ms.points && ms.points.length > 0) {
            const lp = ms.points[ms.points.length - 1];
            lastPointText = `${lp.label} @ ${lp.price.toFixed(5)} (${new Date(lp.time).toLocaleTimeString()})`;
          }
          document.getElementById("msLastPoint").innerText = lastPointText;
          document.getElementById("msComment").innerText   = ms.comment || "";

          const bos = data.bos || {};
          let bosText = "-";
          if (bos.status === "bos_up" || bos.status === "bos_down") {
            const dir = bos.status === "bos_up" ? "Bullish BOS (naik)" : "Bearish BOS (turun)";
            if (bos.price) {
              bosText = `${dir} @ ${bos.price.toFixed(5)} (${bos.time ? new Date(bos.time).toLocaleTimeString() : "-"})`;
            } else {
              bosText = dir;
            }
          } else if (bos.label) {
            bosText = `Belum BOS jelas. Swing terakhir: ${bos.label} @ ${bos.price ? bos.price.toFixed(5) : "-"}`;
          }
          document.getElementById("bosInfo").innerText = bosText;

          const snr = data.snr || [];
          if (snr.length === 0) {
            document.getElementById("snrList").innerText = "-";
          } else {
            document.getElementById("snrList").innerHTML = snr.map(s => {
              return `${s.type} @ ${s.price.toFixed(5)} (${new Date(s.time).toLocaleTimeString()})`;
            }).join("<br>");
          }

          document.getElementById("aiStatus").innerText = "AI siap menjelaskan kondisi market berdasarkan snapshot terakhir.";
        } catch (e) {
          console.error(e);
          alert("Gagal ambil signal. Cek koneksi / TWELVEDATA_KEY.");
        }
      }

      async function mintaAI() {
        if (!lastSnapshot) {
          document.getElementById("aiStatus").innerText = "Ambil signal dulu sebelum minta penjelasan AI.";
          return;
        }

        document.getElementById("aiStatus").innerText = "Mengirim data ke AI, mohon tunggu...";
        document.getElementById("aiText").innerText   = "";

        try {
          const tf = document.getElementById("tfSelect").value;
          const res = await fetch("/ai_insight", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              pair: lastSnapshot.pair,
              timeframe: tf,
              signal: lastSnapshot.signal,
              indicators: lastSnapshot.indicators,
              structure: lastSnapshot.structure,
              bos: lastSnapshot.bos,
              pattern: lastSnapshot.pattern,
              confluence: lastSnapshot.confluence
            })
          });

          const data = await res.json();
          if (data.error) {
            document.getElementById("aiStatus").innerText = "AI error: " + data.error;
            document.getElementById("aiText").innerText   = data.details || "";
          } else {
            document.getElementById("aiStatus").innerText = "Penjelasan AI (untuk latihan, bukan sinyal pasti):";
            document.getElementById("aiText").innerText   = data.ai_comment;
          }
        } catch (e) {
          console.error(e);
          document.getElementById("aiStatus").innerText = "Gagal menghubungi AI.";
          document.getElementById("aiText").innerText   = e.message;
        }
      }

      function hitungRisk() {
        const balance = parseFloat(document.getElementById("rmBalance").value || "0");
        const riskPct = parseFloat(document.getElementById("rmRiskPct").value || "0");
        const payout  = parseFloat(document.getElementById("rmPayout").value || "0");
        const durasi  = document.getElementById("rmDuration").value;

        if (balance <= 0 || riskPct <= 0 || payout <= 0) {
          document.getElementById("rmAmount").innerText = "-";
          document.getElementById("rmMaxLoss").innerText = "-";
          document.getElementById("rmProfit").innerText = "-";
          document.getElementById("rmTotalReturn").innerText = "-";
          document.getElementById("rmNote").innerText = "Isi saldo, risk%, dan payout dengan benar dulu.";
          return;
        }

        const amount    = balance * (riskPct / 100.0);
        const maxLoss   = amount;
        const profitWin = amount * (payout / 100.0);
        const totalBack = amount + profitWin;

        document.getElementById("rmAmount").innerText      = amount.toFixed(2);
        document.getElementById("rmMaxLoss").innerText     = "-" + maxLoss.toFixed(2);
        document.getElementById("rmProfit").innerText      = "+" + profitWin.toFixed(2);
        document.getElementById("rmTotalReturn").innerText = totalBack.toFixed(2);

        document.getElementById("rmNote").innerText =
          "Simulasi: jika kamu entry " + durasi + " dengan amount " + amount.toFixed(2) +
          ", kerugian maksimal per trade sekitar " + maxLoss.toFixed(2) +
          " dan jika payout " + payout.toFixed(0) + "% maka profit sekitar " +
          profitWin.toFixed(2) + " jika posisi menang. Gunakan ini untuk latihan risk management di akun demo, bukan jaminan hasil.";
      }

      function toggleAutoRefresh() {
        autoMode = !autoMode;
        const state = document.getElementById("autoState");
        const interval = parseInt(document.getElementById("intervalSelect").value);

        if (autoMode) {
          state.textContent = "ON";
          state.style.color = "#00ffcc";
          autoTimer = setInterval(() => {
            ambilSignal();
          }, interval);
        } else {
          state.textContent = "OFF";
          state.style.color = "#ff3355";
          clearInterval(autoTimer);
        }
      }

      document.getElementById("intervalSelect").addEventListener("change", () => {
        if (autoMode) {
          clearInterval(autoTimer);
          const newInterval = parseInt(document.getElementById("intervalSelect").value);
          autoTimer = setInterval(() => {
            ambilSignal();
          }, newInterval);
        }
      });

      // auto load pertama
      ambilSignal();
    </script>
  </body>
  </html>
  HTML
end
