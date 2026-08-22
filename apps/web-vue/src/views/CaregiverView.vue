<script setup lang="ts">
import { computed } from "vue";
import { useFingerSpeakStore } from "../stores/fingerspeak";
import { useCaregiverRealtime } from "../composables/useCaregiverRealtime";

const store = useFingerSpeakStore();
const realtime = useCaregiverRealtime();
const eventCount = computed(() => store.spoken.length + realtime.alerts.value.length);
const repeatedRequests = computed(() => {
  const counts = new Map<string, number>();
  store.spoken.forEach((entry) => counts.set(entry.phrase, (counts.get(entry.phrase) ?? 0) + 1));
  return Array.from(counts.values()).filter((count) => count > 1).reduce((sum, count) => sum + count - 1, 0);
});
const trend = computed(() => {
  const now = Date.now();
  const buckets = Array.from({ length: 8 }, () => 0);
  store.spoken.forEach((entry) => {
    const ageHours = (now - new Date(entry.at).getTime()) / 3_600_000;
    const bucket = 7 - Math.floor(ageHours);
    if (bucket >= 0 && bucket < buckets.length) buckets[bucket] += 1;
  });
  const max = Math.max(1, ...buckets);
  return buckets.map((value, index) => `${(index / 7) * 100},${38 - (value / max) * 30}`).join(" ");
});
</script>

<template>
  <section class="caregiver-page" aria-labelledby="caregiver-title">
    <div class="page-intro caregiver-intro">
      <div>
        <span class="eyebrow">CAREGIVER VIEW · CONFIRMED COMMUNICATION ONLY</span>
        <h1 id="caregiver-title">Signal, context, and calm.</h1>
        <p>Confirmed alerts arrive after on-device safety checks. A disconnected dashboard never blocks local speech, and Asha suggestions are never shown here as if they were patient requests.</p>
      </div>
      <span :class="['connection-card', { online: realtime.socketStatus.value === 'live' }]">
        <i />{{ realtime.socketStatus.value === 'live' ? 'Live connection' : realtime.socketStatus.value === 'connecting' ? 'Connecting…' : 'Offline · local log only' }}
      </span>
    </div>

    <section class="caregiver-glance">
      <div><small>COMMUNICATIONS</small><strong>{{ store.spoken.length }}</strong><span>confirmed this session</span></div>
      <div><small>REPEATED REQUESTS</small><strong>{{ repeatedRequests }}</strong><span>worth noticing</span></div>
      <div><small>FALSE ACTIVATIONS</small><strong>{{ store.falseActivations }}</strong><span>feedback for calibration</span></div>
      <div class="activity-curve"><div><small>ACTIVITY</small><strong>Recent pattern</strong></div><svg viewBox="0 0 100 42" preserveAspectRatio="none" aria-label="Recent communication activity"><path d="M0 38 H100" /><polyline :points="trend" /></svg></div>
    </section>

    <div class="caregiver-grid">
      <section class="alerts-card">
        <div class="card-title">
          <div><span class="eyebrow">TODAY</span><h2>Communication timeline</h2></div>
          <span>{{ eventCount }} events</span>
        </div>
        <div class="timeline">
          <article v-for="alert in realtime.alerts.value" :key="alert.id" :class="['timeline-event', alert.severity]">
            <i />
            <div>
              <strong>{{ alert.message }}</strong>
              <p>Confirmed on patient device · {{ alert.status }}</p>
              <span class="alert-actions">
                <button v-if="alert.status === 'pending'" @click="realtime.actOnAlert(alert, 'acknowledge')">Acknowledge</button>
                <button v-if="alert.status !== 'resolved'" @click="realtime.actOnAlert(alert, 'resolve')">Resolve</button>
              </span>
            </div>
            <time>{{ new Date(alert.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) }}</time>
          </article>

          <article v-for="entry in store.spoken" :key="entry.id" :class="['timeline-event', entry.risk]">
            <i />
            <div><strong>{{ entry.phrase }}</strong><p>{{ entry.gesture }} · {{ entry.source === 'gesture' ? 'gesture confirmed' : 'patient-selected phrase' }}</p></div>
            <time>{{ new Date(entry.at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) }}</time>
          </article>

          <div v-if="!store.spoken.length && !realtime.alerts.value.length" class="empty-state">
            <span>○</span><strong>No confirmed events yet</strong><p>Patient-confirmed communication and consented alerts will appear here.</p>
          </div>
        </div>
      </section>

      <aside class="caregiver-side">
        <section class="access-card">
          <span class="eyebrow">AUTHORIZED ACCESS</span><h2>Connect a caregiver</h2>
          <label>Shared profile ID<input v-model="realtime.profileInput.value" placeholder="00000000-0000-0000-0000-000000000000" /></label>
          <button @click="realtime.connectProfile">Open authorized dashboard</button>
          <label>Caregiver subject (owner only)<input v-model="realtime.caregiverSubject.value" placeholder="caregiver account subject" /></label>
          <button @click="realtime.grantAccess">Grant caregiver access</button>
          <small role="status">{{ realtime.message.value }}</small>
          <code v-if="store.remoteProfileId">Profile: {{ store.remoteProfileId }}</code>
        </section>

        <section class="metrics-card">
          <span class="eyebrow">SESSION QUALITY</span>
          <div class="metric-grid">
            <div><strong>{{ store.spoken.length }}</strong><small>phrases</small></div>
            <div><strong>{{ store.falseActivations }}</strong><small>false activations</small></div>
            <div><strong>{{ store.missedGestures }}</strong><small>missed gestures</small></div>
            <div><strong>{{ store.model ? 'Ready' : 'Setup' }}</strong><small>edge model</small></div>
          </div>
          <div class="metric-actions"><button @click="store.markFalseActivation">Mark false activation</button><button @click="store.markMissedGesture">Mark missed gesture</button></div>
        </section>

        <section class="consent-card">
          <div><span class="eyebrow">DATA CONTROL</span><h2>Cloud sharing</h2></div>
          <div class="toggle-row">
            <span><strong>Share confirmed activity</strong><small>Opaque gesture keys and timing only</small></span>
            <button class="switch" type="button" role="switch" aria-label="Share confirmed activity events" :aria-checked="store.profile.consentToEventSync" @click="store.updateConsent('consentToEventSync', !store.profile.consentToEventSync)"><i /></button>
          </div>
          <div class="toggle-row">
            <span><strong>Send caregiver alerts</strong><small>Confirmed request text is shared with approved caregivers</small></span>
            <button class="switch" type="button" role="switch" aria-label="Send confirmed caregiver alerts" :aria-checked="store.profile.consentToCaregiverAlerts" @click="store.updateConsent('consentToCaregiverAlerts', !store.profile.consentToCaregiverAlerts)"><i /></button>
          </div>
          <p>Video, audio, hand landmarks, raw calibration sequences, labels, and routine phrases remain on this device.</p>
        </section>

        <section class="safety-card"><strong>Not an emergency service</strong><p>Caregiver WebSockets are a convenience channel, not guaranteed delivery. Keep a tested call switch or emergency pathway available.</p></section>
      </aside>
    </div>
  </section>
</template>
