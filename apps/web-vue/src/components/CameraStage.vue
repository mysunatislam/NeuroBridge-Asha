<script setup lang="ts">
import type { ComponentPublicInstance } from "vue";
import type { CameraStatus, VisionSignals, HandPrediction } from "../composables/useCameraInference";

defineProps<{
  cameraStatus: CameraStatus;
  cameraMessage: string;
  tracking: boolean;
  faceTracking?: boolean;
  handCount?: number;
  inferenceMs?: number;
  visionSignals?: VisionSignals;
  handPredictions?: HandPrediction[];
}>();

const emit = defineEmits<{
  video: [element: HTMLVideoElement | null];
  canvas: [element: HTMLCanvasElement | null];
}>();
function setVideoRef(element: Element | ComponentPublicInstance | null): void { emit("video", element instanceof HTMLVideoElement ? element : null); }
function setCanvasRef(element: Element | ComponentPublicInstance | null): void { emit("canvas", element instanceof HTMLCanvasElement ? element : null); }
</script>

<template>
  <div class="video-stage">
    <video :ref="setVideoRef" playsinline muted aria-label="Private camera preview" />
    <canvas :ref="setCanvasRef" aria-hidden="true" />
    <div v-if="cameraStatus !== 'ready'" class="camera-placeholder">
      <span class="hand-orbit">🫶</span>
      <strong>{{ cameraStatus === 'loading' ? 'Preparing multimodal recognition…' : 'Camera stays private' }}</strong>
      <p>FingerSpeak can observe both hands plus face/head/eye cues. Raw video is not uploaded by this interface.</p>
    </div>

    <div v-else class="tracking-visual" :class="{ active: tracking || faceTracking }" aria-hidden="true"><i /><i /><i /></div>

    <div v-if="cameraStatus === 'ready'" class="vision-readout multimodal-readout">
      <span><b>{{ tracking ? `${handCount || 1} HAND${(handCount || 1) > 1 ? 'S' : ''}` : 'HANDS READY' }}</b><small>{{ handPredictions?.length ? handPredictions.map(h => `${h.handedness}: ${h.gestureId || '…'}`).join(' · ') : 'Show either or both hands' }}</small></span>
      <span><b>{{ faceTracking ? 'FACE + HEAD' : 'FACE READY' }}</b><small>{{ visionSignals?.faceModelReady === false ? 'cue model optional' : (visionSignals?.head || 'center') }}</small></span>
      <span><b>{{ visionSignals?.eyes || 'steady' }}</b><small>eye activity</small></span>
      <span><b>{{ inferenceMs ? `${inferenceMs.toFixed(0)} ms` : 'Local' }}</b><small>vision loop</small></span>
    </div>

    <div v-if="cameraStatus === 'ready' && visionSignals?.facePresent" class="wellbeing-readout">
      <span :class="['cue-dot', `cue-${visionSignals.cue}`]" />
      <div><strong>{{ visionSignals.cue === 'neutral' ? 'No strong wellbeing cue' : `Possible ${visionSignals.cue} cue` }}</strong><small>{{ visionSignals.note }}</small></div>
    </div>

    <div class="camera-status" role="status"><span :class="['status-dot', { live: tracking || faceTracking }]" />{{ cameraMessage }}</div>
  </div>
</template>
