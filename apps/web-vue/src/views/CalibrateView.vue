<script setup lang="ts">
import { computed, ref } from "vue";
import { useRouter } from "vue-router";
import { useFingerSpeakStore } from "../stores/fingerspeak";
import { useCameraInference } from "../composables/useCameraInference";
import { parseProfile, type Gesture } from "../lib/fingerspeak";
import { importPrototypeBundle } from "../lib/model-bundle";
import CameraStage from "../components/CameraStage.vue";
import GestureHealth from "../components/GestureHealth.vue";

const store = useFingerSpeakStore();
const camera = useCameraInference();
const router = useRouter();
const profileInput = ref<HTMLInputElement | null>(null);
const modelInput = ref<HTMLInputElement | null>(null);
const readiness = computed(() => Math.min(100, Math.round(store.capturedCount / store.requiredCount * 100)));
const readinessStyle = computed(() => ({ "--readiness": `${readiness.value * 3.6}deg` }));

async function train(): Promise<void> {
  camera.captureMessage.value = "Building your personal gesture model on this device…";
  if (await camera.trainLocalModel()) await router.push("/speak");
}

async function importProfileFile(file: File): Promise<void> {
  if (file.size > 5_000_000) {
    camera.captureMessage.value = "Profile rejected: files must be smaller than 5 MB.";
    return;
  }
  try {
    const imported = parseProfile(JSON.parse(await file.text()));
    await store.replaceProfile(imported);
    camera.captureMessage.value = "Profile imported with cloud consent off. Train locally or import its matching model bundle.";
  } catch (error) {
    camera.captureMessage.value = error instanceof Error ? `Profile rejected: ${error.message}` : "Profile rejected.";
  }
}

async function importModelFiles(files: FileList): Promise<void> {
  try {
    const imported = await importPrototypeBundle(Array.from(files), store.profile);
    await store.activateModel(imported);
    camera.captureMessage.value = "Asha learned this verified gesture bundle. The personal model is ready and remains bound to this profile.";
  } catch (error) {
    camera.captureMessage.value = error instanceof Error ? `Model rejected: ${error.message}` : "Model bundle rejected.";
  }
}

function handleProfileChange(event: Event): void {
  const input = event.currentTarget as HTMLInputElement;
  const file = input.files?.[0];
  if (file) void importProfileFile(file);
  input.value = "";
}
function handleModelChange(event: Event): void {
  const input = event.currentTarget as HTMLInputElement;
  if (input.files?.length) void importModelFiles(input.files);
  input.value = "";
}
function exportProfile(): void {
  const blob = new Blob([JSON.stringify(store.profile, null, 2)], { type: "application/json" });
  const link = document.createElement("a");
  link.href = URL.createObjectURL(blob);
  link.download = "fingerspeak-profile-v3.json";
  link.click();
  URL.revokeObjectURL(link.href);
  camera.captureMessage.value = "Profile exported. Treat it as sensitive health and movement data.";
}
function improveGesture(gesture: Gesture): void {
  camera.captureMessage.value = `${gesture.name}: capture two fresh examples from slightly different comfortable positions.`;
}
</script>

<template>
  <section class="calibration-page" aria-labelledby="calibrate-title">
    <div class="page-intro calibration-intro">
      <span class="eyebrow">YOUR GESTURE PROFILE · PERSONALIZED ON-DEVICE LEARNING</span>
      <h1 id="calibrate-title">Teach FingerSpeak the movement you can make.</h1>
      <p>FingerSpeak adapts to your comfortable movement rather than forcing a universal gesture set. More varied examples improve robustness while the protected Rest state helps prevent accidental speech.</p>
    </div>

    <div class="profile-overview">
      <div class="readiness-ring" :style="readinessStyle"><span><strong>{{ readiness }}%</strong><small>model readiness</small></span></div>
      <div class="overview-copy"><span class="eyebrow">PERSONAL MODEL</span><h2>{{ store.calibrationReady ? 'Ready to learn your gestures.' : 'A few examples make it yours.' }}</h2><p>{{ Math.min(store.capturedCount, store.requiredCount) }} / {{ store.requiredCount }} minimum captures · {{ store.model ? 'model active' : 'training remains local' }}</p></div>
      <div class="overview-nodes" aria-hidden="true"><i>✋</i><b /><i>○</i><b /><i>✦</i><b /><i>🔊</i></div>
    </div>

    <div class="calibration-layout enhanced-calibration-layout">
      <div class="calibration-stack">
        <div class="calibration-main">
          <div class="calibration-progress">
            <div><span>{{ Math.min(store.capturedCount, store.requiredCount) }} / {{ store.requiredCount }}</span><small>minimum captures</small></div>
            <div class="progress-track"><span :style="{ width: `${readiness}%` }" /></div>
            <strong>{{ store.calibrationReady ? 'Ready to train' : 'Keep going' }}</strong>
          </div>

          <div class="gesture-list">
            <article v-for="(gesture, index) in store.profile.gestures" :key="gesture.id" :class="['gesture-row', { capturing: camera.captureTarget.value === gesture.id }]">
              <span class="gesture-number">{{ String(index + 1).padStart(2, '0') }}</span>
              <span :class="['mini-icon', `risk-${gesture.risk}`]">{{ gesture.icon }}</span>
              <div class="gesture-copy"><strong>{{ gesture.name }}</strong><small>{{ gesture.phrase || 'Neutral / release state' }}</small></div>
              <div class="sample-dots" :aria-label="`${gesture.samples.length} samples`">
                <i v-for="dot in 5" :key="dot" :class="{ filled: dot <= gesture.samples.length }" />
              </div>
              <button class="button capture" :disabled="camera.captureTarget.value !== null" @click="camera.captureGesture(gesture)">
                {{ camera.captureTarget.value === gesture.id ? 'Capturing…' : 'Capture' }}
              </button>
            </article>
          </div>
        </div>

        <GestureHealth :gestures="store.profile.gestures" @improve="improveGesture" />
      </div>

      <aside class="calibration-aside">
        <div class="mini-camera">
          <CameraStage
            @video="camera.videoEl.value = $event"
            @canvas="camera.canvasEl.value = $event"
            :camera-status="camera.cameraStatus.value"
            :camera-message="camera.cameraMessage.value"
            :tracking="camera.tracking.value"
            :face-tracking="camera.faceTracking.value"
            :hand-count="camera.handCount.value"
            :vision-signals="camera.visionSignals.value"
            :hand-predictions="camera.handPredictions.value"
            :inference-ms="camera.inferenceMs.value"
          />
        </div>
        <button v-if="camera.cameraStatus.value === 'ready'" class="button secondary full" @click="camera.stopCamera">Stop camera</button>
        <button v-else class="button primary full" :disabled="camera.cameraStatus.value === 'loading'" @click="camera.startCamera">Start private camera</button>
        <p class="capture-message" role="status">{{ camera.captureMessage.value }}</p>
        <button class="button train full" :disabled="!store.calibrationReady" @click="train">{{ store.model ? 'Rebuild personal model' : 'Train on this device' }}</button>

        <div v-if="store.model" class="model-ready-note"><span>✦</span><div><strong>Asha learned your gestures</strong><small>Personal model ready · stored locally</small></div></div>

        <div class="profile-tools">
          <button @click="exportProfile">Export profile JSON*</button>
          <button @click="profileInput?.click()">Import profile</button>
          <input ref="profileInput" type="file" accept="application/json" hidden @change="handleProfileChange" />
          <button @click="modelInput?.click()">Import Python model</button>
          <input ref="modelInput" type="file" accept="application/json" multiple hidden @change="handleModelChange" />
        </div>
        <small class="asterisk">*Profile JSON is not encrypted. Select manifest.json and edge-prototype.json together for a model bundle.</small>
      </aside>
    </div>
  </section>
</template>
