require 'sinatra'
require 'json'
require 'httparty'
require 'fileutils'
require 'securerandom'
require 'uri'
require 'base64'

# Bisa jalan di Termux (4567) & Railway/VPS (pakai ENV PORT)
set :bind, '0.0.0.0'
set :port, ENV.fetch('PORT', 4567)
set :public_folder, File.dirname(__FILE__) + '/public'

FileUtils.mkdir_p(File.join(settings.public_folder, 'uploads'))

# ======== KONFIG API ========
TD_API_KEY      = ENV['TWELVEDATA_KEY']
OPENAI_API_KEY  = ENV['OPENAI_API_KEY']
OPENAI_API_URL  = 'https://api.openai.com/v1/responses'
TD_BASE_URL     = 'https://api.twelvedata.com'

PAIRS = {
  "EURUSD" => { name: "EUR/USD", symbol: "EUR/USD" },
  "GBPUSD" => { name: "GBP/USD", symbol: "GBP/USD" },
  "USDJPY" => { name: "USD/JPY", symbol: "USD/JPY" }
}

helpers do
  # ====== DATA FOREX DARI TWELVEDATA ======
  def fetch_pair_intraday_1m_twelve(pair_code)
    raise "TWELVEDATA_KEY belum diset" if TD_API_KEY.nil? || TD_API_KEY.empty?

    cfg = PAIRS[pair_code] || PAIRS["EURUSD"]
    params = {
      symbol:     cfg[:symbol],
      interval:   '1min',
      outputsize: 200,
      apikey:     TD_API_KEY
    }

    res  = HTTParty.get("#{TD_BASE_URL}/time_series", query: params)
    json = JSON.parse(res.body)

    if json["status"] == "error"
      raise "Error TwelveData: #{json["message"]}"
    end

    values = json["values"]
    raise "Data candle kosong" if values.nil? || values.empty?

    values.map do |v|
      {
        time:  v["datetime"],
        open:  v["open"].to_f,
        high:  v["high"].to_f,
        low:   v["low"].to_f,
        close: v["close"].to_f
      }
    end.reverse
  end

  # ====== INDIKATOR DASAR ======
  def sma(values, period)
    return nil if values.size < period
    values.last(period).sum.to_f / period
  end

  def rsi(values, period = 14)
    return nil if values.size < period + 1
    gains, losses = [], []
    values.each_cons(2) do |prev, curr|
      diff = curr - prev
      diff >= 0 ? gains << diff : losses << -diff
    end
    avg_gain = gains.last(period).sum.to_f / period
    avg_loss = losses.last(period).sum.to_f / period
    return 50.0 if avg_loss == 0
    rs = avg_gain / avg_loss
    100 - (100 / (1 + rs))
  end

  def decide_signal(sfast, sslow, rsi)
    return "hold" if [sfast, sslow, rsi].any?(&:nil?)
    return "buy"  if sfast > sslow && rsi < 70
    return "sell" if sfast < sslow && rsi > 30
    "hold"
  end

  # ====== ATR (Average True Range) ======
  def atr(candles, period = 14)
    return nil if candles.size < period + 1

    trs = []
    candles.each_cons(2) do |prev, curr|
      tr1 = curr[:high] - curr[:low]
      tr2 = (curr[:high] - prev[:close]).abs
      tr3 = (curr[:low]  - prev[:close]).abs
      trs << [tr1, tr2, tr3].max
    end

    return nil if trs.size < period
    trs.last(period).sum.to_f / period
  end

  # ====== Bollinger Bands (20,2 default) ======
  def bollinger(closes, period = 20, k = 2.0)
    return { middle: nil, upper: nil, lower: nil } if closes.size < period

    window = closes.last(period)
    m = window.sum.to_f / period
    var = window.map { |c| (c - m) ** 2 }.sum / period
    sd = Math.sqrt(var)

    {
      middle: m,
      upper:  m + k * sd,
      lower:  m - k * sd
    }
  end

  # ====== DETEKSI POLA CANDLE ======
  def detect_candle_pattern(candles)
    return {
      name: "Belum cukup data",
      direction: "neutral",
      confidence: 0.0,
      note: "Minimal butuh 3 candle terakhir untuk deteksi pola."
    } if candles.size < 3

    c1 = candles[-3]
    c2 = candles[-2]
    c3 = candles[-1]

    body = ->(c) { (c[:close] - c[:open]).abs }
    range = ->(c) { c[:high] - c[:low] }
    is_bull = ->(c) { c[:close] > c[:open] }
    is_bear = ->(c) { c[:close] < c[:open] }

    b1, b2, b3 = body[c1], body[c2], body[c3]
    r3 = range[c3]

    uptrend   = c3[:close] > c1[:close]
    downtrend = c3[:close] < c1[:close]

    # Doji
    if r3 > 0 && b3 < (r3 * 0.15)
      return {
        name: "Doji",
        direction: "neutral",
        confidence: 0.6,
        note: "Doji = keraguan market. Latihan: tunggu candle konfirmasi (break high/low doji) sebelum entry."
      }
    end

    # Bullish Engulfing
    if is_bear[c2] && is_bull[c3] &&
       c3[:open] <= c2[:close] && c3[:close] >= c2[:open] &&
       b3 > b2 * 1.2
      return {
        name: "Bullish Engulfing",
        direction: "bullish",
        confidence: uptrend ? 0.8 : 0.65,
        note: "Bullish Engulfing – buyer ambil alih dari seller. Praktik: fokus BUY searah trend naik setelah koreksi kecil."
      }
    end

    # Bearish Engulfing
    if is_bull[c2] && is_bear[c3] &&
       c3[:open] >= c2[:close] && c3[:close] <= c2[:open] &&
       b3 > b2 * 1.2
      return {
        name: "Bearish Engulfing",
        direction: "bearish",
        confidence: downtrend ? 0.8 : 0.65,
        note: "Bearish Engulfing – seller ambil alih dari buyer. Praktik: fokus SELL di arah trend turun setelah pullback."
      }
    end

    # Pin bar / Hammer / Shooting Star
    upper_wick = c3[:high] - [c3[:open], c3[:close]].max
    lower_wick = [c3[:open], c3[:close]].min - c3[:low]

    if lower_wick > b3 * 1.5 && upper_wick < b3 * 0.5
      return {
        name: "Bullish Pin Bar (Hammer)",
        direction: "bullish",
        confidence: 0.7,
        note: "Bullish pin bar – penolakan harga bawah. Praktik: cari ini di area support dalam konteks trend naik."
      }
    end

    if upper_wick > b3 * 1.5 && lower_wick < b3 * 0.5
      return {
        name: "Bearish Pin Bar (Shooting Star)",
        direction: "bearish",
        confidence: 0.7,
        note: "Bearish pin bar – penolakan harga atas. Praktik: cari ini di area resistance dalam trend turun."
      }
    end

    {
      name: "Tidak ada pola kuat",
      direction: "neutral",
      confidence: 0.4,
      note: "Belum terlihat pola jelas. Fokus dulu baca trend & struktur high-low sebelum entry."
    }
  end

  # ====== AUTO SUPPORT & RESISTANCE (SNR) ======
  def find_snr_levels(candles, sensitivity = 2)
    return { resistance: [], support: [] } if candles.size < (sensitivity * 2 + 3)

    swing_highs = []
    swing_lows  = []

    (sensitivity...candles.size - sensitivity).each do |i|
      c = candles[i]

      if c[:high] > candles[i - sensitivity][:high] &&
         c[:high] > candles[i + sensitivity][:high]
        swing_highs << c[:high]
      end

      if c[:low] < candles[i - sensitivity][:low] &&
         c[:low] < candles[i + sensitivity][:low]
        swing_lows << c[:low]
      end
    end

    highs = swing_highs.group_by { |v| v.round(4) }
                       .sort_by { |k,v| -v.size }
                       .map(&:first)
                       .first(5)

    lows  = swing_lows.group_by  { |v| v.round(4) }
                      .sort_by { |k,v| -v.size }
                      .map(&:first)
                      .first(5)

    { resistance: highs, support: lows }
  end
end

# ======== API SIGNAL (JSON) ========
get "/signal" do
  content_type :json
  begin
    pair_code = (params["pair"] || "EURUSD").upcase
    cfg       = PAIRS[pair_code] || PAIRS["EURUSD"]

    candles   = fetch_pair_intraday_1m_twelve(pair_code)
    closes    = candles.map { |c| c[:close] }

    sma_fast  = sma(closes, 5)
    sma_slow  = sma(closes, 20)
    rsi_val   = rsi(closes, 14)
    atr_val   = atr(candles, 14)
    bb        = bollinger(closes, 20, 2.0)
    signal    = decide_signal(sma_fast, sma_slow, rsi_val)
    pattern   = detect_candle_pattern(candles)
    snr       = find_snr_levels(candles)

    {
      pair_name:   cfg[:name],
      pair_code:   pair_code,
      timeframe:   "1min",
      last_price:  closes.last,
      candle_time: candles.last[:time],
      signal:      signal,
      indicators: {
        sma_fast:  sma_fast,
        sma_slow:  sma_slow,
        rsi:       rsi_val,
        atr:       atr_val,
        bb_middle: bb[:middle],
        bb_upper:  bb[:upper],
        bb_lower:  bb[:lower]
      },
      pattern: pattern,
      snr: snr,
      candles: candles
    }.to_json
  rescue => e
    status 500
    { error: e.message }.to_json
  end
end

# ======== UPLOAD SCREENSHOT + OPENAI VISION ========
post "/upload_chart" do
  begin
    file_param = params["chart_image"]
    raise "File tidak ditemukan" if file_param.nil?

    tempfile  = file_param[:tempfile]
    ext       = File.extname(file_param[:filename])
    ext       = ".png" if ext.empty?
    safe_name = "#{SecureRandom.hex(8)}#{ext}"
    upload_path = File.join(settings.public_folder, 'uploads', safe_name)

    File.open(upload_path, "wb") { |f| f.write(tempfile.read) }

    raise "OPENAI_API_KEY belum diset" if OPENAI_API_KEY.nil? || OPENAI_API_KEY.empty?

    img_data   = File.binread(upload_path)
    base64_img = Base64.strict_encode64(img_data)
    data_url   = "data:image/png;base64,#{base64_img}"

    payload = {
      model: "gpt-4.1-mini",
      input: [
        {
          role: "user",
          content: [
            {
              type: "input_text",
              text: "Ini screenshot chart trading forex. 1) Deteksi pola candlestick (engulfing, pin bar, doji, hammer, shooting star, dll). 2) Jelaskan apakah market cenderung uptrend, downtrend, atau sideways. 3) Berikan saran EDUKASI entry untuk latihan di akun demo (bukan saran finansial). Jawab singkat dan jelas dalam bahasa Indonesia."
            },
            {
              type: "input_image",
              image_url: data_url
            }
          ]
        }
      ]
    }

    headers = {
      "Authorization" => "Bearer #{OPENAI_API_KEY}",
      "Content-Type"  => "application/json"
    }

    res   = HTTParty.post(OPENAI_API_URL, headers: headers, body: payload.to_json)
    parsed = JSON.parse(res.body) rescue {}

    ai_comment =
      if parsed["output"].is_a?(Array)
        first = parsed["output"].first
        if first && first["content"].is_a?(Array)
          t = first["content"].find { |c| c["type"] == "output_text" }
          t ? t["text"] : parsed.to_json
        else
          parsed.to_json
        end
      else
        parsed.to_json
      end

    img_url = "/uploads/#{safe_name}"
    redirect to("/?img=#{URI.encode_www_form_component(img_url)}&img_comment=#{URI.encode_www_form_component(ai_comment)}")
  rescue => e
    redirect to("/?img_error=#{URI.encode_www_form_component(e.message)}")
  end
end

# ======== FRONTEND HTML / DASHBOARD ========
get "/" do
  uploaded_img_url  = params['img']
  ai_image_comment  = params['img_comment']
  img_error_message = params['img_error']

  <<~HTML
  <!DOCTYPE html>
  <html>
  <head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>FX Realtime AI Trading Coach</title>
    <script src="https://cdn.jsdelivr.net/npm/luxon@1.26.0"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@3.9.1/dist/chart.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-luxon@1.0.0"></script>
    <script src="https://www.chartjs.org/chartjs-chart-financial/chartjs-chart-financial.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/hammerjs@2.0.8"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-zoom@1.2.1/dist/chartjs-plugin-zoom.min.js"></script>
    <style>
      :root {
        --bg-body: #020617;
        --bg-panel: #020617;
        --bg-card: rgba(15,23,42,0.92);
        --bg-card-soft: rgba(15,23,42,0.9);
        --border-subtle: rgba(148,163,184,0.3);
        --text-main: #e5e7eb;
        --text-muted: #9ca3af;
        --accent-green: #22c55e;
        --accent-red: #f97373;
        --accent-yellow: #facc15;
        --accent-cyan: #22d3ee;
        --accent-pink: #ec4899;
      }

      * { box-sizing: border-box; }

      body {
        margin: 0;
        font-family: system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", Arial, sans-serif;
        background:
          radial-gradient(circle at top left, rgba(56,189,248,0.08), transparent 55%),
          radial-gradient(circle at bottom right, rgba(34,197,94,0.10), transparent 55%),
          var(--bg-body);
        color: var(--text-main);
        min-height: 100vh;
      }

      .shell {
        max-width: 1200px;
        margin: 0 auto;
        padding: 14px 12px 40px;
      }

      .app-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 10px;
        margin-bottom: 14px;
      }

      .brand-group {
        display: flex;
        align-items: center;
        gap: 10px;
      }

      .brand-logo {
        width: 34px;
        height: 34px;
        border-radius: 999px;
        background: radial-gradient(circle at 30% 20%, #22c55e 0, #16a34a 30%, #22d3ee 80%);
        box-shadow:
          0 0 18px rgba(34,197,94,0.9),
          0 0 32px rgba(34,211,238,0.8);
        display: flex;
        align-items: center;
        justify-content: center;
        font-size: 19px;
        font-weight: 900;
        color: #020617;
      }

      .brand-text-main {
        font-size: 17px;
        font-weight: 700;
        letter-spacing: 0.04em;
      }

      .brand-text-sub {
        font-size: 11px;
        color: var(--text-muted);
      }

      .header-right {
        text-align: right;
        font-size: 10px;
        color: var(--text-muted);
      }

      .tag-pill {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        padding: 4px 10px;
        border-radius: 999px;
        background: rgba(15,23,42,0.8);
        border: 1px solid rgba(34,197,94,0.6);
        box-shadow: 0 0 12px rgba(34,197,94,0.4);
        margin-bottom: 4px;
        font-size: 10px;
      }

      .tag-dot {
        width: 7px;height: 7px;border-radius:999px;
        background: radial-gradient(circle at 30% 30%, #22c55e, #16a34a);
      }

      .layout-grid {
        display: grid;
        grid-template-columns: 1fr;
        gap: 14px;
      }

      @media (min-width: 900px) {
        .layout-grid {
          grid-template-columns: minmax(0, 1.1fr) minmax(0, 1.05fr);
          align-items: start;
        }
      }

      .panel {
        background: radial-gradient(circle at top left, rgba(34,197,94,0.05), transparent 55%),
                    radial-gradient(circle at bottom right, rgba(8,47,73,0.6), transparent 55%),
                    var(--bg-panel);
        border-radius: 22px;
        padding: 14px;
        border: 1px solid rgba(148,163,184,0.22);
        box-shadow:
          0 18px 40px rgba(15,23,42,0.9),
          0 0 60px rgba(15,118,110,0.4);
      }

      .panel-header {
        display:flex;
        justify-content:space-between;
        align-items:flex-start;
        gap:8px;
        margin-bottom:10px;
      }

      .panel-title {
        font-size: 14px;
        font-weight: 600;
      }

      .panel-sub {
        font-size: 11px;
        color: var(--text-muted);
      }

      .chip-soft {
        padding: 4px 9px;
        border-radius: 999px;
        background: rgba(15,23,42,0.9);
        border: 1px solid rgba(148,163,184,0.5);
        font-size: 10px;
        color: var(--text-main);
      }

      .chip-live {
        display:inline-flex;
        align-items:center;
        gap:6px;
        padding:3px 9px;
        border-radius:999px;
        font-size:10px;
        background:rgba(15,23,42,0.95);
        border:1px solid rgba(34,197,94,0.55);
      }

      .live-dot {
        width:7px;height:7px;border-radius:999px;
        background:#22c55e;
        box-shadow:0 0 10px rgba(34,197,94,0.9);
      }

      .btn-refresh {
        width:100%;
        display:flex;
        align-items:center;
        justify-content:center;
        gap:8px;
        margin:6px 0 6px;
        background: radial-gradient(circle at 0 0, rgba(251,113,133,0.4), rgba(127,29,29,0.95));
        border: 1px solid rgba(34,197,94,0.8);
        color:#f9fafb;
        font-weight:600;
        cursor:pointer;
        padding:9px 16px;
        border-radius: 999px;
        font-size: 13px;
        text-shadow:0 0 8px rgba(34,197,94,0.8);
        box-shadow:
          0 0 14px rgba(34,197,94,0.65),
          0 0 26px rgba(190,18,60,0.8),
          inset 0 0 10px rgba(0,0,0,0.9);
        transition:0.18s ease-out;
      }

      .btn-refresh:hover {
        transform: translateY(-1px) scale(1.02);
        box-shadow:
          0 0 20px rgba(34,197,94,0.85),
          0 0 32px rgba(190,18,60,0.95),
          inset 0 0 12px rgba(0,0,0,0.9);
      }

      .btn-refresh:active {
        transform: translateY(1px) scale(0.98);
        box-shadow:
          0 0 10px rgba(34,197,94,0.6),
          0 0 18px rgba(190,18,60,0.8),
          inset 0 0 16px rgba(0,0,0,0.95);
      }

      .btn-refresh span.icon {
        font-size: 16px;
      }

      .status-text {
        text-align:center;
        color:var(--text-muted);
        font-size:11px;
        margin-bottom:6px;
      }

      .auto-row {
        display:flex;
        align-items:center;
        justify-content:space-between;
        gap:8px;
        margin:4px 0 10px;
        font-size:11px;
        color:var(--text-muted);
      }

      .auto-btn {
        padding:3px 10px;
        border-radius:999px;
        border:1px solid rgba(148,163,184,0.6);
        background:rgba(15,23,42,0.9);
        color:var(--text-muted);
        cursor:pointer;
        font-size:10px;
        display:inline-flex;
        align-items:center;
        gap:6px;
      }

      .auto-btn.on {
        border-color:rgba(34,197,94,0.9);
        background:radial-gradient(circle at 0 0, rgba(34,197,94,0.4), rgba(21,128,61,0.95));
        color:#e5e7eb;
        box-shadow:0 0 12px rgba(34,197,94,0.8);
      }

      .auto-dot {
        width:7px;height:7px;border-radius:999px;
        background:rgba(148,163,184,0.7);
      }
      .auto-btn.on .auto-dot {
        background:#22c55e;
        box-shadow:0 0 10px rgba(34,197,94,0.9);
      }

      .signal-main-row {
        display:flex;
        justify-content:space-between;
        align-items:flex-end;
        gap:12px;
        flex-wrap:wrap;
        margin-top:6px;
      }

      .signal-section-left {
        flex:1;
        min-width:200px;
      }

      .signal-section-right {
        min-width:180px;
        text-align:right;
      }

      .titlePair {
        margin:0;
        font-size:15px;
      }

      .signal-value {
        font-size:44px;
        font-weight:800;
        letter-spacing:0.05em;
      }

      .buy{color:#22c55e;text-shadow:0 0 14px rgba(34,197,94,0.8);}
      .sell{color:#f97373;text-shadow:0 0 14px rgba(248,113,113,0.9);}
      .hold{color:#facc15;text-shadow:0 0 14px rgba(250,204,21,0.7);}

      .label {
        font-size:11px;
        color:var(--text-muted);
      }

      .pair-group, .tf-group {
        display:flex;
        flex-wrap:wrap;
        gap:6px;
        margin-top:4px;
      }

      .pair-btn, .tf-btn {
        padding:4px 10px;
        border-radius:999px;
        border:1px solid rgba(148,163,184,0.7);
        background:rgba(15,23,42,0.9);
        cursor:pointer;
        font-size:10px;
        color:var(--text-main);
        text-shadow:0 0 4px rgba(15,23,42,0.9);
        transition:0.16s;
      }

      .pair-btn:hover, .tf-btn:hover {
        transform:translateY(-1px);
        border-color:rgba(148,163,184,1);
      }

      .pair-btn.active, .tf-btn.active {
        background:radial-gradient(circle at 0 0, rgba(34,197,94,0.4), rgba(15,23,42,0.96));
        border-color:rgba(34,197,94,0.9);
        box-shadow:0 0 12px rgba(34,197,94,0.7);
        color:#f9fafb;
      }

      .signal-metrics {
        display:grid;
        grid-template-columns: repeat(2, minmax(0,1fr));
        gap:6px 10px;
        margin-top:10px;
        font-size:11px;
      }

      .metric-inline {
        display:flex;
        justify-content:space-between;
        gap:6px;
      }

      .metric-label {
        color:var(--text-muted);
      }

      .metric-value {
        font-weight:600;
      }

      .chart-card {
        background: radial-gradient(circle at top left, rgba(34,197,94,0.06), transparent 60%),
                    radial-gradient(circle at bottom right, rgba(8,47,73,0.7), transparent 55%),
                    rgba(15,23,42,0.98);
        border-radius: 18px;
        border:1px solid rgba(30,64,175,0.6);
        padding:10px 10px 12px;
        box-shadow:
          0 22px 45px rgba(15,23,42,0.95),
          0 0 60px rgba(30,64,175,0.8);
      }

      .chart-header-row {
        display:flex;
        justify-content:space-between;
        align-items:center;
        gap:8px;
        margin-bottom:6px;
      }

      .chart-title {
        font-size:13px;
        font-weight:600;
      }

      .chart-sub {
        font-size:10px;
        color:var(--text-muted);
      }

      .chart-tag {
        padding:3px 8px;
        border-radius:999px;
        background:rgba(15,23,42,0.9);
        border:1px solid rgba(148,163,184,0.5);
        font-size:10px;
        color:var(--text-muted);
      }

      .mini-chart-inner {
        position:relative;
        height:270px;
        margin-top:4px;
      }

      #priceChart {
        height:270px!important;
        width:100%!important;
      }

      .ai-card {
        background:radial-gradient(circle at top left, rgba(56,189,248,0.18), transparent 60%),
                   radial-gradient(circle at bottom right, rgba(34,197,94,0.16), transparent 60%),
                   rgba(15,23,42,0.98);
        border-radius:18px;
        padding:12px;
        border:1px solid rgba(56,189,248,0.55);
        box-shadow:
          0 18px 40px rgba(15,23,42,0.95),
          0 0 50px rgba(59,130,246,0.9);
      }

      .ai-header {
        display:flex;
        justify-content:space-between;
        align-items:flex-start;
        gap:8px;
        margin-bottom:6px;
      }

      .ai-title {
        font-size:14px;
        font-weight:600;
      }

      .ai-badge {
        padding:3px 9px;
        border-radius:999px;
        font-size:10px;
        border:1px solid rgba(148,163,184,0.8);
        background:rgba(15,23,42,0.9);
      }

      .badge-up {
        border-color:rgba(34,197,94,0.9);
        color:#bbf7d0;
        box-shadow:0 0 14px rgba(34,197,94,0.9);
      }

      .badge-down {
        border-color:rgba(248,113,113,0.9);
        color:#fecaca;
        box-shadow:0 0 14px rgba(248,113,113,0.9);
      }

      .badge-sideways {
        border-color:rgba(234,179,8,0.9);
        color:#fef3c7;
        box-shadow:0 0 14px rgba(234,179,8,0.8);
      }

      .ai-text {
        font-size:12px;
        line-height:1.5;
        margin-bottom:6px;
      }

      .ai-note {
        font-size:10px;
        color:var(--text-muted);
      }

      .pattern-card {
        background:rgba(15,23,42,0.98);
        border-radius:16px;
        padding:10px 11px;
        border:1px solid rgba(148,163,184,0.35);
        margin-top:10px;
      }

      .pattern-title {
        font-size:12px;
        font-weight:600;
        margin-bottom:4px;
      }

      .pattern-row {
        display:grid;
        grid-template-columns: repeat(2,minmax(0,1fr));
        gap:4px 8px;
        font-size:11px;
        margin-bottom:4px;
      }

      .pattern-label {
        color:var(--text-muted);
      }

      .pattern-value {
        font-weight:600;
      }

      .upload-card {
        background:rgba(15,23,42,0.97);
        border-radius:18px;
        padding:12px;
        border:1px solid rgba(148,163,184,0.35);
      }

      .upload-img {
        max-width:100%;
        border-radius:12px;
        margin-top:8px;
        border:1px solid rgba(55,65,81,0.9);
      }

      .upload-note {
        font-size:11px;
        color:var(--text-muted);
      }

      input[type="file"] {
        font-size:11px;
        color:var(--text-main);
      }

      .pair-table {
        width:100%;
        border-collapse:collapse;
        font-size:11px;
        margin-top:6px;
      }

      .pair-table th, .pair-table td {
        border:1px solid rgba(31,41,55,0.9);
        padding:5px 7px;
      }

      .pair-table th {
        background:rgba(15,23,42,0.98);
        text-align:left;
      }

      .pair-table tr:nth-child(even) {
        background:rgba(15,23,42,0.92);
      }

      pre {
        margin-top:10px;
        background:rgba(2,6,23,0.95);
        color:var(--text-muted);
        padding:8px;
        border-radius:12px;
        font-size:10px;
        max-height:200px;
        overflow:auto;
        border:1px solid rgba(30,64,175,0.7);
      }

      @media (max-width: 600px) {
        .signal-value { font-size:36px; }
        .mini-chart-inner { height:230px; }
        #priceChart { height:230px!important; }
      }
    </style>
  </head>
  <body>
    <div class="shell">
      <header class="app-header">
        <div class="brand-group">
          <div class="brand-logo">FX</div>
          <div>
            <div class="brand-text-main">Realtime AI Trading Coach</div>
            <div class="brand-text-sub">EUR/USD · Demo learning assistant · 1M data feed</div>
          </div>
        </div>
        <div class="header-right">
          <div class="tag-pill">
            <span class="tag-dot"></span>
            <span>EDU MODE · NOT FINANCIAL ADVICE</span>
          </div>
          <div>Data source: TwelveData · AI: OpenAI</div>
        </div>
      </header>

      <div class="layout-grid">
        <!-- PANEL KIRI: SIGNAL + AI -->
        <section class="panel">
          <div class="panel-header">
            <div>
              <div class="panel-title">Signal & Setup</div>
              <div class="panel-sub">Pilih pair & timeframe label, lalu refresh atau aktifkan auto-refresh.</div>
            </div>
            <div class="chip-soft">Mode: 1M Forex Realtime</div>
          </div>

          <button class="btn-refresh" onclick="ambilSignal(true)">
            <span class="icon">⚡</span>
            <span>REFRESH SIGNAL</span>
          </button>
          <p id="status" class="status-text">Ready...</p>

          <div class="auto-row">
            <span>Auto refresh setiap 15 detik (untuk latihan live membaca pergerakan candle).</span>
            <button id="autoBtn" class="auto-btn" onclick="toggleAuto()">
              <span class="auto-dot"></span>
              <span>AUTO: OFF</span>
            </button>
          </div>

          <div class="signal-main-row">
            <div class="signal-section-left">
              <h2 id="titlePair" class="titlePair">Signal EUR/USD (1M Realtime)</h2>
              <div class="label">Cocok untuk latihan baca candlestick dan konfirmasi sebelum entry demo.</div>

              <div style="margin-top:8px;">
                <div class="label">Pilih Pair:</div>
                <div class="pair-group">
                  <button class="pair-btn active" data-pair="EURUSD">EUR/USD</button>
                  <button class="pair-btn" data-pair="GBPUSD">GBP/USD</button>
                  <button class="pair-btn" data-pair="USDJPY">USD/JPY</button>
                </div>
              </div>

              <div style="margin-top:8px;">
                <div class="label">Timeframe Label (hanya label, data tetap 1M):</div>
                <div class="tf-group">
                  <button class="tf-btn active" data-tf="1m">1M</button>
                  <button class="tf-btn" data-tf="5m">5M</button>
                  <button class="tf-btn" data-tf="15m">15M</button>
                  <button class="tf-btn" data-tf="30m">30M</button>
                  <button class="tf-btn" data-tf="1h">1H</button>
                </div>
              </div>
            </div>

            <div class="signal-section-right">
              <div class="chip-live">
                <span class="live-dot"></span>
                <span>LIVE FEED</span>
              </div>
              <div id="signal" class="signal-value" style="margin-top:4px;">-</div>
              <div class="label">Last Price: <b id="price"></b></div>
              <div class="label">Candle time: <b id="ctime"></b></div>
            </div>
          </div>

          <div class="signal-metrics">
            <div class="metric-inline">
              <span class="metric-label">RSI (14)</span>
              <span class="metric-value" id="rsi">-</span>
            </div>
            <div class="metric-inline">
              <span class="metric-label">ATR (14)</span>
              <span class="metric-value" id="atr">-</span>
            </div>
            <div class="metric-inline">
              <span class="metric-label">SMA Fast (5)</span>
              <span class="metric-value" id="sma5">-</span>
            </div>
            <div class="metric-inline">
              <span class="metric-label">SMA Slow (20)</span>
              <span class="metric-value" id="sma20">-</span>
            </div>
            <div class="metric-inline">
              <span class="metric-label">BB Mid</span>
              <span class="metric-value" id="bbMid">-</span>
            </div>
            <div class="metric-inline">
              <span class="metric-label">BB Upper</span>
              <span class="metric-value" id="bbUp">-</span>
            </div>
            <div class="metric-inline">
              <span class="metric-label">BB Lower</span>
              <span class="metric-value" id="bbLow">-</span>
            </div>
          </div>

          <div class="ai-card" style="margin-top:12px;">
            <div class="ai-header">
              <div>
                <div class="ai-title">AI Market Insight (Data Realtime)</div>
                <div class="label">Ringkasan trend, momentum, volatilitas untuk latihan keputusan.</div>
              </div>
              <span id="aiTrendBadge" class="ai-badge">Menunggu data...</span>
            </div>
            <p id="aiText" class="ai-text">
              Setelah data beberapa puluh candle terkumpul, AI akan memberi komentar kondisi trend, momentum & volatilitas.
            </p>
            <p class="ai-note">Gunakan ini sebagai alat edukasi, bukan sinyal pasti. Fokus ke kualitas analisa, bukan tebak-tebakan.</p>

            <div class="pattern-card">
              <div class="pattern-title">AI Pola Candlestick (Realtime / Data)</div>
              <p class="label" style="margin-bottom:4px;">
                Pola dibaca dari 3 candle terakhir 1M. Cocok untuk latihan mengenali pola visual yang sering muncul.
              </p>
              <div class="pattern-row">
                <div>
                  <span class="pattern-label">Nama Pola</span><br>
                  <span class="pattern-value" id="patName">-</span>
                </div>
                <div>
                  <span class="pattern-label">Arah</span><br>
                  <span class="pattern-value" id="patDir">-</span>
                </div>
                <div>
                  <span class="pattern-label">Confidence</span><br>
                  <span class="pattern-value" id="patConf">-</span>
                </div>
              </div>
              <p class="ai-text" id="patNote">Menunggu data...</p>
            </div>
          </div>
        </section>

        <!-- PANEL KANAN: CHART + DETAIL + UPLOAD -->
        <section class="panel">
          <div class="chart-card">
            <div class="chart-header-row">
              <div>
                <div class="chart-title">Candlestick History 1M + Auto SNR</div>
                <div id="tfLabel" class="chart-sub">
                  History Candlestick · Interval: 1M · Pair: EUR/USD · TF Label: 1M · Zoom: scroll/pinch, Pan: drag.
                </div>
              </div>
              <div class="chart-tag">Garis cyan = Support, pink = Resistance</div>
            </div>
            <div class="mini-chart-inner">
              <canvas id="priceChart"></canvas>
            </div>
          </div>

          <div class="upload-card" style="margin-top:12px;">
            <div class="panel-header" style="margin-bottom:6px;">
              <div>
                <div class="panel-title">Upload Screenshot Market</div>
                <div class="panel-sub">Bandingkan hasil bacaan AI dari gambar chart (misal OlympTrade demo) dengan data realtime.</div>
              </div>
              <div class="chip-soft">Mode: AI Vision</div>
            </div>
            #{img_error_message ? "<p class=\"label\" style=\"color:#f97373;\">Error upload: #{img_error_message}</p>" : ""}
            <form action="/upload_chart" method="POST" enctype="multipart/form-data">
              <input type="file" name="chart_image" accept="image/*" required><br>
              <button type="submit" class="btn-refresh" style="font-size:12px;padding:7px 14px;margin-top:6px;">
                <span class="icon">🧠</span>
                <span>Upload Screenshot & Analisa AI</span>
              </button>
            </form>
            <p class="upload-note">Gunakan hanya screenshot chart. Jangan upload data pribadi atau informasi sensitif lainnya.</p>
            #{if uploaded_img_url
                "<img src=\"#{uploaded_img_url}\" class=\"upload-img\" alt=\"Uploaded chart\" />" \
                "<p class=\"label\" style=\"margin-top:6px;\">AI komentar:</p>" \
                "<p class=\"ai-text\">#{ai_image_comment || "Gambar sudah dianalisa AI."}</p>"
              else
                "<p class=\"label\" style=\"margin-top:6px;\">Belum ada screenshot yang diupload.</p>"
              end
            }
          </div>

          <div class="upload-card" style="margin-top:12px;">
            <div class="panel-title">Detail Data Aktif</div>
            <table class="pair-table">
              <tr><th>Parameter</th><th>Nilai</th></tr>
              <tr><td>Pair Name</td><td id="tblPair">-</td></tr>
              <tr><td>Pair Code</td><td id="tblPairCode">-</td></tr>
              <tr><td>Timeframe (data)</td><td id="tblTF">-</td></tr>
              <tr><td>Timeframe (label)</td><td id="tblTFView">-</td></tr>
              <tr><td>Harga Terakhir</td><td id="tblPrice">-</td></tr>
              <tr><td>RSI (14)</td><td id="tblRSI">-</td></tr>
              <tr><td>SMA Fast (5)</td><td id="tblSMA5">-</td></tr>
              <tr><td>SMA Slow (20)</td><td id="tblSMA20">-</td></tr>
              <tr><td>ATR (14)</td><td id="tblATR">-</td></tr>
              <tr><td>Bollinger Mid</td><td id="tblBBMid">-</td></tr>
              <tr><td>Bollinger Upper</td><td id="tblBBUp">-</td></tr>
              <tr><td>Bollinger Lower</td><td id="tblBBLow">-</td></tr>
              <tr><td>Waktu Candle Terakhir</td><td id="tblTime">-</td></tr>
            </table>

            <pre id="raw">{}</pre>
          </div>
        </section>
      </div>
    </div>

    <script>
      let chartObj=null,allCandles=[],currentTF="1m",currentPair="EURUSD",autoOn=false,autoTimer=null,lastData=null;

      async function ambilSignal(fromButton=false){
        const st=document.getElementById("status");
        st.innerText="Loading...";
        try{
          const res=await fetch("/signal?pair="+currentPair+"&t="+Date.now());
          if(!res.ok){
            let msg="HTTP "+res.status;
            try{const err=await res.json();if(err&&err.error)msg=err.error;}catch(e){}
            throw new Error(msg);
          }
          const data=await res.json();
          lastData = data;
          allCandles=data.candles||[];

          document.getElementById("titlePair").innerText="Signal "+(data.pair_name||currentPair)+" (1M Realtime)";
          const sigEl=document.getElementById("signal");
          sigEl.innerText=data.signal.toUpperCase();
          sigEl.className="signal-value "+data.signal;

          document.getElementById("price").innerText=data.last_price.toFixed(5);
          document.getElementById("rsi").innerText=data.indicators.rsi.toFixed(2);
          document.getElementById("sma5").innerText=data.indicators.sma_fast.toFixed(5);
          document.getElementById("sma20").innerText=data.indicators.sma_slow.toFixed(5);

          if (data.indicators.atr) {
            document.getElementById("atr").innerText = data.indicators.atr.toFixed(5);
            document.getElementById("tblATR").innerText = data.indicators.atr.toFixed(5);
          } else {
            document.getElementById("atr").innerText = "-";
            document.getElementById("tblATR").innerText = "-";
          }

          if (data.indicators.bb_middle) {
            document.getElementById("bbMid").innerText = data.indicators.bb_middle.toFixed(5);
            document.getElementById("bbUp").innerText  = data.indicators.bb_upper.toFixed(5);
            document.getElementById("bbLow").innerText = data.indicators.bb_lower.toFixed(5);

            document.getElementById("tblBBMid").innerText = data.indicators.bb_middle.toFixed(5);
            document.getElementById("tblBBUp").innerText  = data.indicators.bb_upper.toFixed(5);
            document.getElementById("tblBBLow").innerText = data.indicators.bb_lower.toFixed(5);
          } else {
            document.getElementById("bbMid").innerText = "-";
            document.getElementById("bbUp").innerText  = "-";
            document.getElementById("bbLow").innerText = "-";
            document.getElementById("tblBBMid").innerText = "-";
            document.getElementById("tblBBUp").innerText  = "-";
            document.getElementById("tblBBLow").innerText = "-";
          }

          document.getElementById("ctime").innerText=data.candle_time;

          document.getElementById("tblPair").innerText=data.pair_name||"-";
          document.getElementById("tblPairCode").innerText=data.pair_code||"-";
          document.getElementById("tblTF").innerText=data.timeframe||"1min";
          document.getElementById("tblTFView").innerText=currentTF+" (label tampilan)";
          document.getElementById("tblPrice").innerText=data.last_price.toFixed(5);
          document.getElementById("tblRSI").innerText=data.indicators.rsi.toFixed(2);
          document.getElementById("tblSMA5").innerText=data.indicators.sma_fast.toFixed(5);
          document.getElementById("tblSMA20").innerText=data.indicators.sma_slow.toFixed(5);
          document.getElementById("tblTime").innerText=data.candle_time;

          document.getElementById("raw").innerText=JSON.stringify(data,null,2);

          if (data.pattern) {
            document.getElementById("patName").innerText = data.pattern.name || "-";
            document.getElementById("patDir").innerText  = data.pattern.direction || "-";
            document.getElementById("patConf").innerText =
              data.pattern.confidence ? (data.pattern.confidence * 100).toFixed(0) + "%" : "-";
            document.getElementById("patNote").innerText = data.pattern.note || "";
          }

          drawFullHistory(data.pair_name||currentPair);
          analyzeMarketAI(data);

          st.innerText="Updated ✔"+(fromButton?" (manual)":"");
        }catch(e){
          st.innerText="Error: "+e.message;
          console.error(e);
        }
      }

      function drawFullHistory(pairName){
        const tfLabel=document.getElementById("tfLabel");
        tfLabel.innerText="History Candlestick · Interval: 1M · Pair: "+pairName+" · TF Label: "+currentTF+" · Zoom: scroll/pinch, Pan: drag.";
        drawCandleChart(allCandles);
      }

      function drawCandleChart(candles){
        const ctx=document.getElementById("priceChart").getContext("2d");
        const values=candles.map(c=>({x:new Date(c.time),o:c.open,h:c.high,l:c.low,c:c.close}));

        const snr = lastData && lastData.snr ? lastData.snr : {support: [], resistance: []};
        const supports = (snr.support || []).map(v => ({
          label: "Support " + v.toFixed(5),
          value: v
        }));
        const resistances = (snr.resistance || []).map(v => ({
          label: "Resistance " + v.toFixed(5),
          value: v
        }));

        if(chartObj)chartObj.destroy();

        chartObj=new Chart(ctx,{
          type:"candlestick",
          data:{
            datasets:[
              {
                label:"Price",
                data:values,
                type:"candlestick",
                color:{up:"#22c55e",down:"#f97373",unchanged:"#9ca3af"},
                borderColor:{up:"#16a34a",down:"#b91c1c",unchanged:"#9ca3af"},
                borderWidth:2,
                barThickness:6,
                maxBarThickness:8
              },
              ...supports.map(s => ({
                label: s.label,
                data: values.map(v => ({ x: v.x, y: s.value })),
                type: "line",
                borderWidth:1,
                borderColor:"#22d3ee",
                pointRadius:0
              })),
              ...resistances.map(r => ({
                label: r.label,
                data: values.map(v => ({ x: v.x, y: r.value })),
                type: "line",
                borderWidth:1,
                borderColor:"#ec4899",
                pointRadius:0
              }))
            ]
          },
          options:{
            plugins:{
              legend:{display:false},
              zoom:{pan:{enabled:true,mode:"x"},zoom:{wheel:{enabled:true},pinch:{enabled:true},drag:{enabled:false},mode:"x"}}
            },
            scales:{
              x:{type:"time",time:{unit:"minute",tooltipFormat:"HH:mm dd-LL"},
                ticks:{display:true,maxTicksLimit:8,color:"#9ca3af",font:{size:9}},
                grid:{display:true,color:"rgba(148,163,184,0.15)"},offset:true},
              y:{ticks:{display:true,color:"#9ca3af",font:{size:9}},grid:{display:true,color:"rgba(148,163,184,0.15)"}}
            },
            responsive:true,maintainAspectRatio:false
          }
        });
      }

      function analyzeMarketAI(data){
        const aiTextEl=document.getElementById("aiText"),badgeEl=document.getElementById("aiTrendBadge"),candles=data.candles||[];
        if(!aiTextEl||!badgeEl)return;
        const n=candles.length;
        if(n<20){
          badgeEl.className="ai-badge";
          badgeEl.innerText="Data minim";
          aiTextEl.innerText="Data candle masih sedikit. Tunggu beberapa menit supaya AI bisa membaca trend dan pola market.";
          return;
        }
        const closes=candles.map(c=>c.close),recent=closes.slice(-40),first=recent[0],last=recent[recent.length-1];
        const changePct=((last-first)/first)*100;
        const sliceForVol=candles.slice(-40);
        const ranges=sliceForVol.map(c=>c.high-c.low);
        const avgRange=ranges.reduce((a,b)=>a+b,0)/ranges.length;
        const lastRange=ranges[ranges.length-1];
        const volRatio=avgRange===0?1:lastRange/avgRange;
        const rsi=data.indicators&&data.indicators.rsi?data.indicators.rsi:null;
        const atrVal=data.indicators&&data.indicators.atr?data.indicators.atr:null;
        const pair=data.pair_name||data.pair_code||"Pair";
        const tf=data.timeframe||"1min";
        let trendBadge="SIDEWAYS",badgeClass="ai-badge badge-sideways",trendText="",rsiText="",volText="",atrText="",eduText="";
        if(changePct>0.6){trendBadge="UPTREND KUAT";badgeClass="ai-badge badge-up";trendText="Market "+pair+" pada "+tf+" sedang uptrend cukup kuat (+"+changePct.toFixed(2)+"% dalam ±40 candle).";}
        else if(changePct>0.2){trendBadge="UPTREND RINGAN";badgeClass="ai-badge badge-up";trendText="Market cenderung bullish ringan. Arah naik ada tapi tidak terlalu agresif.";}
        else if(changePct<-0.6){trendBadge="DOWNTREND KUAT";badgeClass="ai-badge badge-down";trendText="Market "+pair+" sedang downtrend kuat ("+Math.abs(changePct).toFixed(2)+"% turun dalam ±40 candle).";}
        else if(changePct<-0.2){trendBadge="DOWNTREND RINGAN";badgeClass="ai-badge badge-down";trendText="Market cenderung bearish ringan. Tekanan turun ada.";}
        else{trendBadge="SIDEWAYS";badgeClass="ai-badge badge-sideways";trendText="Market "+pair+" cenderung sideways / ranging.";}
        if(rsi!==null){
          if(rsi>70)rsiText=" RSI sekitar "+rsi.toFixed(1)+" (overbought). Waspada koreksi.";
          else if(rsi<30)rsiText=" RSI sekitar "+rsi.toFixed(1)+" (oversold). Ada potensi bounce.";
          else rsiText=" RSI sekitar "+rsi.toFixed(1)+" (zona netral).";
        }
        if(volRatio>1.5)volText=" Volatilitas di atas rata-rata, candle lebih panjang dari biasanya.";
        else if(volRatio<0.7)volText=" Volatilitas rendah, candle kecil-kecil. Rawan fake signal.";
        else volText=" Volatilitas normal, cocok untuk latihan membaca pola dengan tenang.";
        if(atrVal!==null){
          atrText=" ATR(14) sekitar "+atrVal.toFixed(5)+", gunakan sebagai gambaran range gerak normal per candle.";
        }
        if(trendBadge.includes("UPTREND"))eduText=" Latihan: fokus BUY di arah trend setelah koreksi, jangan kejar candle yang sudah sangat panjang.";
        else if(trendBadge.includes("DOWNTREND"))eduText=" Latihan: fokus SELL setelah pullback gagal tembus resistance, hindari melawan trend.";
        else eduText=" Latihan terbaik di sideways adalah belajar MENAHAN diri, tunggu breakout jelas.";
        badgeEl.className=badgeClass;badgeEl.innerText=trendBadge;
        aiTextEl.innerText=trendText+rsiText+volText+atrText+eduText;
      }

      function setupTimeframeButtons(){
        const buttons=document.querySelectorAll(".tf-btn");
        buttons.forEach(btn=>{
          btn.addEventListener("click",()=>{
            buttons.forEach(b=>b.classList.remove("active"));
            btn.classList.add("active");
            currentTF=btn.getAttribute("data-tf");
            document.getElementById("tblTFView").innerText=currentTF+" (label tampilan)";
            if(allCandles.length>0)drawFullHistory(document.getElementById("tblPair").innerText||currentPair);
          });
        });
      }

      function setupPairButtons(){
        const buttons=document.querySelectorAll(".pair-btn");
        buttons.forEach(btn=>{
          btn.addEventListener("click",()=>{
            buttons.forEach(b=>b.classList.remove("active"));
            btn.classList.add("active");
            currentPair=btn.getAttribute("data-pair");
            ambilSignal(true);
          });
        });
      }

      function toggleAuto(){
        autoOn=!autoOn;
        const btn=document.getElementById("autoBtn");
        const span = btn.querySelector("span:nth-child(2)");
        if(autoOn){
          btn.classList.add("on");
          span.innerText="AUTO: ON";
          autoTimer=setInterval(()=>ambilSignal(false),15000);
        }else{
          btn.classList.remove("on");
          span.innerText="AUTO: OFF";
          if(autoTimer)clearInterval(autoTimer);
        }
      }

      window.onload=()=>{setupTimeframeButtons();setupPairButtons();ambilSignal(true);};
    </script>
  </body>
  </html>
  HTML
end
