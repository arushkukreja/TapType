import { process as cleanUp, stripArtifacts } from "./cleanup.js";
import {
  CLOUD, ProviderError, browserSpeechSupported, browserSpeechOnDevice, recordingSupported,
  startBrowserSpeech, startRecording, cloudTranscribe, cloudEditor, testCloudKey,
  browserAIStatus, browserAIEditor,
} from "./providers.js";

const $ = (id) => document.getElementById(id);
const lang = navigator.language || "en-US";

// Storage can be blocked (private windows, strict settings); the app still works without it.
const store = {
  get(key, fallback) { try { const v = localStorage.getItem("taptype." + key); return v === null ? fallback : JSON.parse(v); } catch { return fallback; } },
  set(key, value) { try { localStorage.setItem("taptype." + key, JSON.stringify(value)); } catch { /* ignore */ } },
  remove(key) { try { localStorage.removeItem("taptype." + key); } catch { /* ignore */ } },
};

const settings = {
  speech: store.get("speech", browserSpeechSupported ? "browser" : "openai"),
  mode: store.get("mode", "cleanup"),
  writing: store.get("writing", "rules"),
  autocopy: store.get("autocopy", true),
};
const cloud = Object.fromEntries(Object.entries(CLOUD).map(([id, c]) => [id, {
  key: store.get(`${id}.key`, ""),
  speechModel: store.get(`${id}.speechModel`, c.speechModel),
  writingModel: store.get(`${id}.writingModel`, c.writingModel),
}]));
let history = store.get("history", []);

// ---------- Dictation ----------

let session = null;   // active recorder/recognizer
let state = "idle";   // idle | recording | working
let startedAt = 0, timer = 0, lastOriginal = "", showingOriginal = false, lastFinal = "";
const card = document.querySelector(".dictate");

function setState(next) {
  state = next;
  card.classList.toggle("recording", next === "recording");
  card.classList.toggle("working", next === "working");
  $("cancel").hidden = next !== "recording";
  $("record").setAttribute("aria-label", next === "recording" ? "Finish dictation" : next === "working" ? "Working" : "Start dictation");
  $("record").disabled = next === "working";
  document.querySelectorAll("#speech, #writing, .segmented button").forEach((el) => { el.disabled = next !== "idle"; });
}

function status(title, detail = "", error = false) {
  $("status").textContent = title;
  $("status").classList.toggle("error", error);
  $("detail").textContent = detail;
}

const elapsed = () => {
  const s = Math.floor((Date.now() - startedAt) / 1000);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
};

async function start() {
  if (state !== "idle") return;
  $("result-wrap").hidden = true;
  $("live").hidden = true;
  const where = settings.speech === "browser" ? "" : ` · ${CLOUD[settings.speech].title}`;
  try {
    if (settings.speech === "browser") {
      session = await startBrowserSpeech({
        lang,
        onText: (finals, interim) => renderLive(finals, interim),
        onError: (error) => fail(error),
      });
    } else {
      if (!cloud[settings.speech].key) throw new ProviderError(`Add your ${CLOUD[settings.speech].title} API key in Cloud providers.`);
      session = await startRecording();
    }
  } catch (error) { session = null; return fail(error); }
  startedAt = Date.now();
  setState("recording");
  const tick = () => status("Listening…", `${elapsed()}${where}${session?.onDevice ? " · on this device" : ""}`);
  tick(); timer = setInterval(tick, 500);
  if (settings.speech === "browser") renderLive("", "");
}

function renderLive(finals, interim) {
  const live = $("live");
  live.hidden = false;
  finals = stripArtifacts(finals); interim = stripArtifacts(interim);
  live.replaceChildren(document.createTextNode(finals ? finals + " " : ""));
  const span = document.createElement("span");
  span.className = "interim";
  span.textContent = interim || (finals ? "" : "Start speaking…");
  live.append(span);
}

async function finish() {
  if (state !== "recording" || !session) return;
  clearInterval(timer);
  const active = session; session = null;
  setState("working");
  try {
    let raw;
    if (settings.speech === "browser") {
      status("Finishing…");
      raw = await active.stop();
    } else {
      status("Transcribing…", CLOUD[settings.speech].title);
      const blob = await active.stop();
      if (blob.size < 1000) throw new ProviderError("No audio was recorded. Check your microphone and try again.");
      const c = cloud[settings.speech];
      raw = await cloudTranscribe(settings.speech, c.key, c.speechModel, blob);
    }
    if (!stripArtifacts(raw)) throw new ProviderError("No speech was heard. Try again a little closer to the microphone.");
    if (settings.mode !== "original") status(settings.mode === "rewrite" ? "Rewriting…" : "Cleaning up…", writerLabel());
    const result = await cleanUp(raw, settings.mode, await editor());
    showResult(stripArtifacts(raw), result);
  } catch (error) {
    fail(error);
  }
}

function cancel() {
  if (state !== "recording" || !session) return;
  clearInterval(timer);
  session.cancel(); session = null;
  $("live").hidden = true;
  setState("idle");
  status("Cancelled", "Nothing was kept.");
}

function fail(error) {
  clearInterval(timer);
  if (session) { try { session.cancel(); } catch { /* ignore */ } session = null; }
  setState("idle");
  $("live").hidden = true;
  status("Couldn’t dictate", error instanceof ProviderError ? error.message : "Something went wrong. Please try again.", true);
  if (!(error instanceof ProviderError)) console.error(error);
}

async function showResult(original, { text, notice }) {
  setState("idle");
  $("live").hidden = true;
  lastOriginal = original; lastFinal = text; showingOriginal = false;
  $("result").value = text;
  $("result-wrap").hidden = false;
  $("notice").hidden = !notice;
  $("notice").textContent = notice || "";
  $("show-original").hidden = text === original;
  $("show-original").textContent = "Show original";
  const words = countWords(text);
  addHistory(original, words);
  let copied = false;
  if (settings.autocopy) copied = await copy(text, true);
  status("Done", `${words} ${words === 1 ? "word" : "words"}${copied ? " · copied" : ""}`);
}

const countWords = (text) => (text.match(/[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu) || []).length;

async function copy(text, quiet = false) {
  try {
    await navigator.clipboard.writeText(text);
    const button = $("copy");
    button.textContent = "Copied"; button.classList.add("done");
    setTimeout(() => { button.textContent = "Copy"; button.classList.remove("done"); }, 1500);
    return true;
  } catch {
    if (!quiet) { $("result").select(); status("Select and copy", "Your browser blocked clipboard access."); }
    return false;
  }
}

// ---------- Writing providers ----------

let builtIn = null;
async function editor() {
  if (settings.mode === "original") return null;
  switch (settings.writing) {
    case "browser":
      if (!["available", "downloadable", "downloading"].includes(await browserAIStatus())) {
        throw new ProviderError("Browser AI isn’t available in this browser. Pick another writing option.");
      }
      builtIn ||= browserAIEditor((loaded) => status("Downloading browser AI…", `${Math.round(loaded * 100)}%`));
      return builtIn;
    case "openai": case "groq": {
      const c = cloud[settings.writing];
      if (!c.key) throw new ProviderError(`Add your ${CLOUD[settings.writing].title} API key in Cloud providers.`);
      return cloudEditor(settings.writing, c.key, c.writingModel);
    }
    default: return null;
  }
}

const writerLabel = () => ({ rules: "Rules", browser: "Browser AI · on this device", openai: "OpenAI", groq: "Groq" })[settings.writing];

async function updateProviderNote() {
  const notes = [];
  if (settings.speech === "browser") {
    if (!browserSpeechSupported) notes.push("This browser can’t recognize speech. Use Chrome, Edge or Safari, or pick OpenAI or Groq.");
    else if (await browserSpeechOnDevice(lang)) notes.push("Browser speech runs on this device.");
    else notes.push("Browser speech may send audio to your browser maker’s speech service (Google for Chrome, Apple for Safari).");
  } else {
    if (!recordingSupported) notes.push("This browser can’t record audio.");
    notes.push(`Audio is sent to ${CLOUD[settings.speech].title} when you tap ✓.`);
  }
  if (settings.mode !== "original") {
    if (settings.writing === "rules") notes.push("Rules remove um, uh and repeated words without changing anything else.");
    if (settings.writing === "browser") {
      const s = await browserAIStatus();
      notes.push(s === "available" ? "Browser AI runs on this device."
        : s === "downloadable" || s === "downloading" ? "Browser AI will download a model the first time you use it."
          : "Browser AI isn’t available here (it needs a recent desktop Chrome). Pick another writing option.");
    }
    if (settings.writing === "openai" || settings.writing === "groq") notes.push(`Text is sent to ${CLOUD[settings.writing].title} for ${settings.mode === "rewrite" ? "rewriting" : "cleanup"}.`);
  }
  $("provider-note").textContent = notes.join(" ");
}

// ---------- History ----------

function addHistory(original, words) {
  history.unshift({ id: crypto.randomUUID?.() || String(Date.now()), at: Date.now(), text: original, words });
  history = history.slice(0, 200);
  store.set("history", history);
  store.set("totalWords", store.get("totalWords", 0) + words);
  store.set("totalCount", store.get("totalCount", 0) + 1);
  renderHistory();
}

function renderHistory() {
  $("stat-words").textContent = store.get("totalWords", 0).toLocaleString();
  $("stat-count").textContent = store.get("totalCount", 0).toLocaleString();
  const list = $("history");
  list.replaceChildren(...history.map((item) => {
    const li = document.createElement("li");
    const time = document.createElement("time");
    time.dateTime = new Date(item.at).toISOString();
    time.textContent = new Date(item.at).toLocaleString([], { dateStyle: "medium", timeStyle: "short" });
    const p = document.createElement("p"); p.textContent = item.text;
    const b = document.createElement("button"); b.textContent = "Copy";
    b.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(item.text); b.textContent = "Copied"; } catch { b.textContent = "Couldn’t copy"; }
      setTimeout(() => { b.textContent = "Copy"; }, 1500);
    });
    li.append(time, p, b);
    return li;
  }));
  $("history-empty").hidden = history.length > 0;
  $("clear-history").hidden = history.length === 0;
}

// ---------- Wiring ----------

$("record").addEventListener("click", () => (state === "recording" ? finish() : start()));
$("cancel").addEventListener("click", cancel);
$("copy").addEventListener("click", () => copy($("result").value));
$("result").addEventListener("input", () => { if (!showingOriginal) lastFinal = $("result").value; });
$("show-original").addEventListener("click", () => {
  showingOriginal = !showingOriginal;
  $("result").value = showingOriginal ? lastOriginal : lastFinal;
  $("show-original").textContent = showingOriginal ? "Show edited" : "Show original";
});

document.addEventListener("keydown", (event) => {
  const typing = event.target.closest?.("input, textarea, select, [contenteditable]");
  if (event.key === "Escape" && state === "recording") { event.preventDefault(); cancel(); }
  else if (event.code === "Space" && !typing && !event.repeat && !event.target.closest?.("button, summary")) {
    event.preventDefault();
    if (state === "recording") finish(); else if (state === "idle") start();
  }
});

const speechSelect = $("speech"), writingSelect = $("writing");
speechSelect.value = settings.speech;
writingSelect.value = settings.writing;
speechSelect.addEventListener("change", () => { settings.speech = speechSelect.value; store.set("speech", settings.speech); updateProviderNote(); });
writingSelect.addEventListener("change", () => { settings.writing = writingSelect.value; store.set("writing", settings.writing); updateProviderNote(); });

function renderMode() {
  document.querySelectorAll(".segmented button").forEach((b) => b.setAttribute("aria-checked", String(b.dataset.mode === settings.mode)));
  writingSelect.closest(".row").style.opacity = settings.mode === "original" ? 0.45 : 1;
}
document.querySelectorAll(".segmented button").forEach((b) => b.addEventListener("click", () => {
  settings.mode = b.dataset.mode; store.set("mode", settings.mode); renderMode(); updateProviderNote();
}));

$("autocopy").checked = settings.autocopy;
$("autocopy").addEventListener("change", () => { settings.autocopy = $("autocopy").checked; store.set("autocopy", settings.autocopy); });

document.querySelectorAll("fieldset[data-provider]").forEach((fs) => {
  const id = fs.dataset.provider;
  const statusEl = fs.querySelector("[data-status]");
  fs.querySelectorAll("input[data-field]").forEach((input) => {
    const field = input.dataset.field;
    input.value = cloud[id][field];
    input.addEventListener("change", () => {
      const value = input.value.trim() || (field === "key" ? "" : CLOUD[id][field]);
      if (field === "key" && /\s/.test(value)) { statusEl.textContent = "Enter a key without spaces."; statusEl.className = "small bad"; return; }
      input.value = value; cloud[id][field] = value;
      value ? store.set(`${id}.${field}`, value) : store.remove(`${id}.${field}`);
      statusEl.textContent = field === "key" ? (value ? "Saved in this browser" : "") : "";
      statusEl.className = "muted small";
    });
  });
  fs.querySelector('[data-action="test"]').addEventListener("click", async () => {
    statusEl.textContent = "Testing…"; statusEl.className = "muted small";
    try {
      const n = await testCloudKey(id, cloud[id].key);
      statusEl.textContent = `Works · ${n} models available`; statusEl.className = "small ok";
    } catch (error) {
      statusEl.textContent = error.message; statusEl.className = "small bad";
    }
  });
  fs.querySelector('[data-action="remove"]').addEventListener("click", () => {
    cloud[id].key = ""; store.remove(`${id}.key`);
    fs.querySelector('[data-field="key"]').value = "";
    statusEl.textContent = "Key removed"; statusEl.className = "muted small";
  });
});

$("clear-history").addEventListener("click", () => {
  if (!confirm("Delete all transcripts and reset stats? This can’t be undone.")) return;
  history = []; store.remove("history"); store.remove("totalWords"); store.remove("totalCount");
  renderHistory();
});

window.addEventListener("beforeunload", (event) => { if (state === "recording") event.preventDefault(); });

renderMode();
renderHistory();
updateProviderNote();
setState("idle");
