<script setup lang="ts">
import { computed, onMounted, watch } from "vue";
import { useRoute } from "vue-router";
import { storeToRefs } from "pinia";
import { modeById } from "../lib/care-modes";
import { useCopilotStore, type CareMode } from "../stores/copilot";
import { speakAsha } from "../lib/asha-voice";

const route = useRoute();
const copilot = useCopilotStore();
const { language, voiceGender } = storeToRefs(copilot);
const mode = computed(() => modeById((route.meta.mode as CareMode) || copilot.careMode));

function announceMode(): void { speakAsha(mode.value.voicePrompt[language.value], { language: language.value, gender: voiceGender.value, speed: copilot.speakingSpeed, style: copilot.preferredVoice }); }
function activate(): void { copilot.setCareMode(mode.value.id); }
onMounted(() => { activate(); window.setTimeout(announceMode, 250); });
watch(() => route.path, () => { activate(); announceMode(); });
</script>

<template>
  <section class="mode-hub-page">
    <div class="mode-hub-hero">
      <div>
        <span class="eyebrow">{{ mode.icon }} {{ mode.title.toUpperCase() }}</span>
        <h1>{{ mode.hero }}</h1>
        <p>{{ mode.description }}</p>
        <div class="mode-actions"><RouterLink v-for="action in mode.actions" :key="action.to + action.label" :to="action.to" :class="['mode-action', action.kind || 'secondary']">{{ action.label }}</RouterLink><button class="mode-action voice" @click="announceMode">🔊 Hear this mode</button></div>
      </div>
      <aside class="mode-voice-card"><span>✦</span><small>ASHA WILL ASK & GUIDE IN VOICE</small><strong>{{ language }} · {{ voiceGender }} voice</strong><p>{{ mode.voicePrompt[language] }}</p></aside>
    </div>

    <div class="mode-feature-grid"><article v-for="feature in mode.features" :key="feature.title"><span>{{ feature.icon }}</span><div><strong>{{ feature.title }}</strong><p>{{ feature.text }}</p></div></article></div>
    <div class="mode-safety-panel"><div><span class="eyebrow">HUMAN-IN-THE-LOOP SAFETY</span><h2>Observe, ask, confirm.</h2></div><ul><li v-for="item in mode.cautions" :key="item">{{ item }}</li></ul></div>
  </section>
</template>
