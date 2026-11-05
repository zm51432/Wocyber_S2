/* S2 硬件控制台 前端逻辑 */
const $ = (s) => document.querySelector(s);
const state = { conf: null, leds: [] };
const GAUGE_C = 301.6;
const NEST = { cpu: 2 * Math.PI * 86, hdd: 2 * Math.PI * 66, fan: 2 * Math.PI * 46 };  // 同心环嵌套仪表盘各环周长          // r=48 的圆周长
const TREND_N = 40;             // 趋势图采样点数
const HIST = { cpu: [], hdd: [] };
let histSeeded = false;
let fanTouch = 0;          // 最近一次手动调节风扇挡位的时间戳（防止轮询把滑块抢回去）

function toast(msg, ok) {
  const t = $('#toast');
  t.textContent = msg;
  t.className = 'toast show ' + (ok === false ? 'err' : 'ok');
  setTimeout(() => (t.className = 'toast'), 2600);
}

async function api(path, body) {
  const opt = { headers: {} };
  if (localStorage.s2token) opt.headers['X-S2-Token'] = localStorage.s2token;
  if (body) {
    opt.method = 'POST';
    opt.headers['Content-Type'] = 'application/json';
    opt.body = JSON.stringify(body);
  }
  const r = await fetch(path, opt);
  if (r.status === 401) {
    const v = prompt('请输入访问口令');
    if (v) { localStorage.s2token = v; return api(path, body); }
    throw new Error('需要口令');
  }
  return r.json();
}

async function hw(op, params, quiet) {
  const r = await api('/api/hw', { op, params });
  if (!quiet) toast(r.msg || (r.ok ? '完成' : '失败'), r.ok);
  return r;
}

/* ---------- 环形仪表 ---------- */
function setGauge(boxId, valId, val, max, warn, crit) {
  const box = document.getElementById(boxId);
  const el = document.getElementById(valId);
  if (!el || !box) return;
  el.textContent = (val === 0 || val) ? val : '—';
  box.classList.remove('warn', 'crit');
  const ring = box.querySelector('.g-prog');
  const n = parseFloat(val);
  if (isNaN(n) || n === undefined) {
    if (ring) ring.style.strokeDashoffset = GAUGE_C;
    return;
  }
  const p = Math.max(0, Math.min(1, n / max));
  if (ring) ring.style.strokeDashoffset = (GAUGE_C * (1 - p)).toFixed(1);
  if (crit && n >= crit) box.classList.add('crit');
  else if (warn && n >= warn) box.classList.add('warn');
}

/* ---------- 同心环嵌套仪表盘 ---------- */
function setRing(id, val, max, warn, crit) {
  const el = document.querySelector('.ng-prog.ng-' + id);
  if (!el) return;
  const C = NEST[id];
  const n = parseFloat(val);
  el.style.strokeDasharray = C.toFixed(1);
  el.classList.remove('warn', 'crit');
  if (isNaN(n)) { el.style.strokeDashoffset = C; return; }
  const p = Math.max(0, Math.min(1, n / max));
  el.style.strokeDashoffset = (C * (1 - p)).toFixed(1);
  if (crit && n >= crit) el.classList.add('crit');
  else if (warn && n >= warn) el.classList.add('warn');
}

/* ---------- 温度趋势 ---------- */
function trendY(v) {
  const lo = 20, hi = 100, n = Math.max(lo, Math.min(hi, v));
  return 104 - ((n - lo) / (hi - lo)) * 104;
}
function pushTrend(d) {
  const c = (d.cpu_temp === 0 || d.cpu_temp) ? parseFloat(d.cpu_temp) : NaN;
  const h = (d.hdd_max_temp === 0 || d.hdd_max_temp) ? parseFloat(d.hdd_max_temp) : NaN;
  if (!histSeeded) {                       // 首次：围绕当前值铺满带轻微波动，一进来就有完整曲线
    for (let i = 0; i < TREND_N; i++) {
      HIST.cpu.push(isNaN(c) ? NaN : c + Math.sin(i / 3.1) * 2.4 + (Math.random() - 0.5) * 2);
      HIST.hdd.push(isNaN(h) ? NaN : h + Math.sin(i / 2.7) * 1.8 + (Math.random() - 0.5) * 1.6);
    }
    histSeeded = true;
  } else {
    HIST.cpu.push(c); HIST.hdd.push(h);
    if (HIST.cpu.length > TREND_N) { HIST.cpu.shift(); HIST.hdd.shift(); }
  }
  drawTrend();
}
function drawTrend() {
  ['cpu', 'hdd'].forEach((k) => {
    const arr = HIST[k];
    const line = document.getElementById('tl-' + k);
    const dot = document.getElementById('tp-' + k);
    if (!line) return;
    const pts = [];
    let lastIdx = -1;
    for (let i = 0; i < arr.length; i++) {
      const v = arr[i];
      if (v == null || isNaN(v)) continue;
      const x = 320 * (i / (TREND_N - 1));
      pts.push(x.toFixed(1) + ',' + trendY(v).toFixed(1));
      lastIdx = i;
    }
    line.setAttribute('points', pts.join(' '));
    if (!dot) return;
    if (lastIdx < 0) dot.setAttribute('cx', -9);
    else {
      dot.setAttribute('cx', (320 * (lastIdx / (TREND_N - 1))).toFixed(1));
      dot.setAttribute('cy', trendY(arr[lastIdx]).toFixed(1));
    }
  });
}

/* ---------- 状态灯泡 ---------- */
function setBulb(id, mode) {
  const el = document.getElementById(id);
  if (el) el.className = 'bulb ' + (mode || '');
}

/* 硬盘数量：fan-control 写入的 disks 是每盘温度快照，形如 "sda=33 sdb=41"，
   老版本也可能是纯数字。两种都要能正确得出盘数（原来直接 parseInt 会得到 NaN，
   导致「无硬盘 → 灯全灭」误判）。 */
function diskCount(v) {
  if (typeof v === "string") {
    const m = v.match(/[A-Za-z0-9_]+=-?[0-9]+/g);
    if (m && m.length) return m.length;
    return parseInt(v, 10) || 0;
  }
  return parseInt(v, 10) || 0;
}

/* ---------- 渲染 ---------- */
function renderStatus(d) {
  setRing('cpu', d.cpu_temp, 100, 70, 85);
  setRing('hdd', d.hdd_max_temp, 80, 50, 60);
  setRing('fan', d.fan_level, 15, 11, 14);
  const cpuV = (d.cpu_temp === 0 || d.cpu_temp) ? +d.cpu_temp : null;
  const hddV = (d.hdd_max_temp === 0 || d.hdd_max_temp) ? +d.hdd_max_temp : null;
  const sysT = Math.max(cpuV == null ? -Infinity : cpuV, hddV == null ? -Infinity : hddV);
  $('#ng-temp').textContent = isFinite(sysT) ? sysT : '—';
  $('#ng-cpu-v').textContent = cpuV == null ? '—' : d.cpu_temp;
  $('#ng-hdd-v').textContent = hddV == null ? '—' : d.hdd_max_temp;
  $('#ng-fan-v').textContent = (d.fan_level === 0 || d.fan_level) ? d.fan_level : '—';
  pushTrend(d);

  $('#b-uid').textContent = d.root ? 'root 直控' : '应用用户（需代理）';
  $('#b-uid').className = 'pill' + (d.root ? ' okp' : ' warnp');
  $('#b-port').textContent = '端口 ' + (d.port || '—');
  $('#b-host').textContent = d.hostname || '—';

  const svc = $('#s-services');
  svc.innerHTML = '';
  for (const [k, v] of Object.entries(d.services || {})) {
    const s = document.createElement('span');
    let label = v, cls = '';
    if (v === 'active') { cls = 'on'; label = '运行中'; }
    else if (v === 'done') { cls = 'on'; label = '已执行'; }   // oneshot 守卫跑完即正常退出
    else if (v === 'unknown') { s.style.display = 'none'; }
    else { cls = 'off'; label = v; }                            // 真正的异常才标红
    if (cls) s.className = cls;
    if (v !== 'unknown') s.textContent = k + ': ' + label;
    svc.appendChild(s);
  }

  const tag = $('#s-tag');
  const bad = Object.values(d.services || {}).some((v) => v !== 'active' && v !== 'done' && v !== 'unknown');
  tag.textContent = bad ? 'SERVICE ALERT' : 'SYSTEM NOMINAL';
  tag.className = 'hd-tag' + (bad ? ' alert' : '');
  $('#s-updated').textContent = new Date().toTimeString().slice(0, 8);

  /* 电源灯：网络状态指示 */
  const nl = d.net_link || {};
  const nState = $('#p-net-state');
  const povr = (d.conf.led_override || {}).power || 'auto';
  $('#p-ovr').value = povr;
  nState.className = 'state';
  if (povr === 'off') {
    nState.classList.add('warn');
    nState.textContent = '手动覆盖：电源灯已全灭（优先级最高）';
    setBulb('p-bulb', 'grey');
  } else if (!nl.deployed) {
    nState.classList.add('warn');
    nState.textContent = '网络状态灯未部署（可在「脚本修复」执行 00-部署全部硬件配置）';
    setBulb('p-bulb', 'grey');
  } else if (nl.up) {
    nState.textContent = '链路已连接 · ' + (nl.iface || 'up') + ' → 绿灯常亮';
    setBulb('p-bulb', 'g');
  } else {
    nState.classList.add('down');
    nState.textContent = '无网络链路 → 红灯闪烁';
    setBulb('p-bulb', 'rb');
  }

  /* 硬盘灯 */
  const dovr = (d.conf.led_override || {}).sata || 'auto';
  $('#d-ovr').value = dovr;
  const nDisk = diskCount(d.disks);
  const dState = $('#d-led-state');
  dState.className = 'state';
  if (dovr === 'off') {
    dState.classList.add('warn');
    dState.textContent = '手动覆盖：硬盘灯已全灭（优先级最高）';
    setBulb('d-bulb', 'grey');
  } else if (nDisk > 0) {
    dState.textContent = '检测到硬盘 → 绿灯常亮';
    setBulb('d-bulb', 'g');
  } else {
    dState.textContent = '无硬盘 → 红绿灯全灭';
    setBulb('d-bulb', 'grey');
  }

  /* 风扇 */
  const fc = d.conf.fan || {};
  // 后端只存 auto/manual；手动控温在后端仍走 auto，用 FAN_UI_MODE 还原前端标签页
  $('#f-mode').value = fc.FAN_UI_MODE || (fc.MODE === 'manual' ? 'manual' : 'auto');
  // 手动调节中（或刚调完 5s 内）不回写滑块，否则轮询会把挡位拽回去、手感卡顿
  if (Date.now() - fanTouch > 5000) {
    $('#f-level').value = fc.MANUAL_LEVEL || 6;
    $('#f-level-v').textContent = fc.MANUAL_LEVEL || 6;
  }
  $('#f-h0').value = fc.HDD_TEMP_OFF || 40;
  $('#f-h1').value = fc.HDD_TEMP_LOW || 45;
  $('#f-h2').value = fc.HDD_TEMP_MID || 55;
  $('#f-h3').value = fc.HDD_TEMP_MAX || 60;
  $('#f-c0').value = fc.TEMP_OFF || 60;
  $('#f-c1').value = fc.TEMP_LOW || 65;
  $('#f-c2').value = fc.TEMP_MID || 80;
  $('#f-c3').value = fc.TEMP_CRITICAL || 100;
  // 模式联动放在曲线赋值之后：避免自动模式的固定值被上面的 config 值覆盖
  applyFanMode();
  // 扇叶：按当前实际转速旋转，0 挡静止
  $('#f-cur').textContent = (d.fan_level === 0 || d.fan_level) ? d.fan_level : '—';
  const blade = $('#fan-blade');
  const lv = parseFloat(d.fan_level);
  if (!blade) { /* noop */ }
  else if (isNaN(lv) || lv <= 0) blade.classList.add('still');
  else { blade.classList.remove('still'); blade.style.animationDuration = (2.6 - (Math.min(lv, 15) / 15) * 2.1).toFixed(2) + 's'; }

  /* 蜂鸣器 */
  const bp = d.conf.beep || {};
  $('#b-ms').value = bp.beep_ms || 280;
  $('#b-ms-v').textContent = bp.beep_ms || 280;

  /* 定时开关机 */
  const sc = d.conf.power_schedule || {};
  $('#sch-enable').checked = sc.enabled === '1';
  $('#sch-shutdown').value = sc.shutdown_time || '';
  $('#sch-boot').value = sc.boot_time || '';
  const schHint = $('#sch-hint');
  schHint.textContent = sc.rtc_wake
    ? '关机为每日到点自动 poweroff；开机依赖主板 RTC 定时唤醒（已检测到 RTC，支持定时开机）。'
    : '关机为每日到点自动 poweroff；未检测到 RTC 唤醒能力，定时开机可能不生效。';

  /* 端口 */
  if (d.port) $('#port-v').value = d.port;

  renderScripts(d.scripts || []);
}

function renderScripts(list) {
  const box = $('#scripts');
  box.innerHTML = '';
  list.forEach((s) => {
    const b = document.createElement('button');
    b.textContent = (s.builtin ? '⚙ ' : '📄 ') + s.name;
    if (s.builtin) b.className = 'bi';
    b.onclick = () => runScript(s.name);
    box.appendChild(b);
  });
}

/* ---------- 脚本执行 ---------- */
let pollTimer = null;
async function runScript(name) {
  const r = await api('/api/script/start', { name });
  if (!r.ok) return toast(r.msg, false);
  $('#log').textContent = '// 正在执行 ' + name + '\n';
  clearInterval(pollTimer);
  pollTimer = setInterval(async () => {
    const p = await fetch('/api/script/poll?job=' + r.job, {
      headers: localStorage.s2token ? { 'X-S2-Token': localStorage.s2token } : {},
    }).then((x) => x.json());
    $('#log').textContent = '// ' + name + '\n' + (p.lines || []).join('\n');
    $('#log').scrollTop = $('#log').scrollHeight;
    if (p.done) {
      clearInterval(pollTimer);
      $('#log').textContent += '\n// 结束，退出码 ' + p.rc;
      toast('脚本执行结束（退出码 ' + p.rc + '）', p.rc === 0);
      refresh();
    }
  }, 700);
}

/* ---------- 卡片跟光 ---------- */
function initGlow() {
  document.querySelectorAll('.card').forEach((c) => {
    c.addEventListener('pointermove', (e) => {
      const r = c.getBoundingClientRect();
      c.style.setProperty('--mx', (((e.clientX - r.left) / r.width) * 100).toFixed(1) + '%');
      c.style.setProperty('--my', (((e.clientY - r.top) / r.height) * 100).toFixed(1) + '%');
    });
  });
}

/* ---------- 背景粒子星座 ---------- */
function initBg() {
  const cv = document.getElementById('bgfx');
  if (!cv || !cv.getContext) return;
  const ctx = cv.getContext('2d');
  if (!ctx) return;
  let w = 0, h = 0, dpr = 1, pts = [];
  const reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  function size() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    w = cv.width = Math.floor(window.innerWidth * dpr);
    h = cv.height = Math.floor(window.innerHeight * dpr);
    cv.style.width = window.innerWidth + 'px';
    cv.style.height = window.innerHeight + 'px';
    const n = Math.min(58, Math.max(22, Math.round((window.innerWidth * window.innerHeight) / 28000)));
    pts = [];
    for (let i = 0; i < n; i++) {
      pts.push({
        x: Math.random() * w, y: Math.random() * h,
        vx: (Math.random() - 0.5) * 0.22 * dpr, vy: (Math.random() - 0.5) * 0.22 * dpr,
        r: (Math.random() * 1.2 + 0.6) * dpr,
      });
    }
  }
  function draw() {
    ctx.clearRect(0, 0, w, h);
    const lim = 132 * dpr, lim2 = lim * lim;
    for (let i = 0; i < pts.length; i++) {
      const p = pts[i];
      if (!reduce) {
        p.x += p.vx; p.y += p.vy;
        if (p.x < 0 || p.x > w) p.vx *= -1;
        if (p.y < 0 || p.y > h) p.vy *= -1;
      }
      for (let j = i + 1; j < pts.length; j++) {
        const q = pts[j], dx = p.x - q.x, dy = p.y - q.y, d2 = dx * dx + dy * dy;
        if (d2 < lim2) {
          const a = (1 - d2 / lim2) * 0.17;
          ctx.strokeStyle = 'rgba(96,196,255,' + a.toFixed(3) + ')';
          ctx.lineWidth = 1 * dpr;
          ctx.beginPath(); ctx.moveTo(p.x, p.y); ctx.lineTo(q.x, q.y); ctx.stroke();
        }
      }
      ctx.fillStyle = 'rgba(150,225,255,.5)';
      ctx.beginPath(); ctx.arc(p.x, p.y, p.r, 0, 6.2832); ctx.fill();
    }
  }
  size();
  window.addEventListener('resize', () => { size(); if (reduce) draw(); });
  if (reduce) { draw(); return; }
  (function loop() { draw(); requestAnimationFrame(loop); })();
}


/* 自动温控固定阈值（不可调节）：CPU 50/60/70/80℃，硬盘 40/50/55/60℃ */
const AUTO_CPU = { off: 50, low: 60, mid: 70, crit: 80 };
const AUTO_HDD = { off: 40, low: 50, mid: 55, max: 60 };

/* 风扇模式联动（三种模式）：
   自动温控(auto)      -> 显示锁定说明(f-lock)，滑块禁用；
   手动控温(manual_temp)-> 显示可编辑曲线(f-curve)，滑块禁用（仍是自动调速，只是阈值可改）；
   手动挡位(manual)    -> 显示说明(f-manual-note)，【滑块可拖动】直接设定固定挡位。 */
function applyFanMode() {
  const mode = $('#f-mode').value;
  const lock = $('#f-lock');
  const box = $('#f-curve');
  const mnote = $('#f-manual-note');
  const lvl = $('#f-level');
  const lockOn = mode === 'auto';
  const curveOn = mode === 'manual_temp';
  const manualOn = mode === 'manual';
  if (lock) lock.classList.toggle('hidden', !lockOn);      // 自动：显示锁定说明
  if (box) box.classList.toggle('hidden', !curveOn);        // 手动控温：显示可编辑曲线
  if (mnote) mnote.classList.toggle('hidden', !manualOn);   // 手动挡位：显示说明
  if (lvl) lvl.disabled = !manualOn;                       // 仅手动挡位可拖动滑块
  // 自动模式：隐藏右侧数值 "X/15"，改用"自动"提示，避免显示数字
  const showNum = !lockOn;
  const fv = $('#f-level-v'), fmax = $('#f-level-max'), fauto = $('#f-level-auto');
  if (fv) fv.classList.toggle('hidden', !showNum);
  if (fmax) fmax.classList.toggle('hidden', !showNum);
  if (fauto) fauto.classList.toggle('hidden', showNum);
  if (lockOn) {                                            // 自动：固定参数落进隐藏输入框
    $('#f-h0').value = AUTO_HDD.off; $('#f-h1').value = AUTO_HDD.low;
    $('#f-h2').value = AUTO_HDD.mid; $('#f-h3').value = AUTO_HDD.max;
    $('#f-c0').value = AUTO_CPU.off; $('#f-c1').value = AUTO_CPU.low;
    $('#f-c2').value = AUTO_CPU.mid; $('#f-c3').value = AUTO_CPU.crit;
  }
}

/* 组装 set_fan 参数：
   - 自动温控 / 手动控温 后端都走 auto（自动调速），区别仅在于阈值是否固定；
   - 手动挡位 后端走 manual（固定挡位）；
   - 额外带 ui_mode 便于前端刷新后还原标签页。 */
function fanPayload(persist) {
  const mode = $('#f-mode').value;
  let backendMode = 'auto', cpu = AUTO_CPU, hdd = AUTO_HDD;
  if (mode === 'manual_temp') {
    cpu = { off: +$('#f-c0').value, low: +$('#f-c1').value, mid: +$('#f-c2').value, crit: +$('#f-c3').value };
    hdd = { off: +$('#f-h0').value, low: +$('#f-h1').value, mid: +$('#f-h2').value, max: +$('#f-h3').value };
  } else if (mode === 'manual') {
    backendMode = 'manual';
  }
  return { mode: backendMode, ui_mode: mode, level: +$('#f-level').value, persist, hdd, cpu };
}
/* ---------- 事件 ---------- */
function bind() {
  $('#btn-refresh').onclick = refresh;
  const syncLevel = (e) => {
    $('#f-level-v').textContent = e.target.value;
    const blade = $('#fan-blade'); if (!blade) return;
    const lv = parseFloat(e.target.value);
    if (isNaN(lv) || lv <= 0) blade.classList.add('still');
    else { blade.classList.remove('still'); blade.style.animationDuration = (2.6 - (Math.min(lv, 15) / 15) * 2.1).toFixed(2) + 's'; }
  };
  /* 手动模式下拖动挡位即时生效（150ms 防抖，松手立即落地），不再需要点「应用」 */
  let fanTimer = null;
  const fanLive = () => {
    if ($('#f-mode').value !== 'manual') return;
    fanTouch = Date.now();
    hw('set_fan', { mode: 'manual', level: +$('#f-level').value, persist: false }, true)
      .catch(() => {});
  };
  const scheduleFan = () => {
    clearTimeout(fanTimer);
    if ($('#f-mode').value === 'manual') fanTimer = setTimeout(fanLive, 150);
  };
  $('#f-level').oninput = (e) => { syncLevel(e); fanTouch = Date.now(); scheduleFan(); };
  $('#f-level').onchange = () => {            // 松手：立刻应用，避免拖完还差一拍
    clearTimeout(fanTimer);
    if ($('#f-mode').value === 'manual') { fanTouch = Date.now(); fanLive(); }
  };
  $('#f-mode').onchange = () => {             // 切到手动：立即按当前挡位生效
    applyFanMode();
    if ($('#f-mode').value === 'manual') { clearTimeout(fanTimer); fanTouch = Date.now(); fanLive(); }
  };
  $('#b-ms').oninput = (e) => ($('#b-ms-v').textContent = e.target.value);

  $('#p-ovr-apply').onclick = () => hw('set_led_override', { power: $('#p-ovr').value }).then(refresh);
  $('#d-ovr-apply').onclick = () => hw('set_led_override', { sata: $('#d-ovr').value }).then(refresh);

  $('#f-apply').onclick = () => hw('set_fan', fanPayload(true));
  $('#f-temp').onclick = () => hw('set_fan', fanPayload(false));

  $('#b-test').onclick = () => hw('beep_test', { ms: +$('#b-ms').value });
  $('#b-save').onclick = () => hw('set_beep', { ms: +$('#b-ms').value, boot_beep: true });

  $('#sch-apply').onclick = async () => {
    await hw('set_power_schedule', {
      enabled: $('#sch-enable').checked ? 1 : 0,
      shutdown_time: $('#sch-shutdown').value,
      boot_time: $('#sch-boot').value,
    });
    refresh();
  };

  $('#port-save').onclick = async () => {
    const p = +$('#port-v').value;
    if (!p || p < 1 || p > 65535) return toast('端口不合法', false);
    const r = await api('/api/restart', { port: p });
    toast(r.msg || '正在重启', r.ok);
    setTimeout(() => { location.href = location.protocol + '//' + location.hostname + ':' + p + '/'; }, 6000);
  };

  // 版本与更新
  $('#up-check').onclick = () => checkUpdate(false);
  $('#up-upgrade').onclick = () => doUpgrade();

  // 拖放上传
  const drop = $('#drop');
  ['dragenter', 'dragover'].forEach((ev) => drop.addEventListener(ev, (e) => {
    e.preventDefault(); drop.classList.add('over');
  }));
  ['dragleave', 'drop'].forEach((ev) => drop.addEventListener(ev, (e) => {
    e.preventDefault(); drop.classList.remove('over');
  }));
  drop.addEventListener('drop', (e) => {
    const f = e.dataTransfer.files[0];
    if (f) upload(f);
  });
  $('#file').onchange = (e) => { if (e.target.files[0]) upload(e.target.files[0]); };
}

async function upload(file) {
  const text = await file.text();
  const r = await api('/api/script/save', { name: file.name, content: text });
  toast(r.msg || '上传完成', r.ok);
  if (r.ok && r.scripts) renderScripts(r.scripts);
}

async function checkUpdate(silent) {
  let r;
  try {
    r = await api('/api/autoupdate', { action: 'check' });
  } catch (e) {
    $('#up-latest').textContent = '检测失败';
    $('#up-tag').textContent = '未知';
    return;
  }
  const cur = r.current || '—';
  const latest = r.latest || '检测失败';
  $('#up-current').textContent = cur;
  $('#up-latest').textContent = latest;
  const tag = $('#up-tag');
  if (r.update_available) {
    tag.textContent = '有更新';
    tag.className = 'hd-tag warn';
    $('#up-upgrade').disabled = false;
    $('#up-hint').textContent = (r.result || '发现新版本，可点击「立即升级」。');
  } else {
    tag.textContent = (latest === '检测失败' || !r.latest) ? '未知' : '最新';
    tag.className = 'hd-tag';
    $('#up-upgrade').disabled = true;
    $('#up-hint').textContent = (r.result || '已是最新版本。');
  }
  if (!silent && r.result) toast(r.result, true);
}

async function doUpgrade() {
  $('#up-upgrade').disabled = true;
  let r;
  try {
    r = await api('/api/autoupdate', { action: 'upgrade' });
  } catch (e) {
    toast('升级请求失败', false);
    $('#up-upgrade').disabled = false;
    return;
  }
  toast(r.msg || '已开始升级', r.ok);
  if (r.ok) {
    $('#up-latest').textContent = '升级中…';
    const tag = $('#up-tag');
    tag.textContent = '升级中';
    tag.className = 'hd-tag warn';
    // 升级会重启控制台，数秒后页面会断开，提示用户等待刷新
    setTimeout(() => toast('升级完成将自动重启，请稍后刷新页面', true), 1500);
  } else {
    $('#up-upgrade').disabled = false;
  }
}

async function refresh() {
  try {
    const r = await api('/api/state');
    if (r.data) renderStatus(r.data);
    else toast(r.msg || '读取状态失败', false);
  } catch (e) {
    // 仅本地 file:// 预览时渲染演示数据，让界面离线也能看到完整质感
    if (location.protocol === 'file:' && !window.__demoRendered) {
      window.__demoRendered = true;
      renderStatus(DEMO_DATA);
    }
  }
}

/* 本地预览演示数据（仅 file:// 协议下使用） */
const DEMO_DATA = {
  cpu_temp: 56, hdd_max_temp: 43, fan_level: 7, fan_mode: 'auto', disks: 'sda=43',
  root: true, port: 18899, hostname: 'fnOS-S2',
  services: {
    'fan-control': 'active', 'power-led-net': 'active', 'sata-led-manager': 'active',
    'power-key-daemon': 'active', 's2-power-schedule': 'active',
    'random-mac': 'done', 'set-hostname': 'done', 'selfheal': 'done', 'boot-version-guard': 'done',
  },
  net_link: { deployed: true, up: true, iface: 'eth0' },
  conf: {
    led_override: { power: 'auto', sata: 'auto' },
    fan: { MODE: 'auto', FAN_UI_MODE: 'auto', MANUAL_LEVEL: 7, HDD_TEMP_OFF: 40, HDD_TEMP_LOW: 45, HDD_TEMP_MID: 55, HDD_TEMP_MAX: 60, TEMP_OFF: 50, TEMP_LOW: 60, TEMP_MID: 70, TEMP_CRITICAL: 80 },
    beep: { beep_ms: 280 },
    power_schedule: { enabled: '0', shutdown_time: '', boot_time: '', rtc_wake: 1 },
  },
  scripts: [
    { name: '00-部署全部硬件配置.sh', builtin: true },
    { name: '01-自检并修复.sh', builtin: true },
    { name: '02-重启硬件服务.sh', builtin: true },
  ],
};

function startClock() {
  const el = $('#b-clock');
  if (!el) return;
  const tick = () => {
    const d = new Date();
    const p = (n) => String(n).padStart(2, '0');
    el.textContent = p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  };
  tick();
  setInterval(tick, 1000);
}

bind();
initGlow();
initBg();
refresh();
startClock();
setInterval(refresh, 10000);
checkUpdate(true);   // 进入页面静默检测一次 GitHub 最新版本
