// Lyric HUD Bridge — service worker.
// Menerima state dari content script (Spotify Web / YT Music), memilih tab yang sedang
// dianggap aktif, lalu meneruskannya ke app Lyric HUD lewat WebSocket lokal.
// Perintah dari app (play/pause/next/previous) diteruskan balik ke tab aktif.

const APP_URL = "ws://127.0.0.1:38765";
const TOKEN = "lyrichud-dev-token"; // harus sama dengan BridgeServer.token di app Swift
const PING_MS = 20000;

let ws = null;
let pingTimer = null;
let activeTabId = null;
let changeSeq = 0; // penghitung urutan perubahan (lebih tegas daripada timestamp)

// tabId -> { state, key, changedAt }
const sources = new Map();

// ---------- koneksi ke app ----------

function connect() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;

  let socket;
  try {
    socket = new WebSocket(APP_URL);
  } catch (_) {
    return;
  }
  ws = socket;

  socket.onopen = () => {
    socket.send(JSON.stringify({ type: "hello", token: TOKEN }));
    if (activeTabId !== null) publish();
    clearInterval(pingTimer);
    // Traffic WebSocket juga menjaga service worker tetap hidup.
    pingTimer = setInterval(() => sendRaw({ type: "ping" }), PING_MS);
  };

  socket.onmessage = (event) => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch (_) {
      return;
    }
    if (message.type === "command" && activeTabId !== null) {
      chrome.tabs
        .sendMessage(activeTabId, { kind: "command", action: message.action })
        .catch(() => {});
    }
  };

  socket.onclose = () => {
    if (ws === socket) {
      ws = null;
      clearInterval(pingTimer);
    }
  };

  socket.onerror = () => {}; // app belum jalan; dicoba lagi saat ada pesan berikutnya
}

function sendRaw(object) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(object));
    return true;
  }
  return false;
}

// ---------- memilih sumber aktif ----------

function pickActive() {
  let bestId = null;
  let best = null;
  for (const [tabId, entry] of sources) {
    if (best === null) {
      bestId = tabId;
      best = entry;
      continue;
    }
    if (entry.state.playing !== best.state.playing) {
      if (entry.state.playing) {
        bestId = tabId;
        best = entry;
      }
      continue;
    }
    if (entry.changedAt > best.changedAt) {
      bestId = tabId;
      best = entry;
    }
  }
  return bestId;
}

function publish() {
  const entry = sources.get(activeTabId);
  if (!entry) return;
  sendRaw({ type: "state", ...entry.state });
}

function onState(tabId, state) {
  const key = `${state.title}\u0000${state.artist}`;
  const previous = sources.get(tabId);
  const changed = !previous || previous.state.playing !== state.playing || previous.key !== key;
  sources.set(tabId, {
    state,
    key,
    changedAt: changed ? ++changeSeq : previous.changedAt,
  });

  const before = activeTabId;
  activeTabId = pickActive();
  // Hanya teruskan kalau pesan ini dari tab aktif, atau tab aktifnya berganti.
  if (activeTabId === tabId || activeTabId !== before) publish();
}

function onGone(tabId) {
  if (!sources.delete(tabId)) return;
  const before = activeTabId;
  activeTabId = pickActive();
  if (activeTabId === null) {
    sendRaw({ type: "idle" });
  } else if (activeTabId !== before) {
    publish();
  }
}

// ---------- pemicu ----------

chrome.runtime.onMessage.addListener((message, sender) => {
  connect(); // setiap pesan dari content script sekaligus memastikan koneksi hidup
  const tabId = sender.tab && sender.tab.id;
  if (tabId === undefined || !message) return;

  if (message.kind === "state" && message.state) onState(tabId, message.state);
  else if (message.kind === "idle") onGone(tabId);
});

chrome.tabs.onRemoved.addListener(onGone);
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);

connect();
