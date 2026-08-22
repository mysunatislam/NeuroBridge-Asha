<script setup lang="ts">
import { computed } from "vue";
import type { Gesture } from "../lib/fingerspeak";
import type { IntentOutput } from "../lib/intent-machine";

const props = defineProps<{
  modelReady: boolean;
  gesture: Gesture | null;
  prediction: { gestureId: string | null; confidence: number; inDistribution: boolean };
  intent: IntentOutput;
}>();
const emit = defineEmits<{ speak: [gesture: Gesture]; edit: [phrase: string]; save: [phrase: string] }>();

const progressStyle = computed(() => ({ "--progress": `${Math.round(Math.max(props.intent.progress, props.prediction.confidence) * 360)}deg` }));
const stateLabel = computed(() => props.intent.state === "WAIT_RELEASE" ? "Release hand" : props.intent.state);
const recognizedName = computed(() => {
  if (!props.modelReady) return "Touch phrases still work";
  if (!props.prediction.inDistribution) return "Unrecognized movement";
  return props.gesture?.name ?? "Watching…";
});
const phrase = computed(() => props.gesture?.phrase || "Your confirmed phrase will appear here.");
</script>

<template>
  <section class="intent-card" aria-label="Live gesture intent">
    <div class="intent-topline">
      <span>LIVE INTENT</span>
      <span :class="['intent-state', `state-${intent.state.toLowerCase()}`]">{{ stateLabel }}</span>
    </div>
    <div class="recognized-gesture">
      <div :class="['gesture-orb', { danger: gesture?.risk === 'emergency', breathing: !prediction.inDistribution }]" :style="progressStyle">
        <span>{{ prediction.inDistribution ? (gesture?.icon ?? '·') : '·' }}</span>
      </div>
      <div class="recognized-copy">
        <small>{{ modelReady ? (prediction.inDistribution ? 'Tracking hand · local match' : 'Recognizing locally') : 'Calibration needed' }}</small>
        <strong>{{ recognizedName }}</strong>
        <p><b>{{ Math.round(prediction.confidence * 100) }}% confidence</b> · {{ intent.state === 'CANDIDATE' ? 'keep holding' : intent.state === 'WAIT_RELEASE' ? 'return to Rest' : 'ready' }}</p>
      </div>
    </div>
    <div class="intent-phrase-preview">
      <span>Prepared phrase</span><strong>“{{ phrase }}”</strong>
      <div class="intent-actions">
        <button :disabled="!gesture?.phrase" @click="gesture && emit('speak', gesture)">Speak</button>
        <button :disabled="!gesture?.phrase" @click="gesture?.phrase && emit('edit', gesture.phrase)">Edit</button>
        <button :disabled="!gesture?.phrase" @click="gesture?.phrase && emit('save', gesture.phrase)">Save phrase</button>
      </div>
    </div>
    <div class="confidence-track" :aria-label="`Confirmation ${Math.round(intent.progress * 100)} percent`">
      <span :style="{ width: `${intent.progress * 100}%` }" />
    </div>
  </section>
</template>
