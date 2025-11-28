require 'sinatra'
require 'json'
require 'httparty'
require 'fileutils'
require 'securerandom'
require 'uri'
require 'base64'

set :bind, '0.0.0.0'
set :port, ENV.fetch('PORT', 4567)
set :public_folder, File.dirname(__FILE__) + '/public'

FileUtils.mkdir_p(File.join(settings.public_folder, 'uploads'))

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
end

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
    signal    = decide_signal(sma_fast, sma_slow, rsi_val)

    {
      pair_name:   cfg[:name],
      pair_code:   pair_code,
      timeframe:   "1min",
      last_price:  closes.last,
      candle_time: candles.last[:time],
      signal:      signal,
      indicators: {
        sma_fast: sma_fast,
        sma_slow: sma_slow,
        rsi:      rsi_val
      },
      candles: candles
    }.to_json
  rescue => e
    status 500
    { error: e.message }.to_json
  end
end

post "/upload_chart" do
  begin
    file_param = params["chart_image"]
    raise "File tidak ditemukan" if file_param.nil?

    tempfile  = file_param[:tempfile]
    ext       = File.extname(file_param[:filename])
    ext       = ".png" if ext.empty?
    safe_name = "#{SecureRandom.hex(8)}#{ext}"
    upload_path = File.join(settings.public_folder, "uploads", safe_name)

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
              text: "Ini screenshot chart trading. Analisa trend (uptrend/downtrend/sideways), momentum, volatilitas, dan beri saran edukasi latihan akun demo. Bahasa Indonesia, singkat dan jelas."
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
  <title>FX Realtime 1M Dashboard</title>
  <script src="https://cdn.jsdelivr.net/npm/luxon@1.26.0"></script>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@3.9.1/dist/chart.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-luxon@1.0.0"></script>
  <script src="https://www.chartjs.org/chartjs-chart-financial/chartjs-chart-financial.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/hammerjs@2.0.8"></script>
  <script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-zoom@1.2.1/dist/chartjs-plugin-zoom.min.js"></script>
  <style>
  :root {
    --bg-dark:#0b0f17;--bg-card:#131a24;--text-main:#e5e7eb;--muted:#9ca3af;
    --green:#00ff55;--red:#ff1744;--yellow:#ffe159;
  }
  *{box-sizing:border-box;}
  body{margin:0;font-family:Arial, sans-serif;background:var(--bg-dark);color:var(--text-main);}
  .shell{max-width:1100px;margin:0 auto;padding:14px;}
  h1{text-align:center;margin-bottom:15px;}
  .btn-refresh{
    margin:auto;display:flex;align-items:center;justify-content:center;
    background:var(--red);border:2px solid var(--green);color:#fff;
    font-weight:bold;cursor:pointer;padding:10px 22px;border-radius:12px;
    font-size:18px;text-shadow:0 0 8px var(--green);
    box-shadow:0 0 12px var(--green),inset 0 0 6px rgba(0,255,136,0.5);
    transition:0.2s;
  }
  .btn-refresh:hover{transform:scale(1.04);box-shadow:0 0 18px var(--green),inset 0 0 10px rgba(0,255,136,0.7);}
  .btn-refresh:active{transform:scale(0.97);}
  .status-text{text-align:center;color:var(--muted);margin:6px 0 10px;font-size:13px;}
  .auto-row{display:flex;align-items:center;justify-content:center;gap:10px;margin-bottom:10px;font-size:13px;color:var(--muted);}
  .auto-btn{padding:4px 12px;border-radius:999px;border:1px solid var(--green);background:#020617;color:var(--green);cursor:pointer;font-size:11px;}
  .auto-btn.on{background:var(--red);color:#fff;box-shadow:0 0 10px rgba(0,255,136,0.7);}
  .card{background:var(--bg-card);padding:14px;border-radius:16px;border:1px solid #1f2937;box-shadow:0 0 22px rgba(0,255,136,0.08);margin-bottom:16px;}
  .signal-header-row{display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap;}
  .signal-value{font-size:40px;font-weight:bold;}
  .buy{color:var(--green);} .sell{color:var(--red);} .hold{color:var(--yellow);}
  .tf-group,.pair-group{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px;}
  .tf-btn,.pair-btn{
    padding:5px 10px;border-radius:999px;border:1.5px solid var(--green);
    background:#020617;cursor:pointer;font-size:11px;color:var(--green);
    text-shadow:0 0 4px rgba(0,255,136,0.5);box-shadow:0 0 8px rgba(0,255,136,0.35);transition:0.15s;
  }
  .tf-btn:hover,.pair-btn:hover{transform:translateY(-1px);}
  .tf-btn.active,.pair-btn.active{
    background:var(--red);color:#fff;border-color:var(--green);
    box-shadow:0 0 12px rgba(0,255,136,0.75),inset 0 0 6px rgba(0,0,0,0.6);
  }
  .mini-chart-card{height:320px;}
  .mini-chart-inner{position:relative;height:260px;}
  #priceChart{height:260px!important;width:100%!important;}
  .ai-card{border-left:3px solid var(--green);}
  .ai-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:6px;}
  .ai-title{font-weight:bold;font-size:15px;}
  .ai-badge{padding:3px 10px;border-radius:999px;font-size:11px;border:1px solid #4b5563;}
  .badge-up{border-color:var(--green);color:var(--green);}
  .badge-down{border-color:var(--red);color:var(--red);}
  .badge-sideways{border-color:var(--yellow);color:var(--yellow);}
  .ai-text{font-size:13px;line-height:1.4;margin-bottom:6px;}
  .ai-note{font-size:11px;color:var(--muted);}
  .pair-table{width:100%;border-collapse:collapse;font-size:13px;}
  .pair-table th,.pair-table td{border:1px solid #1f2937;padding:6px 8px;}
  .pair-table th{background:#0f172a;text-align:left;}
  .pair-table tr:nth-child(even){background:#111827;}
  .upload-img{max-width:100%;border-radius:12px;margin-top:8px;border:1px solid #374151;}
  .upload-note,.label{font-size:11px;color:var(--muted);}
  pre{margin-top:8px;background:#020617;color:var(--muted);padding:10px;border-radius:10px;font-size:11px;max-height:200px;overflow:auto;}
  </style>
  </head>
  <body>
  <div class="shell">
    <h1>FX Realtime 1M Dashboard</h1>
    <button class="btn-refresh" onclick="ambilSignal(true)">REFRESH SIGNAL ⚡</button>
    <div class="auto-row">
      <span>Auto refresh (15 detik):</span>
      <button id="autoBtn" class="auto-btn" onclick="toggleAuto()">OFF</button>
    </div>
    <p id="status" class="status-text">Ready...</p>

    <div class="card">
      <div class="signal-header-row">
        <div style="flex:1;">
          <h2 id="titlePair" style="margin:0 0 4px 0;">Signal EUR/USD (1M Realtime)</h2>
          <div class="label">Data: Twelve Data · Interval: 1M. Cocok untuk latihan di akun demo.</div>
          <div style="margin-top:8px;">
            <div class="label" style="margin-bottom:2px;">Pilih Pair:</div>
            <div class="pair-group">
              <button class="pair-btn active" data-pair="EURUSD">EUR/USD</button>
              <button class="pair-btn" data-pair="GBPUSD">GBP/USD</button>
              <button class="pair-btn" data-pair="USDJPY">USD/JPY</button>
            </div>
          </div>
        </div>
        <div>
          <div class="label" style="margin-bottom:2px;">Timeframe Label (catatan):</div>
          <div class="tf-group">
            <button class="tf-btn active" data-tf="1m">1M</button>
            <button class="tf-btn" data-tf="5m">5M</button>
            <button class="tf-btn" data-tf="15m">15M</button>
            <button class="tf-btn" data-tf="30m">30M</button>
            <button class="tf-btn" data-tf="1h">1H</button>
          </div>
        </div>
      </div>
      <div id="signal" class="signal-value" style="margin-top:10px;">-</div>
      <p>Last Price: <b id="price"></b></p>
      <p>RSI(14): <b id="rsi"></b></p>
      <p>SMA Fast (5): <b id="sma5"></b></p>
      <p>SMA Slow (20): <b id="sma20"></b></p>
      <p><span class="label">Candle latest: </span><b id="ctime"></b></p>
    </div>

    <div class="card mini-chart-card">
      <div class="label" id="tfLabel">
        History Candlestick · Interval: 1M · Pair: EUR/USD · TF Label: 1M · Zoom: scroll/pinch, Pan: drag.
      </div>
      <div class="mini-chart-inner">
        <canvas id="priceChart"></canvas>
      </div>
    </div>

    <div class="card ai-card">
      <div class="ai-header">
        <span class="ai-title">AI Market Insight (Data Realtime)</span>
        <span id="aiTrendBadge" class="ai-badge">Menunggu data...</span>
      </div>
      <p id="aiText" class="ai-text">
        Setelah data beberapa puluh candle terkumpul, AI akan memberi komentar kondisi trend, momentum & volatilitas.
      </p>
      <p class="ai-note">Ini alat edukasi, bukan saran finansial.</p>
    </div>

    <div class="card">
      <h3 style="margin-top:0;">Upload Screenshot Market</h3>
      <p class="label">Upload screenshot chart (misal dari OlympTrade akun demo) untuk dianalisa AI.</p>
      #{img_error_message ? "<p class=\"label\" style=\"color:#f97373;\">Error upload: #{img_error_message}</p>" : ""}
      <form action="/upload_chart" method="POST" enctype="multipart/form-data">
        <input type="file" name="chart_image" accept="image/*" required style="margin-bottom:8px;color:var(--text-main);"><br>
        <button type="submit" class="btn-refresh" style="font-size:14px;padding:6px 16px;margin-top:4px;">
          Upload Screenshot & Analisa AI
        </button>
      </form>
      <p class="upload-note">Jangan upload data pribadi, hanya screenshot chart.</p>
      #{if uploaded_img_url
          "<img src=\"#{uploaded_img_url}\" class=\"upload-img\" alt=\"Uploaded chart\" />" \
          "<p class=\"label\" style=\"margin-top:6px;\">AI komentar:</p>" \
          "<p class=\"ai-text\">#{ai_image_comment || "Gambar sudah dianalisa AI."}</p>"
        else
          "<p class=\"label\" style=\"margin-top:6px;\">Belum ada screenshot yang diupload.</p>"
        end
      }
    </div>

    <div class="card">
      <div class="pair-table-title">Detail Pair</div>
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
        <tr><td>Waktu Candle Terakhir</td><td id="tblTime">-</td></tr>
      </table>
    </div>

    <pre id="raw">{}</pre>
  </div>

  <script>
  let chartObj=null,allCandles=[],currentTF="1m",currentPair="EURUSD",autoOn=false,autoTimer=null;
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
      allCandles=data.candles||[];
      document.getElementById("titlePair").innerText="Signal "+(data.pair_name||currentPair)+" (1M Realtime)";
      document.getElementById("signal").innerText=data.signal.toUpperCase();
      document.getElementById("signal").className="signal-value "+data.signal;
      document.getElementById("price").innerText=data.last_price.toFixed(5);
      document.getElementById("rsi").innerText=data.indicators.rsi.toFixed(2);
      document.getElementById("sma5").innerText=data.indicators.sma_fast.toFixed(5);
      document.getElementById("sma20").innerText=data.indicators.sma_slow.toFixed(5);
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
    if(chartObj)chartObj.destroy();
    chartObj=new Chart(ctx,{
      type:"candlestick",
      data:{datasets:[{label:"Price",data:values,color:{up:"#00ff55",down:"#ff1744",unchanged:"#9ca3af"},
      borderColor:{up:"#00cc44",down:"#d50032",unchanged:"#9ca3af"},borderWidth:2,barThickness:6,maxBarThickness:8}]},
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
    const pair=data.pair_name||data.pair_code||"Pair";
    const tf=data.timeframe||"1min";
    let trendBadge="SIDEWAYS",badgeClass="ai-badge badge-sideways",trendText="",rsiText="",volText="",eduText="";
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
    if(trendBadge.includes("UPTREND"))eduText=" Latihan: fokus BUY di arah trend setelah koreksi, jangan kejar candle yang sudah sangat panjang.";
    else if(trendBadge.includes("DOWNTREND"))eduText=" Latihan: fokus SELL setelah pullback gagal tembus resistance, hindari melawan trend.";
    else eduText=" Latihan terbaik di sideways adalah belajar MENAHAN diri, tunggu breakout jelas.";
    badgeEl.className=badgeClass;badgeEl.innerText=trendBadge;
    aiTextEl.innerText=trendText+rsiText+volText+eduText;
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
    if(autoOn){
      btn.classList.add("on");btn.innerText="ON";
      autoTimer=setInterval(()=>ambilSignal(false),15000);
    }else{
      btn.classList.remove("on");btn.innerText="OFF";
      if(autoTimer)clearInterval(autoTimer);
    }
  }
  window.onload=()=>{setupTimeframeButtons();setupPairButtons();ambilSignal(true);};
  </script>
  </body>
  </html>
  HTML
end
