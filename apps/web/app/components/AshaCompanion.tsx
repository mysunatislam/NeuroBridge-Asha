"use client";

import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { sendAshaChat, type AshaCitation } from "../lib/api";
import { offlineCompanionReply } from "../lib/asha-companion";

type CompanionMessage = {
  id: string;
  role: "asha" | "patient";
  text: string;
  mode?: string;
  citations?: AshaCitation[];
};

type SpeechRecognitionResultEvent = Event & {
  results: { 0?: { 0?: { transcript?: string } } };
};

type SpeechRecognitionLike = {
  lang: string;
  continuous: boolean;
  interimResults: boolean;
  start(): void;
  stop(): void;
  abort(): void;
  onresult: ((event: SpeechRecognitionResultEvent) => void) | null;
  onerror: (() => void) | null;
  onend: (() => void) | null;
};

type SpeechRecognitionConstructor = new () => SpeechRecognitionLike;

type VoiceWindow = Window & typeof globalThis & {
  SpeechRecognition?: SpeechRecognitionConstructor;
  webkitSpeechRecognition?: SpeechRecognitionConstructor;
};

type Props = {
  aiAvailable: boolean;
  patientContext: Record<string, unknown>;
  caregiverConfigured: boolean;
  onSpeak(text: string): void;
  onWriteDisplay(text: string): boolean;
  onCallCaregiver(): string;
  onConfirmEmergency(): string;
};

function messageId(): string {
  return typeof crypto.randomUUID === "function" ? crypto.randomUUID() : `message-${Date.now()}-${Math.random()}`;
}

function safeCitationUrl(value: string | undefined): string | null {
  if (!value) return null;
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

export function AshaCompanion({
  aiAvailable,
  patientContext,
  caregiverConfigured,
  onSpeak,
  onWriteDisplay,
  onCallCaregiver,
  onConfirmEmergency,
}: Props) {
  const [messages, setMessages] = useState<CompanionMessage[]>([{
    id: "asha-welcome",
    role: "asha",
    text: "I’m right here with you. We can talk, write on your display, or contact your caregiver whenever you choose.",
    mode: "local welcome",
  }]);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [actionMessage, setActionMessage] = useState("Your choices stay in your control.");
  const [confirmingHelp, setConfirmingHelp] = useState(false);
  const [voiceInputAvailable, setVoiceInputAvailable] = useState(false);
  const [listening, setListening] = useState(false);
  const recognitionRef = useRef<SpeechRecognitionLike | null>(null);
  const requestRef = useRef<AbortController | null>(null);

  const latestAshaMessage = useMemo(
    () => [...messages].reverse().find((message) => message.role === "asha")?.text ?? "Asha is ready.",
    [messages],
  );

  useEffect(() => {
    const voiceWindow = window as VoiceWindow;
    const detectionTimer = window.setTimeout(() => {
      setVoiceInputAvailable(Boolean(voiceWindow.SpeechRecognition ?? voiceWindow.webkitSpeechRecognition));
    }, 0);
    return () => {
      window.clearTimeout(detectionTimer);
      recognitionRef.current?.abort();
      requestRef.current?.abort();
    };
  }, []);

  async function submitMessage(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    const message = draft.trim();
    if (!message || busy) return;
    setMessages((current) => [...current, { id: messageId(), role: "patient", text: message }]);
    setDraft("");
    setBusy(true);
    setActionMessage("Asha is thinking…");
    const controller = new AbortController();
    requestRef.current?.abort();
    requestRef.current = controller;
    try {
      const recentSummary = messages
        .slice(-4)
        .map((item) => `${item.role === "asha" ? "Asha" : "Patient"}: ${item.text}`)
        .join(" | ")
        .slice(0, 500);
      const response = await sendAshaChat({
        message,
        locale: navigator.language || "en-US",
        patient_context: { ...patientContext, ...(recentSummary ? { recent_summary: recentSummary } : {}) },
      }, controller.signal);
      setMessages((current) => [...current, {
        id: messageId(),
        role: "asha",
        text: response.reply,
        mode: response.mode,
        citations: response.citations,
      }]);
      setActionMessage(response.urgent ? "Asha noticed that this may be urgent. Please confirm before an alert is sent." : "Asha replied. You can play it aloud or write it on the Pi display.");
      if (response.urgent) setConfirmingHelp(true);
    } catch {
      if (controller.signal.aborted) return;
      const fallback = offlineCompanionReply(message);
      setMessages((current) => [...current, {
        id: messageId(),
        role: "asha",
        text: fallback.reply,
        mode: "offline companion",
      }]);
      setActionMessage("Online Asha is unavailable. Local communication controls remain ready.");
      if (fallback.urgent) setConfirmingHelp(true);
    } finally {
      if (requestRef.current === controller) requestRef.current = null;
      setBusy(false);
    }
  }

  function toggleVoiceInput(): void {
    if (listening) {
      recognitionRef.current?.stop();
      return;
    }
    const voiceWindow = window as VoiceWindow;
    const Recognition = voiceWindow.SpeechRecognition ?? voiceWindow.webkitSpeechRecognition;
    if (!Recognition) {
      setActionMessage("Voice input is unavailable in this browser. Type your message instead.");
      return;
    }
    const recognition = new Recognition();
    recognition.lang = navigator.language || "en-US";
    recognition.continuous = false;
    recognition.interimResults = false;
    recognition.onresult = (event) => {
      const transcript = event.results[0]?.[0]?.transcript?.trim();
      if (transcript) setDraft((current) => current ? `${current} ${transcript}` : transcript);
    };
    recognition.onerror = () => setActionMessage("Voice input could not be captured. You can keep typing your message.");
    recognition.onend = () => {
      setListening(false);
      recognitionRef.current = null;
    };
    recognitionRef.current = recognition;
    setListening(true);
    setActionMessage("Listening… your browser may use its own speech service to create text.");
    try {
      recognition.start();
    } catch {
      setListening(false);
      recognitionRef.current = null;
      setActionMessage("Voice input could not start. You can keep typing your message.");
    }
  }

  function writeDisplay(): void {
    const caption = draft.trim() || latestAshaMessage;
    const delivered = onWriteDisplay(caption);
    setActionMessage(delivered
      ? "Caption sent to the connected Pi display."
      : "Caption is visible in the local Pi Display preview, but no Pi is connected.");
  }

  function callCaregiver(): void {
    setActionMessage(onCallCaregiver());
  }

  function confirmEmergency(): void {
    const result = onConfirmEmergency();
    setConfirmingHelp(false);
    setActionMessage(result);
  }

  return (
    <section className="asha-companion" aria-labelledby="asha-companion-title">
      <div className="asha-companion-head">
        <span className="asha-avatar" aria-hidden="true">A</span>
        <div><span className="eyebrow">ASHA COMPANION</span><h2 id="asha-companion-title">I’m here with you.</h2></div>
        <span className={aiAvailable ? "asha-presence live" : "asha-presence"}><i />{aiAvailable ? "Service ready" : "Offline-ready"}</span>
      </div>

      <ol className="conversation" aria-live="polite" aria-busy={busy} aria-label="Conversation with Asha">
        {messages.map((message) => (
          <li key={message.id} className={`conversation-message ${message.role}`}>
            <div><small>{message.role === "asha" ? `Asha · ${message.mode ?? "companion"}` : "You"}</small><p>{message.text}</p></div>
            {message.role === "asha" && <button type="button" onClick={() => onSpeak(message.text)} aria-label={`Play Asha message aloud: ${message.text}`}>▶ Play</button>}
            {message.citations?.length ? (
              <ul className="citation-list" aria-label="Sources">
                {message.citations.map((citation, index) => {
                  const url = safeCitationUrl(citation.url);
                  return <li key={`${message.id}-source-${index}`}>{url ? <a href={url} target="_blank" rel="noreferrer">{citation.title}</a> : citation.title}{citation.snippet && <span>{citation.snippet}</span>}</li>;
                })}
              </ul>
            ) : null}
          </li>
        ))}
        {busy && <li className="conversation-message asha pending"><div><small>Asha</small><p>Thinking with care…</p></div></li>}
      </ol>

      <form className="asha-composer" onSubmit={(event) => void submitMessage(event)}>
        <label htmlFor="asha-message">Message Asha</label>
        <textarea id="asha-message" value={draft} onChange={(event) => setDraft(event.target.value)} rows={2} maxLength={1_000} placeholder="Type what you need or how you feel…" />
        <div className="composer-actions">
          <button className={listening ? "voice-input listening" : "voice-input"} type="button" onClick={toggleVoiceInput} disabled={!voiceInputAvailable} aria-pressed={listening}>
            {listening ? "■ Stop listening" : voiceInputAvailable ? "● Press to talk" : "Voice input unavailable"}
          </button>
          <button className="send-message" type="submit" disabled={!draft.trim() || busy}>{busy ? "Sending…" : "Ask Asha"}</button>
        </div>
        <small>{voiceInputAvailable ? "Voice input starts only when you press the button; typing always works." : "This browser does not offer speech recognition. Type your message instead."}</small>
      </form>

      <div className="patient-primary-actions" aria-label="Patient quick actions">
        <button type="button" onClick={writeDisplay}><span aria-hidden="true">▣</span><strong>Write on Pi display</strong><small>Send this draft, or Asha’s latest reply</small></button>
        <button type="button" onClick={callCaregiver}><span aria-hidden="true">☎</span><strong>Call caregiver</strong><small>{caregiverConfigured ? "Open your phone dialer" : "Add a local contact first"}</small></button>
        <button className="need-help" type="button" onClick={() => setConfirmingHelp(true)}><span aria-hidden="true">!</span><strong>Need help</strong><small>Requires confirmation</small></button>
      </div>

      {confirmingHelp && (
        <div className="emergency-confirmation" role="alertdialog" aria-modal="true" aria-labelledby="confirm-help-title" aria-describedby="confirm-help-copy">
          <div><strong id="confirm-help-title">Send a confirmed help request?</strong><p id="confirm-help-copy">This will speak “I need help now” locally and notify approved caregivers when alert sharing is enabled. FingerSpeak is not an emergency service.</p></div>
          <div><button type="button" className="confirm-help" onClick={confirmEmergency}>Confirm I need help</button><button type="button" onClick={() => setConfirmingHelp(false)}>Cancel</button></div>
        </div>
      )}
      <p className="asha-action-status" role="status">{actionMessage}</p>
    </section>
  );
}
