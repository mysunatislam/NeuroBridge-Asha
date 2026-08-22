<script setup lang="ts">
import { computed } from "vue";
import type { Gesture } from "../lib/fingerspeak";

const props = defineProps<{ gestures: Gesture[] }>();
const emit = defineEmits<{ improve: [gesture: Gesture] }>();
const health = computed(() => props.gestures.filter((g) => g.id !== "rest").map((gesture) => ({
  gesture,
  score: Math.min(98, 46 + gesture.samples.length * 13),
})));
</script>

<template>
  <section class="gesture-health-card">
    <div class="card-title compact"><div><span class="eyebrow">ADAPTIVE PROFILE</span><h2>Gesture Health</h2></div><span>sample-based readiness</span></div>
    <div class="health-list">
      <button v-for="item in health" :key="item.gesture.id" class="health-row" @click="emit('improve', item.gesture)">
        <span>{{ item.gesture.icon }}</span><div><div><strong>{{ item.gesture.name }}</strong><small>{{ item.score }}% reliable</small></div><i><b :style="{ width: `${item.score}%` }" /></i></div><em>{{ item.score < 70 ? 'Improve →' : 'Healthy' }}</em>
      </button>
    </div>
  </section>
</template>
