"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  createCaptionCommand,
  createDemoTelemetry,
  createHeartbeatCommand,
  createPairingAuthentication,
  normalizePiWebSocketUrl,
  parsePairingAuthenticatedMessage,
  parsePiTelemetryMessage,
  PI_DEVICE_SUBPROTOCOL,
  type PiCredentialKind,
  type PiTelemetry,
} from "../lib/pi-device";

export type PiConnectionStatus = "demo" | "connecting" | "connected" | "unavailable";

const ENDPOINT_KEY = "fingerspeak:pi-websocket-url";
const PAIRING_TOKEN_KEY = "fingerspeak:pi-pairing-token";
const CREDENTIAL_KIND_KEY = "fingerspeak:pi-credential-kind";
const PHONE_ID_KEY = "fingerspeak:phone-id";
const ENV_ENDPOINT = process.env.NEXT_PUBLIC_PI_WS_URL ?? "";
const DEVICE_ID = process.env.NEXT_PUBLIC_PI_DEVICE_ID ?? "fingerspeak-pi";

export function usePiDevice() {
  const [endpoint, setEndpoint] = useState(ENV_ENDPOINT);
  const [pairingToken, setPairingToken] = useState("");
  const [credentialKind, setCredentialKind] = useState<PiCredentialKind>("pairing_code");
  const [status, setStatus] = useState<PiConnectionStatus>("demo");
  const [telemetry, setTelemetry] = useState<PiTelemetry>(() => createDemoTelemetry());
  const [message, setMessage] = useState("Demo mode · no authenticated Raspberry Pi is connected.");
  const socketRef = useRef<WebSocket | null>(null);
  const reconnectRef = useRef<number | null>(null);
  const heartbeatRef = useRef<number | null>(null);
  const phoneIdRef = useRef("");
  const sequenceRef = useRef(0);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      const saved = window.localStorage.getItem(ENDPOINT_KEY);
      if (saved !== null) setEndpoint(saved);
      setPairingToken(window.localStorage.getItem(PAIRING_TOKEN_KEY) ?? "");
      const savedKind = window.localStorage.getItem(CREDENTIAL_KIND_KEY);
      setCredentialKind(savedKind === "device_credential" ? "device_credential" : "pairing_code");
      let phoneId = window.localStorage.getItem(PHONE_ID_KEY) ?? "";
      if (!phoneId) {
        phoneId = `phone-${crypto.randomUUID()}`;
        window.localStorage.setItem(PHONE_ID_KEY, phoneId);
      }
      phoneIdRef.current = phoneId;
    }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  useEffect(() => {
    if (reconnectRef.current !== null) window.clearTimeout(reconnectRef.current);
    if (heartbeatRef.current !== null) window.clearInterval(heartbeatRef.current);
    socketRef.current?.close(1000, "Pi endpoint changed");
    socketRef.current = null;

    if (!endpoint || !pairingToken) {
      return;
    }

    let cancelled = false;
    const connect = () => {
      if (cancelled) return;
      setStatus("connecting");
      setMessage("Connecting to the configured Pi…");
      let socket: WebSocket;
      try {
        socket = new WebSocket(endpoint, PI_DEVICE_SUBPROTOCOL);
      } catch {
        setStatus("unavailable");
        setMessage("The Pi address could not be opened. Local display preview remains available.");
        return;
      }
      socketRef.current = socket;
      socket.onopen = () => {
        if (cancelled) return;
        setMessage("Pi reached. Verifying the local pairing token…");
        socket.send(JSON.stringify(createPairingAuthentication(
          pairingToken,
          DEVICE_ID,
          phoneIdRef.current,
          credentialKind,
          sequenceRef.current++,
        )));
      };
      let pairingAccepted = false;
      socket.onmessage = (event) => {
        const raw = String(event.data);
        if (!pairingAccepted) {
          const accepted = parsePairingAuthenticatedMessage(raw);
          if (!accepted) {
            setMessage("Pi pairing was rejected. Telemetry was not accepted.");
            socket.close(4403, "Pairing was not accepted");
            return;
          }
          pairingAccepted = true;
          if (accepted.deviceCredential) {
            window.localStorage.setItem(PAIRING_TOKEN_KEY, accepted.deviceCredential);
            window.localStorage.setItem(CREDENTIAL_KIND_KEY, "device_credential");
            setPairingToken(accepted.deviceCredential);
            setCredentialKind("device_credential");
          }
          const heartbeatMs = Math.max(2_000, Math.round(accepted.heartbeatIntervalSeconds * 1_000));
          if (heartbeatRef.current !== null) window.clearInterval(heartbeatRef.current);
          heartbeatRef.current = window.setInterval(() => {
            if (socket.readyState === WebSocket.OPEN) {
              socket.send(JSON.stringify(createHeartbeatCommand(DEVICE_ID, sequenceRef.current++)));
            }
          }, heartbeatMs);
          setStatus("connected");
          setMessage("Raspberry Pi paired and connected live.");
          return;
        }
        const update = parsePiTelemetryMessage(raw);
        if (!update || cancelled) return;
        setTelemetry((current) => ({ ...current, ...update, lastSeen: update.lastSeen ?? new Date().toISOString() }));
      };
      socket.onerror = () => socket.close();
      socket.onclose = (event) => {
        if (cancelled) return;
        if (heartbeatRef.current !== null) window.clearInterval(heartbeatRef.current);
        heartbeatRef.current = null;
        socketRef.current = null;
        setStatus("unavailable");
        setMessage("Pi is unavailable. Captions are previewed locally and are not delivered.");
        if (![4401, 4403, 4406].includes(event.code)) reconnectRef.current = window.setTimeout(connect, 4_000);
      };
    };
    connect();

    return () => {
      cancelled = true;
      if (reconnectRef.current !== null) window.clearTimeout(reconnectRef.current);
      if (heartbeatRef.current !== null) window.clearInterval(heartbeatRef.current);
      reconnectRef.current = null;
      heartbeatRef.current = null;
      socketRef.current?.close(1000, "FingerSpeak closed the Pi connection");
      socketRef.current = null;
    };
  }, [credentialKind, endpoint, pairingToken]);

  const configureConnection = useCallback((value: string, token: string): string => {
    try {
      const normalized = normalizePiWebSocketUrl(value);
      const normalizedToken = token.trim();
      if (normalized && !normalizedToken) return "Add the local Pi pairing token before connecting.";
      window.localStorage.setItem(ENDPOINT_KEY, normalized);
      window.localStorage.setItem(PAIRING_TOKEN_KEY, normalizedToken);
      window.localStorage.setItem(CREDENTIAL_KIND_KEY, "pairing_code");
      setEndpoint(normalized);
      setPairingToken(normalizedToken);
      setCredentialKind("pairing_code");
      if (!normalized) {
        setStatus("demo");
        setMessage("Demo mode · add a Pi address and pairing token to connect.");
        setTelemetry((current) => createDemoTelemetry(current.caption));
      }
      return normalized ? "Pi address and pairing token saved only on this device." : "Pi connection cleared. Demo mode is active.";
    } catch (error) {
      return error instanceof Error ? error.message : "The Pi address is invalid.";
    }
  }, []);

  const sendCaption = useCallback((caption: string): boolean => {
    const text = caption.trim().slice(0, 280);
    if (!text) return false;
    const command = createCaptionCommand(text, DEVICE_ID, sequenceRef.current++, navigator.language || "en-US");
    setTelemetry((current) => ({ ...current, caption: text }));
    const socket = socketRef.current;
    if (!socket || socket.readyState !== WebSocket.OPEN) return false;
    socket.send(JSON.stringify(command));
    return true;
  }, []);

  return { endpoint, pairingToken, status, telemetry, message, configureConnection, sendCaption };
}
