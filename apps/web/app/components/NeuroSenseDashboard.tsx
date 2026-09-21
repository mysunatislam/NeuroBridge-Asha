"use client";

import { useEffect, useRef, useState } from "react";
import type { NeuroFaceStatus } from "../lib/neuroface-rules";
import type { SomaticEvent } from "../lib/maira-api";

type Props = {
  videoRef: React.RefObject<HTMLVideoElement | null>;
  cameraActive: boolean;
  neurofaceStatus: NeuroFaceStatus;
  faceCalibrationProgress: number;
  onRecalibrate(): void;
  onClose(): void;
  onSpeakPhrase(phrase: string): void;
  onStartCamera?(): void;
  recentSomaticEvents?: SomaticEvent[];
};

type TelemetrySample = {
  t: number;
  ear: number;
  yaw: number;
  pitch: number;
  smile: number;
};

export function NeuroSenseDashboard({
  videoRef,
  cameraActive,
  neurofaceStatus,
  faceCalibrationProgress,
  onRecalibrate,
  onClose,
  onSpeakPhrase,
  onStartCamera,
  recentSomaticEvents = [],
}: Props) {
  const internalVideoRef = useRef<HTMLVideoElement | null>(null);
  const historyRef = useRef<TelemetrySample[]>([]);
  const earCanvasRef = useRef<HTMLCanvasElement | null>(null);
  const headCanvasRef = useRef<HTMLCanvasElement | null>(null);
  const smileCanvasRef = useRef<HTMLCanvasElement | null>(null);
  const overlayCanvasRef = useRef<HTMLCanvasElement | null>(null);

  const [blinkFlash, setBlinkFlash] = useState(false);
  const prevBlinkCountRef = useRef(0);

  const metrics = neurofaceStatus.metrics;
  const calibrated = neurofaceStatus.calibrated;
  const recentBlinks = neurofaceStatus.recentBlinkCount ?? 0;
  const recentLeft = neurofaceStatus.recentHeadLeftCount ?? 0;
  const recentRight = neurofaceStatus.recentHeadRightCount ?? 0;
  const nodReversals = neurofaceStatus.nodReversalsCount ?? 0;

  // Flash animation on blink
  useEffect(() => {
    if (recentBlinks > prevBlinkCountRef.current) {
      setBlinkFlash(true);
      const timer = window.setTimeout(() => setBlinkFlash(false), 300);
      prevBlinkCountRef.current = recentBlinks;
      return () => window.clearTimeout(timer);
    }
    prevBlinkCountRef.current = recentBlinks;
  }, [recentBlinks]);

  // Synchronize internal video element with camera stream without hijacking videoRef
  useEffect(() => {
    const video = videoRef.current;
    const internal = internalVideoRef.current;
    if (cameraActive && video && internal && video.srcObject) {
      if (internal.srcObject !== video.srcObject) {
        internal.srcObject = video.srcObject;
        internal.play().catch(() => {});
      }
    }
  }, [cameraActive, videoRef]);

  // Record telemetry sample every frame
  useEffect(() => {
    if (!metrics) return;
    const sample: TelemetrySample = {
      t: Date.now(),
      ear: metrics.earAvg,
      yaw: metrics.yawDeg,
      pitch: metrics.pitchDeg,
      smile: metrics.smile,
    };
    const hist = historyRef.current;
    hist.push(sample);
    if (hist.length > 120) hist.shift();
  }, [metrics]);

  // Render Dynamic Curves Animation Loop
  useEffect(() => {
    let animId: number;

    const renderCurves = () => {
      const hist = historyRef.current;
      if (hist.length >= 2) {
        // ── 1. EAR Canvas ──────────────────────────────────────────────
        const earCanvas = earCanvasRef.current;
        if (earCanvas) {
          const ctx = earCanvas.getContext("2d");
          if (ctx) {
            const w = earCanvas.width;
            const h = earCanvas.height;
            ctx.clearRect(0, 0, w, h);

            // Background grid
            ctx.strokeStyle = "rgba(255, 255, 255, 0.06)";
            ctx.lineWidth = 1;
            for (let y = 0; y < h; y += 20) {
              ctx.beginPath();
              ctx.moveTo(0, y);
              ctx.lineTo(w, y);
              ctx.stroke();
            }

            // Threshold lines
            const thCloseY = h - 0.16 * (h / 0.4);
            const thOpenY = h - 0.22 * (h / 0.4);

            ctx.strokeStyle = "rgba(239, 68, 68, 0.6)"; // Close threshold (red)
            ctx.setLineDash([4, 4]);
            ctx.beginPath();
            ctx.moveTo(0, thCloseY);
            ctx.lineTo(w, thCloseY);
            ctx.stroke();

            ctx.strokeStyle = "rgba(16, 185, 129, 0.6)"; // Open threshold (green)
            ctx.beginPath();
            ctx.moveTo(0, thOpenY);
            ctx.lineTo(w, thOpenY);
            ctx.stroke();
            ctx.setLineDash([]);

            // Draw EAR Waveform
            ctx.strokeStyle = "#10b981";
            ctx.lineWidth = 2.5;
            ctx.beginPath();
            for (let i = 0; i < hist.length; i++) {
              const x = (i / (hist.length - 1)) * w;
              const y = h - Math.max(0, Math.min(0.4, hist[i].ear)) * (h / 0.4);
              if (i === 0) ctx.moveTo(x, y);
              else ctx.lineTo(x, y);
            }
            ctx.stroke();

            // Current point dot
            const lastSample = hist[hist.length - 1];
            const curY = h - Math.max(0, Math.min(0.4, lastSample.ear)) * (h / 0.4);
            ctx.fillStyle = "#34d399";
            ctx.beginPath();
            ctx.arc(w - 4, curY, 4, 0, Math.PI * 2);
            ctx.fill();
          }
        }

        // ── 2. Head Yaw & Pitch Canvas ────────────────────────────────
        const headCanvas = headCanvasRef.current;
        if (headCanvas) {
          const ctx = headCanvas.getContext("2d");
          if (ctx) {
            const w = headCanvas.width;
            const h = headCanvas.height;
            const midY = h / 2;
            ctx.clearRect(0, 0, w, h);

            // Center neutral line
            ctx.strokeStyle = "rgba(255, 255, 255, 0.15)";
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(0, midY);
            ctx.lineTo(w, midY);
            ctx.stroke();

            // Thresholds (-12° left, +12° right)
            const leftY = midY - (-12 * (h / 60));
            const rightY = midY - (12 * (h / 60));
            ctx.strokeStyle = "rgba(14, 165, 233, 0.4)";
            ctx.setLineDash([3, 3]);
            ctx.beginPath();
            ctx.moveTo(0, leftY);
            ctx.lineTo(w, leftY);
            ctx.moveTo(0, rightY);
            ctx.lineTo(w, rightY);
            ctx.stroke();
            ctx.setLineDash([]);

            // Draw Yaw curve (Cyan)
            ctx.strokeStyle = "#0ea5e9";
            ctx.lineWidth = 2.5;
            ctx.beginPath();
            for (let i = 0; i < hist.length; i++) {
              const x = (i / (hist.length - 1)) * w;
              const y = midY - (hist[i].yaw * (h / 60));
              if (i === 0) ctx.moveTo(x, y);
              else ctx.lineTo(x, y);
            }
            ctx.stroke();

            // Draw Pitch curve (Magenta)
            ctx.strokeStyle = "#a855f7";
            ctx.lineWidth = 2;
            ctx.beginPath();
            for (let i = 0; i < hist.length; i++) {
              const x = (i / (hist.length - 1)) * w;
              const y = midY - (hist[i].pitch * (h / 60));
              if (i === 0) ctx.moveTo(x, y);
              else ctx.lineTo(x, y);
            }
            ctx.stroke();
          }
        }

        // ── 3. Smile Intensity Canvas ─────────────────────────────────
        const smileCanvas = smileCanvasRef.current;
        if (smileCanvas) {
          const ctx = smileCanvas.getContext("2d");
          if (ctx) {
            const w = smileCanvas.width;
            const h = smileCanvas.height;
            ctx.clearRect(0, 0, w, h);

            // 35% smile threshold
            const thSmileY = h - 0.35 * h;
            ctx.strokeStyle = "rgba(245, 158, 11, 0.5)";
            ctx.setLineDash([3, 3]);
            ctx.beginPath();
            ctx.moveTo(0, thSmileY);
            ctx.lineTo(w, thSmileY);
            ctx.stroke();
            ctx.setLineDash([]);

            // Smile curve (Amber)
            ctx.strokeStyle = "#f59e0b";
            ctx.lineWidth = 2.5;
            ctx.beginPath();
            for (let i = 0; i < hist.length; i++) {
              const x = (i / (hist.length - 1)) * w;
              const y = h - (hist[i].smile * h);
              if (i === 0) ctx.moveTo(x, y);
              else ctx.lineTo(x, y);
            }
            ctx.stroke();
          }
        }
      }

      animId = requestAnimationFrame(renderCurves);
    };

    animId = requestAnimationFrame(renderCurves);
    return () => cancelAnimationFrame(animId);
  }, []);

  const lookingAtCamera =
    metrics &&
    Math.abs(metrics.yawDeg) < 11 &&
    Math.abs(metrics.pitchDeg) < 22;

  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 1000,
        background: "#080e14",
        color: "#e2e8f0",
        display: "flex",
        flexDirection: "column",
        overflowY: "auto",
        fontFamily: "system-ui, -apple-system, sans-serif",
      }}
    >
      {/* ── Top Header ────────────────────────────────────────────── */}
      <header
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          padding: "16px 24px",
          background: "linear-gradient(180deg, #0f172a 0%, #080e14 100%)",
          borderBottom: "1px solid rgba(255, 255, 255, 0.08)",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: "14px" }}>
          <div
            style={{
              width: "40px",
              height: "40px",
              borderRadius: "12px",
              background: "linear-gradient(135deg, #0ea5e9, #10b981)",
              display: "grid",
              placeItems: "center",
              fontSize: "20px",
            }}
          >
            👁️
          </div>
          <div>
            <h1 style={{ margin: 0, fontSize: "20px", fontWeight: 800, letterSpacing: "-0.02em" }}>
              NeuroSense™ Face Studio
            </h1>
            <p style={{ margin: 0, fontSize: "12px", color: "#94a3b8" }}>
              Real-time High-Precision Facial Dynamic Telemetry &amp; Intent Suite
            </p>
          </div>
        </div>

        <div style={{ display: "flex", alignItems: "center", gap: "12px" }}>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: "8px",
              padding: "6px 14px",
              borderRadius: "999px",
              background: calibrated ? "rgba(16, 185, 129, 0.15)" : "rgba(245, 158, 11, 0.15)",
              border: `1px solid ${calibrated ? "#10b981" : "#f59e0b"}`,
              fontSize: "12px",
              fontWeight: 700,
              color: calibrated ? "#34d399" : "#fbbf24",
            }}
          >
            <span
              style={{
                width: "8px",
                height: "8px",
                borderRadius: "50%",
                background: calibrated ? "#10b981" : "#f59e0b",
                boxShadow: `0 0 8px ${calibrated ? "#10b981" : "#f59e0b"}`,
              }}
            />
            {calibrated ? "TWIN CALIBRATED" : `CALIBRATING ${Math.round(faceCalibrationProgress * 100)}%`}
          </div>

          <button
            type="button"
            onClick={onRecalibrate}
            style={{
              padding: "8px 16px",
              borderRadius: "10px",
              border: "1px solid rgba(255, 255, 255, 0.15)",
              background: "rgba(255, 255, 255, 0.05)",
              color: "#e2e8f0",
              fontSize: "12px",
              fontWeight: 700,
              cursor: "pointer",
            }}
          >
            ↺ Recalibrate (60f)
          </button>

          <button
            type="button"
            onClick={onClose}
            style={{
              padding: "8px 18px",
              borderRadius: "10px",
              border: "0",
              background: "#0ea5e9",
              color: "#fff",
              fontSize: "13px",
              fontWeight: 800,
              cursor: "pointer",
            }}
          >
            ✕ Exit Studio
          </button>
        </div>
      </header>

      {/* ── Main Dashboard Layout ──────────────────────────────────── */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "1.1fr 1fr",
          gap: "20px",
          padding: "20px 24px",
          flex: 1,
        }}
      >
        {/* Left Column: Camera Viewport with Visual Gaze Target */}
        <div style={{ display: "flex", flexDirection: "column", gap: "16px" }}>
          <div
            style={{
              position: "relative",
              borderRadius: "18px",
              overflow: "hidden",
              background: "#0f172a",
              border: `2px solid ${blinkFlash ? "#34d399" : lookingAtCamera ? "rgba(16, 185, 129, 0.4)" : "rgba(255, 255, 255, 0.1)"}`,
              boxShadow: blinkFlash ? "0 0 30px rgba(52, 211, 153, 0.4)" : "0 10px 30px rgba(0, 0, 0, 0.5)",
              minHeight: "360px",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            {/* Camera Video / Preview */}
            {cameraActive ? (
              <video
                ref={internalVideoRef}
                autoPlay
                playsInline
                muted
                style={{
                  width: "100%",
                  height: "100%",
                  objectFit: "cover",
                  transform: "scaleX(-1)",
                }}
              />
            ) : (
              <div
                style={{
                  textAlign: "center",
                  padding: "40px 20px",
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  gap: "14px",
                }}
              >
                <div style={{ fontSize: "42px" }}>📷</div>
                <h3 style={{ margin: 0, fontSize: "16px", color: "#e2e8f0" }}>Private Camera is Idle</h3>
                <p style={{ margin: 0, fontSize: "12px", color: "#94a3b8", maxWidth: "280px" }}>
                  Start the private camera to track intentional eye blinks and head gestures in real-time.
                </p>
                {onStartCamera && (
                  <button
                    type="button"
                    onClick={onStartCamera}
                    style={{
                      marginTop: "6px",
                      padding: "10px 22px",
                      borderRadius: "12px",
                      background: "linear-gradient(135deg, #10b981, #059669)",
                      color: "#fff",
                      border: "0",
                      fontWeight: 800,
                      cursor: "pointer",
                      fontSize: "13px",
                      boxShadow: "0 4px 12px rgba(16, 185, 129, 0.4)",
                    }}
                  >
                    ▶ Start Private Camera
                  </button>
                )}
              </div>
            )}

            {/* Visual Gaze Target Overlay */}
            <div
              style={{
                position: "absolute",
                inset: "15%",
                border: `2px dashed ${lookingAtCamera ? "#10b981" : "rgba(255, 255, 255, 0.2)"}`,
                borderRadius: "16px",
                pointerEvents: "none",
                display: "flex",
                alignItems: "flex-start",
                justifyContent: "center",
                padding: "8px",
              }}
            >
              <span
                style={{
                  fontSize: "11px",
                  fontWeight: 700,
                  background: lookingAtCamera ? "rgba(16, 185, 129, 0.85)" : "rgba(0, 0, 0, 0.6)",
                  color: "#fff",
                  padding: "3px 10px",
                  borderRadius: "999px",
                }}
              >
                {lookingAtCamera ? "TARGET CAMERA GAZE LOCKED ✓" : "CENTER FACE INSIDE BOX"}
              </span>
            </div>

            {/* Blink Flash Notification */}
            {blinkFlash && (
              <div
                style={{
                  position: "absolute",
                  inset: 0,
                  background: "rgba(52, 211, 153, 0.2)",
                  display: "grid",
                  placeItems: "center",
                  pointerEvents: "none",
                }}
              >
                <div
                  style={{
                    background: "#10b981",
                    color: "#fff",
                    padding: "8px 20px",
                    borderRadius: "999px",
                    fontSize: "16px",
                    fontWeight: 900,
                  }}
                >
                  ⚡ DELIBERATE BLINK DETECTED!
                </div>
              </div>
            )}

            {/* Corner Indicators */}
            <div
              style={{
                position: "absolute",
                bottom: "12px",
                left: "14px",
                right: "14px",
                display: "flex",
                justifyContent: "space-between",
                alignItems: "center",
                background: "rgba(15, 23, 42, 0.8)",
                backdropFilter: "blur(8px)",
                padding: "8px 14px",
                borderRadius: "10px",
                fontSize: "12px",
                fontWeight: 600,
              }}
            >
              <span>EAR: <strong>{metrics ? metrics.earAvg.toFixed(3) : "0.000"}</strong></span>
              <span>Yaw: <strong>{metrics ? `${metrics.yawDeg.toFixed(1)}°` : "0.0°"}</strong></span>
              <span>Pitch: <strong>{metrics ? `${metrics.pitchDeg.toFixed(1)}°` : "0.0°"}</strong></span>
              <span>Smile: <strong>{metrics ? `${Math.round(metrics.smile * 100)}%` : "0%"}</strong></span>
            </div>
          </div>

          {/* 4 Interactive NeuroSense Rule Progress Cards */}
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "12px" }}>
            {/* Rule 1: Water */}
            <div
              style={{
                background: "rgba(255, 255, 255, 0.03)",
                border: "1px solid rgba(255, 255, 255, 0.08)",
                borderRadius: "14px",
                padding: "14px",
                display: "flex",
                flexDirection: "column",
                gap: "8px",
              }}
            >
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                <span style={{ fontSize: "13px", fontWeight: 800 }}>👁️ 3 Blinks → Water</span>
                <span style={{ fontSize: "11px", color: lookingAtCamera ? "#34d399" : "#94a3b8" }}>
                  {lookingAtCamera ? "Gaze locked" : "Need center gaze"}
                </span>
              </div>
              <div style={{ display: "flex", gap: "8px", alignItems: "center" }}>
                {[1, 2, 3].map((step) => (
                  <div
                    key={step}
                    style={{
                      flex: 1,
                      height: "10px",
                      borderRadius: "999px",
                      background: recentBlinks >= step ? "#10b981" : "rgba(255, 255, 255, 0.1)",
                      boxShadow: recentBlinks >= step ? "0 0 8px #10b981" : "none",
                      transition: "all 0.2s ease",
                    }}
                  />
                ))}
              </div>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                <small style={{ color: "#94a3b8" }}>{recentBlinks} / 3 intentional blinks</small>
                <button
                  type="button"
                  onClick={() => onSpeakPhrase("I need water")}
                  style={{
                    padding: "3px 8px",
                    borderRadius: "6px",
                    border: "0",
                    background: "rgba(16, 185, 129, 0.2)",
                    color: "#34d399",
                    fontSize: "10px",
                    fontWeight: 800,
                    cursor: "pointer",
                  }}
                >
                  ▶ Test Voice
                </button>
              </div>
            </div>

            {/* Rule 2: Food */}
            <div
              style={{
                background: "rgba(255, 255, 255, 0.03)",
                border: "1px solid rgba(255, 255, 255, 0.08)",
                borderRadius: "14px",
                padding: "14px",
                display: "flex",
                flexDirection: "column",
                gap: "8px",
              }}
            >
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                <span style={{ fontSize: "13px", fontWeight: 800 }}>⬅️ 3 Head Left → Food</span>
                <span style={{ fontSize: "11px", color: "#0ea5e9" }}>
                  {metrics && metrics.yawDeg < -12 ? "◄ Turning Left" : "Return to center"}
                </span>
              </div>
              <div style={{ display: "flex", gap: "8px", alignItems: "center" }}>
                {[1, 2, 3].map((step) => (
                  <div
                    key={step}
                    style={{
                      flex: 1,
                      height: "10px",
                      borderRadius: "999px",
                      background: recentLeft >= step ? "#0ea5e9" : "rgba(255, 255, 255, 0.1)",
                      boxShadow: recentLeft >= step ? "0 0 8px #0ea5e9" : "none",
                      transition: "all 0.2s ease",
                    }}
                  />
                ))}
              </div>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                <small style={{ color: "#94a3b8" }}>{recentLeft} / 3 left turns</small>
                <button
                  type="button"
                  onClick={() => onSpeakPhrase("I need food")}
                  style={{
                    padding: "3px 8px",
                    borderRadius: "6px",
                    border: "0",
                    background: "rgba(14, 165, 233, 0.2)",
                    color: "#38bdf8",
                    fontSize: "10px",
                    fontWeight: 800,
                    cursor: "pointer",
                  }}
                >
                  ▶ Test Voice
                </button>
              </div>
            </div>

            {/* Rule 3: Toilet */}
            <div
              style={{
                background: "rgba(255, 255, 255, 0.03)",
                border: "1px solid rgba(255, 255, 255, 0.08)",
                borderRadius: "14px",
                padding: "14px",
                display: "flex",
                flexDirection: "column",
                gap: "8px",
              }}
            >
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                <span style={{ fontSize: "13px", fontWeight: 800 }}>➡️ 3 Head Right → Toilet</span>
                <span style={{ fontSize: "11px", color: "#6366f1" }}>
                  {metrics && metrics.yawDeg > 12 ? "Turning Right ►" : "Return to center"}
                </span>
              </div>
              <div style={{ display: "flex", gap: "8px", alignItems: "center" }}>
                {[1, 2, 3].map((step) => (
                  <div
                    key={step}
                    style={{
                      flex: 1,
                      height: "10px",
                      borderRadius: "999px",
                      background: recentRight >= step ? "#6366f1" : "rgba(255, 255, 255, 0.1)",
                      boxShadow: recentRight >= step ? "0 0 8px #6366f1" : "none",
                      transition: "all 0.2s ease",
                    }}
                  />
                ))}
              </div>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                <small style={{ color: "#94a3b8" }}>{recentRight} / 3 right turns</small>
                <button
                  type="button"
                  onClick={() => onSpeakPhrase("I need to go to toilet")}
                  style={{
                    padding: "3px 8px",
                    borderRadius: "6px",
                    border: "0",
                    background: "rgba(99, 102, 241, 0.2)",
                    color: "#818cf8",
                    fontSize: "10px",
                    fontWeight: 800,
                    cursor: "pointer",
                  }}
                >
                  ▶ Test Voice
                </button>
              </div>
            </div>

            {/* Rule 4: Okay */}
            <div
              style={{
                background: "rgba(255, 255, 255, 0.03)",
                border: "1px solid rgba(255, 255, 255, 0.08)",
                borderRadius: "14px",
                padding: "14px",
                display: "flex",
                flexDirection: "column",
                gap: "8px",
              }}
            >
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                <span style={{ fontSize: "13px", fontWeight: 800 }}>😊 Nod + Smile → OK</span>
                <span style={{ fontSize: "11px", color: metrics && metrics.smile > 0.35 ? "#f59e0b" : "#94a3b8" }}>
                  {metrics && metrics.smile > 0.35 ? "Smile ACTIVE" : "Smile needed"}
                </span>
              </div>
              <div style={{ display: "flex", gap: "8px", alignItems: "center" }}>
                {[1, 2, 3].map((step) => (
                  <div
                    key={step}
                    style={{
                      flex: 1,
                      height: "10px",
                      borderRadius: "999px",
                      background: nodReversals >= step ? "#f59e0b" : "rgba(255, 255, 255, 0.1)",
                      boxShadow: nodReversals >= step ? "0 0 8px #f59e0b" : "none",
                      transition: "all 0.2s ease",
                    }}
                  />
                ))}
              </div>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                <small style={{ color: "#94a3b8" }}>{nodReversals} / 3 nod reversals</small>
                <button
                  type="button"
                  onClick={() => onSpeakPhrase("I am okay, thank you")}
                  style={{
                    padding: "3px 8px",
                    borderRadius: "6px",
                    border: "0",
                    background: "rgba(245, 158, 11, 0.2)",
                    color: "#fbbf24",
                    fontSize: "10px",
                    fontWeight: 800,
                    cursor: "pointer",
                  }}
                >
                  ▶ Test Voice
                </button>
              </div>
            </div>
          </div>
        </div>

        {/* Right Column: 3 Dynamic Telemetry Curves / Oscilloscopes */}
        <div style={{ display: "flex", flexDirection: "column", gap: "16px" }}>
          {/* Curve 1: Eye Aspect Ratio (EAR) */}
          <div
            style={{
              background: "rgba(15, 23, 42, 0.6)",
              border: "1px solid rgba(255, 255, 255, 0.08)",
              borderRadius: "16px",
              padding: "16px",
              display: "flex",
              flexDirection: "column",
              gap: "10px",
            }}
          >
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <div>
                <strong style={{ fontSize: "14px", color: "#34d399" }}>📈 Eye Openness Dynamics (EAR Waveform)</strong>
                <p style={{ margin: "2px 0 0", fontSize: "11px", color: "#94a3b8" }}>
                  Green line = open threshold · Red dashed = close threshold
                </p>
              </div>
              <div style={{ textAlign: "right" }}>
                <span style={{ fontSize: "18px", fontWeight: 800, color: "#34d399" }}>
                  {metrics ? metrics.earAvg.toFixed(3) : "0.000"}
                </span>
                <small style={{ display: "block", fontSize: "10px", color: "#64748b" }}>Live EAR</small>
              </div>
            </div>
            <canvas
              ref={earCanvasRef}
              width={480}
              height={90}
              style={{ width: "100%", height: "90px", borderRadius: "8px", background: "rgba(0, 0, 0, 0.3)" }}
            />
          </div>

          {/* Curve 2: Head Yaw & Pitch Multi-Axis */}
          <div
            style={{
              background: "rgba(15, 23, 42, 0.6)",
              border: "1px solid rgba(255, 255, 255, 0.08)",
              borderRadius: "16px",
              padding: "16px",
              display: "flex",
              flexDirection: "column",
              gap: "10px",
            }}
          >
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <div>
                <strong style={{ fontSize: "14px", color: "#38bdf8" }}>📉 Head Orientation (Cyan: Yaw · Purple: Pitch)</strong>
                <p style={{ margin: "2px 0 0", fontSize: "11px", color: "#94a3b8" }}>
                  Horizontal left/right turn threshold: ±12°
                </p>
              </div>
              <div style={{ textAlign: "right" }}>
                <span style={{ fontSize: "16px", fontWeight: 800, color: "#38bdf8" }}>
                  {metrics ? `${metrics.yawDeg.toFixed(1)}°` : "0.0°"}
                </span>
                <small style={{ display: "block", fontSize: "10px", color: "#64748b" }}>Current Yaw</small>
              </div>
            </div>
            <canvas
              ref={headCanvasRef}
              width={480}
              height={90}
              style={{ width: "100%", height: "90px", borderRadius: "8px", background: "rgba(0, 0, 0, 0.3)" }}
            />
          </div>

          {/* Curve 3: Smile Intensity */}
          <div
            style={{
              background: "rgba(15, 23, 42, 0.6)",
              border: "1px solid rgba(255, 255, 255, 0.08)",
              borderRadius: "16px",
              padding: "16px",
              display: "flex",
              flexDirection: "column",
              gap: "10px",
            }}
          >
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <div>
                <strong style={{ fontSize: "14px", color: "#fbbf24" }}>📊 Smile Intensity (Nod + Smile Threshold: 35%)</strong>
                <p style={{ margin: "2px 0 0", fontSize: "11px", color: "#94a3b8" }}>
                  Amber line = live smile engagement
                </p>
              </div>
              <div style={{ textAlign: "right" }}>
                <span style={{ fontSize: "16px", fontWeight: 800, color: "#fbbf24" }}>
                  {metrics ? `${Math.round(metrics.smile * 100)}%` : "0%"}
                </span>
                <small style={{ display: "block", fontSize: "10px", color: "#64748b" }}>Smile Score</small>
              </div>
            </div>
            <canvas
              ref={smileCanvasRef}
              width={480}
              height={90}
              style={{ width: "100%", height: "90px", borderRadius: "8px", background: "rgba(0, 0, 0, 0.3)" }}
            />
          </div>
        </div>
      </div>
    </div>
  );
}
