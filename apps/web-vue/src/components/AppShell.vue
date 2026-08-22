<script setup lang="ts">
import { RouterLink, useRoute } from "vue-router";
import { storeToRefs } from "pinia";
import { useFingerSpeakStore } from "../stores/fingerspeak";
import { useCopilotStore } from "../stores/copilot";
import { modeById } from "../lib/care-modes";
import AmbientCurves from "./AmbientCurves.vue";
import AshaCopilot from "./AshaCopilot.vue";

const store = useFingerSpeakStore();
const copilot = useCopilotStore();
const route = useRoute();
const { theme, careMode } = storeToRefs(copilot);
const links = [
  { to: "/", label: "Modes" },
  { to: "/speak", label: "Speak" },
  { to: "/calibrate", label: "Calibrate" },
  { to: "/caregiver", label: "Caregiver" },
];
</script>

<template>
  <div class="app-shell">
    <AmbientCurves />
    <div class="global-glitter" aria-hidden="true" />
    <header class="topbar">
      <RouterLink class="brand" to="/" aria-label="FingerSpeak home">
        <span class="brand-mark">FS</span>
        <span><strong>FingerSpeak</strong><small>Asha multimodal assist</small></span>
      </RouterLink>

      <nav class="mode-switch" aria-label="Application views">
        <RouterLink v-for="link in links" :key="link.to" :to="link.to" :class="{ active: route.path === link.to }">{{ link.label }}</RouterLink>
      </nav>

      <div class="system-badges" aria-label="System status">
        <span class="active-care-mode">{{ modeById(careMode).icon }} {{ modeById(careMode).title }}</span>
        <button class="theme-toggle" @click="copilot.toggleTheme" :aria-label="`Switch to ${theme === 'dark' ? 'bright' : 'dark'} mode`">
          <span>{{ theme === 'dark' ? '☾' : '☀' }}</span>{{ theme === 'dark' ? 'Dark glow' : 'Bright glow' }}
        </button>
        <span class="privacy-badge"><i /> On-device AI</span>
      </div>
    </header>

    <main><slot /></main>
    <AshaCopilot />

    <footer>
      <span>FingerSpeak prototype · assistive communication and observation, not autonomous clinical decision-making</span>
      <span>Observe → ask → confirm → communicate</span>
    </footer>
  </div>
</template>
