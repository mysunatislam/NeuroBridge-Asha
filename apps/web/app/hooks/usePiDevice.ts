"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  createCaptionCommand,
  createDemoTelemetry,
  createEmergencyDisplayCommand,
  createHeartbeatCommand,
  createPairingAuthentication,
  normalizePiWebSocketUrl,
  parsePairingAuthenticatedMessage,
  parsePiCommandResult,
  parsePiPatientIntentMessage,
  parsePiTelemetryMessage,
  PiPatientIntentGate,
  PI_DEVICE_SUBPROTOCOL,
  type PiCredentialKind,
  type PiPatientIntent,
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
  const [patientIntent, setPatientIntent] = useState<PiPatientIntent | null>(null);
  const socketRef = useRef<WebSocket | null>(null);
  const reconnectRef = useRef<number | null>(null);
  const heartbeatRef = useRef<number | null>(null);
  const phoneIdRef = useRef("");
  const sequenceRef = useRef(0);
  const reconnectAttemptRef = useRef(0);
  const pendingCommandsRef = useRef(new Map<string, { resolve(accepted: boolean): void; timeout: number }>());
  const patientIntentGateRef = useRef(new PiPatientIntentGate());

  const settlePendingCommands = useCallback((accepted = false) => {
    for (const pending of pendingCommandsRef.current.values()) {
      window.clearTimeout(pending.timeout);
      pending.resolve(accepted);
    }
    pendingCommandsRef.current.clear();
  }, []);

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
    settlePendingCommands(false);
    patientIntentGateRef.current.reset();
    socketRef.current?.close(1000, "Pi endpoint changed");
    socketRef.current = null;

    if (!endpoint || !pairingToken) {
      return;
    }

    let cancelled = false;
    const connect = () => {
      if (cancelled) return;
      if (socketRef.current && (socketRef.current.readyState === WebSocket.OPEN || socketRef.current.readyState === WebSocket.CONNECTING)) return;
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
        reconnectAttemptRef.current = 0;
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
        const commandResult = parsePiCommandResult(raw);
        if (commandResult) {
          const pending = pendingCommandsRef.current.get(commandResult.commandId);
          if (pending) {
            window.clearTimeout(pending.timeout);
            pendingCommandsRef.current.delete(commandResult.commandId);
            pending.resolve(commandResult.accepted);
            setMessage(commandResult.accepted ? "Raspberry Pi confirmed the display update." : `The Pi rejected the command: ${commandResult.detail}`);
          }
          return;
        }
        const nextPatientIntent = parsePiPatientIntentMessage(raw);
        if (nextPatientIntent) {
          if (!cancelled && nextPatientIntent.deviceId === DEVICE_ID && patientIntentGateRef.current.accept(nextPatientIntent)) {
            setPatientIntent(nextPatientIntent);
          }
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
        settlePendingCommands(false);
        setStatus("unavailable");
        setMessage("Pi is unavailable. Captions are previewed locally and are not delivered.");
        if (![4401, 4403, 4406].includes(event.code)) {
          const attempt = reconnectAttemptRef.current++;
          const delay = Math.min(30_000, 1_500 * (2 ** Math.min(attempt, 4))) + Math.round(Math.random() * 500);
          reconnectRef.current = window.setTimeout(connect, delay);
        }
      };
    };
    connect();
    const reconnectWhenVisible = () => {
      if (document.visibilityState !== "visible" || cancelled) return;
      if (!socketRef.current || socketRef.current.readyState === WebSocket.CLOSED) {
        if (reconnectRef.current !== null) window.clearTimeout(reconnectRef.current);
        reconnectRef.current = null;
        connect();
      }
    };
    document.addEventListener("visibilitychange", reconnectWhenVisible);

    return () => {
      cancelled = true;
      document.removeEventListener("visibilitychange", reconnectWhenVisible);
      if (reconnectRef.current !== null) window.clearTimeout(reconnectRef.current);
      if (heartbeatRef.current !== null) window.clearInterval(heartbeatRef.current);
      reconnectRef.current = null;
      heartbeatRef.current = null;
      settlePendingCommands(false);
      socketRef.current?.close(1000, "FingerSpeak closed the Pi connection");
      socketRef.current = null;
    };
  }, [credentialKind, endpoint, pairingToken, settlePendingCommands]);

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

  const sendCommand = useCallback((command: { message_id: string; type: string; [key: string]: unknown }): Promise<boolean> => {
    const socket = socketRef.current;
    if (!socket || socket.readyState !== WebSocket.OPEN) return Promise.resolve(false);
    return new Promise((resolve) => {
      let attempts = 0;
      const fail = () => {
        pendingCommandsRef.current.delete(command.message_id);
        setMessage(`The Pi did not acknowledge the ${command.type} command.`);
        resolve(false);
      };
      const transmit = () => {
        attempts += 1;
        const timeout = window.setTimeout(() => {
          if (attempts < 2 && socket.readyState === WebSocket.OPEN) {
            setMessage(`The Pi has not acknowledged ${command.type} yet. Retrying once…`);
            transmit();
          } else {
            fail();
          }
        }, 4_000);
        pendingCommandsRef.current.set(command.message_id, { resolve, timeout });
        try {
          // Reusing the same message ID makes this single retry idempotent on the edge.
          socket.send(JSON.stringify(command));
        } catch {
          window.clearTimeout(timeout);
          fail();
        }
      };
      transmit();
    });
  }, []);

  const sendCaption = useCallback((caption: string): Promise<boolean> => {
    const text = caption.trim().slice(0, 280);
    if (!text) return Promise.resolve(false);
    const command = createCaptionCommand(text, DEVICE_ID, sequenceRef.current++, navigator.language || "en-US");
    setTelemetry((current) => ({ ...current, caption: text }));
    return sendCommand(command);
  }, [sendCommand]);

  const sendEmergency = useCallback((caption: string): Promise<boolean> => {
    const text = caption.trim().slice(0, 500);
    if (!text) return Promise.resolve(false);
    const command = createEmergencyDisplayCommand(text, DEVICE_ID, sequenceRef.current++, navigator.language || "en-US");
    setTelemetry((current) => ({ ...current, caption: text }));
    return sendCommand(command);
  }, [sendCommand]);

  return { endpoint, pairingToken, status, telemetry, patientIntent, message, configureConnection, sendCaption, sendEmergency };
}
