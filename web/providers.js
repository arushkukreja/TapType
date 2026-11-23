// Speech and writing providers for the web app. Each mirrors an iOS provider:
// browser speech ≈ Apple Speech, browser AI ≈ Apple Foundation Models, and the same
// OpenAI / Groq endpoints the iOS app calls with the user's own key.

import { instructions } from "./cleanup.js";

export const CLOUD = {
  openai: { title: "OpenAI", base: "https://api.openai.com/v1/", speechModel: "gpt-transcribe", writingModel: "gpt-6-luna" },
  groq: { title: "Groq", base: "https://api.groq.com/openai/v1/", speechModel: "whisper-large-v3-turbo", writingModel: "llama-3.3-70b-versatile" },
};

export class ProviderError extends Error {}

const SpeechRecognitionClass = globalThis.SpeechRecognition || globalThis.webkitSpeechRecognition;
export const browserSpeechSupported = Boolean(SpeechRecognitionClass);
export const recordingSupported = Boolean(navigator.mediaDevices?.getUserMedia && globalThis.MediaRecorder);

/** Whether the browser can recognize speech without sending audio to a server. */
export async function browserSpeechOnDevice(lang) {
  try {
    if (!SpeechRecognitionClass?.available) return false;
    return (await SpeechRecognitionClass.available({ langs: [lang], processLocally: true })) === "available";
  } catch { return false; }
}

/** Live recognition in the browser. Calls onText(finalText, interimText) as words arrive. */
export async function startBrowserSpeech({ lang, onText, onError }) {
  if (!SpeechRecognitionClass) throw new ProviderError("This browser can’t recognize speech. Try Chrome, Edge or Safari, or pick a cloud provider.");
  const onDevice = await browserSpeechOnDevice(lang);
  let finals = "", interim = "", active = true, resolveStop = null, recognition = null;

  const begin = () => {
    recognition = new SpeechRecognitionClass();
    recognition.lang = lang;
    recognition.continuous = true;
    recognition.interimResults = true;
    if (onDevice && "processLocally" in recognition) recognition.processLocally = true;
    recognition.onresult = (event) => {
      interim = "";
      for (let i = event.resultIndex; i < event.results.length; i++) {
        const piece = event.results[i][0].transcript;
        if (event.results[i].isFinal) finals = join(finals, piece); else interim = join(interim, piece);
      }
      onText(finals, interim);
    };
    recognition.onerror = (event) => {
      if (event.error === "no-speech" || event.error === "aborted") return;
      active = false;
      const message = event.error === "not-allowed" || event.error === "service-not-allowed"
        ? "Microphone access was blocked. Allow it in your browser’s site settings and try again."
        : event.error === "network"
          ? "The browser’s speech service couldn’t be reached. Check your connection or pick a cloud provider."
          : "Speech recognition stopped unexpectedly. Please try again.";
      onError(new ProviderError(message));
    };
    // Browsers end recognition after a pause; keep listening until the user taps ✓.
    recognition.onend = () => {
      if (active) { try { begin(); } catch { /* ignore */ } return; }
      resolveStop?.(join(finals, interim));
    };
    recognition.start();
  };
  begin();

  return {
    onDevice,
    stop: () => new Promise((resolve) => {
      active = false; resolveStop = resolve;
      recognition.stop();
      // Some browsers never fire `end` if nothing was heard.
      setTimeout(() => resolve(join(finals, interim)), 1500);
    }),
    cancel: () => { active = false; recognition.abort(); },
  };
}

const join = (a, b) => [a.trim(), b.trim()].filter(Boolean).join(" ");

/** Records audio for a cloud provider. stop() resolves with the recorded Blob. */
export async function startRecording() {
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
  } catch {
    throw new ProviderError("Microphone access was blocked. Allow it in your browser’s site settings and try again.");
  }
  const mimeType = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg"].find((t) => MediaRecorder.isTypeSupported(t)) || "";
  const recorder = new MediaRecorder(stream, mimeType ? { mimeType } : undefined);
  const chunks = [];
  recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data);
  recorder.start(250);
  const release = () => stream.getTracks().forEach((t) => t.stop());
  return {
    onDevice: false,
    stop: () => new Promise((resolve) => {
      recorder.onstop = () => { release(); resolve(new Blob(chunks, { type: recorder.mimeType || "audio/webm" })); };
      recorder.stop();
    }),
    cancel: () => { recorder.onstop = release; recorder.stop(); },
  };
}

async function send(provider, key, path, init) {
  if (!key) throw new ProviderError(`Add your ${CLOUD[provider].title} API key in Cloud providers.`);
  const { title, base } = CLOUD[provider];
  let response;
  try {
    response = await fetch(base + path, {
      ...init, redirect: "error", cache: "no-store", credentials: "omit",
      headers: { Authorization: `Bearer ${key}`, Accept: "application/json", ...(init.headers || {}) },
      signal: AbortSignal.timeout(30000),
    });
  } catch {
    throw new ProviderError(`Couldn’t connect to ${title}. Check your internet connection and try again.`);
  }
  if (!response.ok) {
    const s = response.status;
    throw new ProviderError(
      s === 401 || s === 403 ? `Check your ${title} API key and its permissions.`
        : s === 404 ? "This model isn’t available. Check its name in Cloud providers."
          : s === 429 ? `${title}’s usage limit was reached. Check your quota or try later.`
            : [400, 413, 422].includes(s) ? `${title} couldn’t process this request. Check the model or try a shorter dictation.`
              : `${title} is unavailable right now. Please try again.`);
  }
  return response.json();
}

export async function cloudTranscribe(provider, key, model, blob) {
  const ext = blob.type.includes("mp4") ? "m4a" : blob.type.includes("ogg") ? "ogg" : "webm";
  const form = new FormData();
  form.append("model", model);
  form.append("response_format", "json");
  form.append("file", blob, `dictation.${ext}`);
  const result = await send(provider, key, "audio/transcriptions", { method: "POST", body: form });
  if (!result?.text?.trim()) throw new ProviderError("No speech was returned. Try speaking a little closer to your microphone.");
  return result.text;
}

export async function testCloudKey(provider, key) {
  const result = await send(provider, key, "models", { method: "GET" });
  return result?.data?.length ?? 0;
}

/** Returns an edit function for cleanup.process, or null for rules only. */
export function cloudEditor(provider, key, model) {
  return async (source, mode) => {
    const body = {
      model, max_completion_tokens: 1500,
      messages: [{ role: "system", content: instructions(mode) }, { role: "user", content: source }],
    };
    if (provider === "openai" && model === "gpt-6-luna") body.reasoning_effort = "none";
    const result = await send(provider, key, "chat/completions", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
    return result?.choices?.[0]?.message?.content ?? "";
  };
}

// Chrome's built-in Prompt API runs a small model on the device, like Apple Foundation Models.
const BuiltInModel = globalThis.LanguageModel;

export async function browserAIStatus() {
  if (!BuiltInModel?.availability) return "unsupported";
  try { return await BuiltInModel.availability({ expectedInputs: [{ type: "text", languages: ["en"] }], expectedOutputs: [{ type: "text", languages: ["en"] }] }); }
  catch { return "unavailable"; }
}

export function browserAIEditor(onProgress) {
  const sessions = {};
  return async (source, mode) => {
    sessions[mode] ||= BuiltInModel.create({
      initialPrompts: [{ role: "system", content: instructions(mode) }],
      expectedOutputs: [{ type: "text", languages: ["en"] }],
      monitor: (m) => m.addEventListener("downloadprogress", (e) => onProgress?.(e.loaded)),
    });
    const base = await sessions[mode];
    const session = await base.clone(); // each dictation starts fresh
    try { return await session.prompt(`Input: ${source}\nOutput:`); }
    finally { session.destroy(); }
  };
}
