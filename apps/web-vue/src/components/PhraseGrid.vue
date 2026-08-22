<script setup lang="ts">
import type { Gesture } from "../lib/fingerspeak";

defineProps<{ gestures: Gesture[]; armedGestureId: string | null }>();
const emit = defineEmits<{ select: [gesture: Gesture] }>();
</script>

<template>
  <div class="phrase-grid">
    <button
      v-for="gesture in gestures.filter((item) => item.phrase)"
      :key="gesture.id"
      :class="['phrase-button', `risk-${gesture.risk}`, { armed: armedGestureId === gesture.id }]"
      @click="emit('select', gesture)"
    >
      <span class="phrase-icon" aria-hidden="true">{{ gesture.icon }}</span>
      <span>
        <strong>{{ armedGestureId === gesture.id ? 'Touch again to confirm' : gesture.name }}</strong>
        <small>{{ gesture.phrase }}</small>
      </span>
      <span class="speak-arrow" aria-hidden="true">›</span>
    </button>
  </div>
</template>
