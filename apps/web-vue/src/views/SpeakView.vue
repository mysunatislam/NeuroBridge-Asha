<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from "vue";
import { storeToRefs } from "pinia";
import { useFingerSpeakStore } from "../stores/fingerspeak";
import { useCopilotStore } from "../stores/copilot";
import { useCameraInference } from "../composables/useCameraInference";
import CameraStage from "../components/CameraStage.vue";
import IntentCard from "../components/IntentCard.vue";
import PhraseGrid from "../components/PhraseGrid.vue";
import SmartSuggestions from "../components/SmartSuggestions.vue";
import SentenceComposer from "../components/SentenceComposer.vue";
import ContextSelector from "../components/ContextSelector.vue";

const store = useFingerSpeakStore();
const copilot = useCopilotStore();
const { context, suggestions, pendingPhrase } = storeToRefs(copilot);
const camera = useCameraInference();
const customPhrase = ref("");
const showCustom = ref(false);

function speakCustomPhrase(phrase: string): void {
  camera.speakPhrase(phrase);
}

function addCustomPhrase(): void {
  const clean = customPhrase.value.trim();
  if (!clean) return;
  copilot.savePhrase(clean);
  customPhrase.value = "";
  showCustom.value = false;
}

watch(pendingPhrase, (phrase) => {
  if (!phrase) return;
  speakCustomPhrase(phrase);
  copilot.clearPendingPhrase();
});

onBeforeUnmount(camera.stopCamera);
</script>

<template>
  <section class="workspace speak-workspace" aria-labelledby="speak-title">
    <div class="camera-column">
      <div class="section-heading speak-heading">
        <div>
          <span class="eyebrow">PATIENT VIEW · PRIVATE REAL-TIME COMMUNICATION</span>
          <h1 id="speak-title">Your voice, without the wait.</h1>
          <p class="contextual-line"><span>✦</span> Asha learns your communication context, routines and preferred expressions.</p>
        </div>
        <div class="heading-controls">
          <ContextSelector v-model="context" />
          <span :class="['tracking-pill', { live: camera.tracking.value }]">
            {{ camera.tracking.value ? `${camera.handCount.value} hand${camera.handCount.value > 1 ? 's' : ''} found` : camera.cameraStatus.value === 'ready' ? 'Show either hand' : 'Camera idle' }}
          </span>
        </div>
      </div>

      <div class="camera-card intelligent-camera">
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
        <div class="camera-actions">
          <button v-if="camera.cameraStatus.value === 'ready'" class="button secondary" @click="camera.stopCamera">Stop camera</button>
          <button v-else class="button primary" :disabled="camera.cameraStatus.value === 'loading'" @click="camera.startCamera">
            Start private camera
          </button>
          <RouterLink class="button ghost" to="/calibrate">{{ store.model ? 'Recalibrate' : 'Set up gestures' }}</RouterLink>
        </div>
      </div>

      <div class="privacy-note">
        <span>◉</span>
        <p><strong>Speech never waits for the network.</strong> Hand landmarks, recognition, safety confirmation, and speech stay on this device. Optional face-cue inference is separated from communication intent and never triggers an emergency action by itself. Asha prepares options; the patient confirms communication.</p>
      </div>

      <SentenceComposer @speak="speakCustomPhrase" />
    </div>

    <div class="voice-column">
      <IntentCard
        :model-ready="Boolean(store.model)"
        :gesture="camera.currentGesture.value"
        :prediction="camera.prediction.value"
        :intent="camera.intent.value"
        @speak="camera.touchPhrase"
        @edit="copilot.setComposerPhrase"
        @save="copilot.savePhrase"
      />

      <div class="phrase-header communication-header">
        <div><span class="eyebrow">QUICK COMMUNICATION</span><h2>What would you like to say?</h2></div>
        <span class="voice-status" role="status">{{ camera.voiceMessage.value }}</span>
      </div>
      <PhraseGrid
        :gestures="store.profile.gestures"
        :armed-gesture-id="camera.armedGestureId.value"
        @select="camera.touchPhrase"
      />

      <div class="custom-phrase-wrap">
        <button v-if="!showCustom" class="custom-phrase-trigger" @click="showCustom = true">＋ Custom phrase</button>
        <div v-else class="custom-phrase-editor">
          <input v-model="customPhrase" placeholder="Type a phrase to keep nearby" @keyup.enter="addCustomPhrase" />
          <button @click="addCustomPhrase">Save</button><button @click="showCustom = false">Cancel</button>
        </div>
      </div>

      <SmartSuggestions :suggestions="suggestions" @select="speakCustomPhrase" />
    </div>
  </section>
</template>
