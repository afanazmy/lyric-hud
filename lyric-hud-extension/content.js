// Lyric HUD Bridge — content script.
// Berjalan di open.spotify.com dan music.youtube.com. Tugasnya hanya membaca state
// pemutar dan menjalankan perintah; lirik dan sinkronisasi ditangani app di Mac.
(() => {
  "use strict";

  const HOST = location.hostname;
  const SOURCE =
    HOST === "open.spotify.com" ? "spotify" :
    HOST === "music.youtube.com" ? "ytmusic" : null;
  if (!SOURCE) return;

  const POLL_MS = 500;          // seberapa sering state diperiksa
  const HEARTBEAT_MS = 5000;    // kirim ulang state walau tidak berubah (resync + jaga koneksi)
  const SEEK_THRESHOLD = 1.5;   // lompatan posisi (detik) yang dianggap seek

  // Selector kontrol. Kalau Spotify / YT Music mengubah DOM-nya, cukup perbaiki di sini.
  const CONTROLS = {
    spotify: {
      togglePlay: ['[data-testid="control-button-playpause"]'],
      next: ['[data-testid="control-button-skip-forward"]'],
      previous: ['[data-testid="control-button-skip-back"]'],
    },
    ytmusic: {
      togglePlay: ["ytmusic-player-bar .play-pause-button", ".play-pause-button.ytmusic-player-bar"],
      next: ["ytmusic-player-bar .next-button", ".next-button.ytmusic-player-bar"],
      previous: ["ytmusic-player-bar .previous-button", ".previous-button.ytmusic-player-bar"],
    },
  };

  const $ = (selector) => document.querySelector(selector);
  const textOf = (selector) => ($(selector)?.textContent || "").trim();

  // "1:23" atau "1:02:03" → detik
  function parseClock(str) {
    if (!str) return null;
    const parts = str.replace("-", "").trim().split(":").map(Number);
    if (!parts.length || parts.some(Number.isNaN)) return null;
    return parts.reduce((total, n) => total * 60 + n, 0);
  }

  // ---------- membaca state ----------

  function readMetadata() {
    const md = navigator.mediaSession && navigator.mediaSession.metadata;
    let title = (md && md.title) || "";
    let artist = (md && md.artist) || "";
    const album = (md && md.album) || "";

    // Cadangan kalau MediaSession belum terisi.
    if (SOURCE === "spotify") {
      title = title || textOf('[data-testid="context-item-info-title"]') || textOf('[data-testid="context-item-link"]');
      artist = artist || textOf('[data-testid="context-item-info-subtitles"]');
    } else {
      title = title || textOf("ytmusic-player-bar .title");
      artist = artist || textOf("ytmusic-player-bar .byline").split("•")[0].trim();
    }
    return { title, artist, album };
  }

  function findVideo() {
    const videos = Array.from(document.querySelectorAll("video"));
    return videos.find((v) => Number.isFinite(v.duration) && v.duration > 0) || videos[0] || null;
  }

  function spotifyPlaying() {
    const state = navigator.mediaSession && navigator.mediaSession.playbackState;
    if (state === "playing") return true;
    if (state === "paused") return false;
    // Cadangan: label tombol play/pause ("Pause" / "Jeda" saat sedang memutar).
    const label = ($('[data-testid="control-button-playpause"]')?.getAttribute("aria-label") || "").toLowerCase();
    return /pause|jeda/.test(label);
  }

  function readPlayback() {
    if (SOURCE === "ytmusic") {
      const video = findVideo();
      if (!video) return null;
      return {
        position: video.currentTime,
        duration: Number.isFinite(video.duration) ? video.duration : null,
        playing: !video.paused && !video.ended,
      };
    }
    // Spotify Web: posisi dibaca dari teks di progress bar (akurat per detik).
    const position = parseClock(textOf('[data-testid="playback-position"]'));
    if (position === null) return null;
    return {
      position,
      duration: parseClock(textOf('[data-testid="playback-duration"]')),
      playing: spotifyPlaying(),
    };
  }

  // ---------- mengirim ke service worker ----------

  let stopped = false;

  function send(message) {
    if (stopped) return;
    if (!chrome.runtime || !chrome.runtime.id) {
      // Extension di-reload: content script lama ini sudah tidak berguna.
      stopped = true;
      clearInterval(pollTimer);
      return;
    }
    try {
      const result = chrome.runtime.sendMessage(message);
      if (result && result.catch) result.catch(() => {});
    } catch (_) {
      /* context invalidated */
    }
  }

  const last = { key: "", playing: null, position: 0, at: 0, sentAt: 0 };

  function check(force = false) {
    const meta = readMetadata();
    const playback = readPlayback();
    const now = Date.now();

    if (!meta.title || !playback) {
      if (last.key !== "") {
        last.key = "";
        last.playing = null;
        send({ kind: "idle" });
      }
      return;
    }

    const key = `${meta.title}\u0000${meta.artist}`;
    const expected = last.playing ? last.position + (now - last.at) / 1000 : last.position;
    const jumped = Math.abs(playback.position - expected) > SEEK_THRESHOLD;
    const changed = key !== last.key || playback.playing !== last.playing || jumped;
    const heartbeat = now - last.sentAt >= HEARTBEAT_MS;

    last.key = key;
    last.playing = playback.playing;
    last.position = playback.position;
    last.at = now;

    if (force || changed || heartbeat) {
      last.sentAt = now;
      send({ kind: "state", state: { source: SOURCE, ...meta, ...playback } });
    }
  }

  // ---------- perintah dari app ----------

  function runCommand(action) {
    const selectors = (CONTROLS[SOURCE] && CONTROLS[SOURCE][action]) || [];
    for (const selector of selectors) {
      const el = $(selector);
      if (el) {
        el.click();
        return true;
      }
    }
    if (SOURCE === "ytmusic" && action === "togglePlay") {
      const video = findVideo();
      if (video) {
        if (video.paused) video.play(); else video.pause();
        return true;
      }
    }
    console.warn("[LyricHUD] tombol kontrol tidak ditemukan:", action);
    return false;
  }

  chrome.runtime.onMessage.addListener((message) => {
    if (!message || message.kind !== "command") return;
    runCommand(message.action);
    // Laporkan hasilnya secepat mungkin supaya HUD ikut berubah.
    setTimeout(() => check(true), 150);
    setTimeout(() => check(true), 700);
  });

  // ---------- pemicu ----------

  // Event media tidak ikut di-throttle saat tab di background, jadi perubahan terdeteksi cepat.
  for (const eventName of ["play", "playing", "pause", "seeked", "ended", "loadedmetadata"]) {
    document.addEventListener(eventName, () => setTimeout(check, 120), true);
  }
  window.addEventListener("pagehide", () => send({ kind: "idle" }));

  const pollTimer = setInterval(check, POLL_MS);
  check(true);
})();
