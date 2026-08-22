import type { PiConnectionStatus } from "../hooks/usePiDevice";
import type { PiTelemetry } from "../lib/pi-device";

type Props = {
  status: PiConnectionStatus;
  statusMessage: string;
  telemetry: PiTelemetry;
};

function percent(value: number | null): string {
  return value === null ? "Unknown" : `${value}%`;
}

function lastSeen(value: string | null): string {
  if (!value) return "No live telemetry";
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? "Unknown" : parsed.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

export function PiDisplayView({ status, statusMessage, telemetry }: Props) {
  const connected = status === "connected";
  return (
    <section className="pi-display-page" aria-labelledby="pi-display-title">
      <header className="pi-display-header">
        <div><span className="eyebrow">RASPBERRY PI DISPLAY</span><h1 id="pi-display-title">Live writing &amp; tracking</h1></div>
        <span className={connected ? "pi-display-connection live" : "pi-display-connection"}><i />{connected ? "Paired live" : status === "connecting" ? "Pairing…" : "Demo preview"}</span>
      </header>

      <div className="pi-caption-stage">
        <small>ASHA / PATIENT CAPTION</small>
        <p aria-live="polite">{telemetry.caption}</p>
        <span>{connected ? "Synced from the phone" : "Local preview · not delivered to hardware"}</span>
      </div>

      <div className="pi-indicator-grid" aria-label="Wheelchair device indicators">
        <article className={telemetry.tracking === true ? "live" : ""}><i /><div><small>TRACKING</small><strong>{telemetry.tracking === null ? "Unknown" : telemetry.tracking ? "Movement found" : "Waiting"}</strong></div></article>
        <article className={telemetry.camera === "ready" ? "live" : telemetry.camera === "error" ? "error" : ""}><i /><div><small>NOIR CAMERA</small><strong>{telemetry.camera === "ready" ? "Ready" : telemetry.camera === "error" ? "Needs attention" : telemetry.camera === "off" ? "Off" : "Unknown"}</strong></div></article>
        <article className={telemetry.phoneConnected === true || connected ? "live" : ""}><i /><div><small>PHONE LINK</small><strong>{connected || telemetry.phoneConnected ? "Connected" : "Not connected"}</strong></div></article>
        <article><i /><div><small>PI POWER</small><strong>{percent(telemetry.piPowerPercent)}</strong></div></article>
        <article><i /><div><small>WHEELCHAIR BATTERY</small><strong>{percent(telemetry.wheelchairBatteryPercent)}</strong></div></article>
        <article><i /><div><small>LAST TELEMETRY</small><strong>{lastSeen(telemetry.lastSeen)}</strong></div></article>
      </div>

      <p className="pi-display-note" role="status">{statusMessage} This surface shows captions and device state only; conversation audio stays on the phone.</p>
    </section>
  );
}
