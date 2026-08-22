<script setup lang="ts">
import { onMounted } from "vue";
import { useRouter } from "vue-router";
import { storeToRefs } from "pinia";
import { CARE_MODES } from "../lib/care-modes";
import { useCopilotStore, type AshaLanguage, type VoiceGender, type CareMode } from "../stores/copilot";
import { speakAsha } from "../lib/asha-voice";

const router = useRouter();
const copilot = useCopilotStore();
const { language, voiceGender, theme } = storeToRefs(copilot);

function speak(text: string): void { speakAsha(text, { language: language.value, gender: voiceGender.value, speed: copilot.speakingSpeed, style: copilot.preferredVoice }); }
function askPurpose(): void {
  speak(language.value === "Bangla"
    ? "ফিঙ্গারস্পিক কোন উদ্দেশ্যে ব্যবহার করতে চান? কেয়ার, অটিজম সাপোর্ট, রিহ্যাবিলিটেশন, কন্টিনিউয়াস সাপোর্ট, অথবা ইমোশনাল সাপোর্ট থেকে একটি বেছে নিন।"
    : "What would you like to use FingerSpeak for? Choose communication and care, autism support, rehabilitation, continuous support, or emotional support.");
}
function setLanguage(next: AshaLanguage): void { copilot.setLanguage(next); askPurpose(); }
function setGender(next: VoiceGender): void {
  voiceGender.value = next;
  speak(language.value === "Bangla"
    ? (next === "Female" ? "নারী কণ্ঠ নির্বাচন করা হয়েছে।" : "পুরুষ কণ্ঠ নির্বাচন করা হয়েছে।")
    : (next === "Female" ? "Female voice selected." : "Male voice selected."));
}
async function chooseMode(id: CareMode, path: string): Promise<void> {
  copilot.setCareMode(id);
  const mode = CARE_MODES.find((item) => item.id === id)!;
  speak(mode.voicePrompt[language.value]);
  await router.push(path);
}

onMounted(() => window.setTimeout(askPurpose, 350));
</script>

<template>
  <section class="welcome-page">
    <div class="glitter-field" aria-hidden="true"><i v-for="n in 24" :key="n" /></div>
    <div class="welcome-hero">
      <div class="welcome-copy">
        <span class="eyebrow">FINGERSPEAK · ASHA MULTIMODAL ASSIST</span>
        <h1>How should Asha support you today?</h1>
        <p>Choose a purpose first. FingerSpeak will reshape its prompts, pages and assistance around that situation.</p>
        <div class="welcome-controls">
          <div class="segmented-control"><span>Language</span><button :class="{ active: language === 'English' }" @click="setLanguage('English')">English</button><button :class="{ active: language === 'Bangla' }" @click="setLanguage('Bangla')">বাংলা</button></div>
          <div class="segmented-control"><span>Voice</span><button :class="{ active: voiceGender === 'Female' }" @click="setGender('Female')">♀ Female</button><button :class="{ active: voiceGender === 'Male' }" @click="setGender('Male')">♂ Male</button></div>
          <button class="voice-question" @click="askPurpose">🔊 Ask me aloud</button>
        </div>
      </div>
      <div class="welcome-asha" aria-label="Asha, your assistive copilot">
        <div class="asha-portrait-large">
          <img src="/asha-avatar.webp" alt="Asha, the FingerSpeak hospital-support avatar" />
          <em>✦</em>
        </div>
        <div><small>ASHA · READY</small><strong>{{ language === 'Bangla' ? 'আমি আপনার সাথে আছি।' : 'I’m right here with you.' }}</strong><p>{{ voiceGender }} · {{ language }} · {{ theme === 'dark' ? 'Dark glow' : 'Bright glow' }}</p></div>
      </div>
    </div>

    <div class="purpose-heading"><div><span class="eyebrow">CHOOSE YOUR FINGERSPEAK MODE</span><h2>One system, different kinds of support.</h2></div><small>Every mode keeps Asha available in the bottom-right corner.</small></div>
    <div class="purpose-grid">
      <button v-for="mode in CARE_MODES" :key="mode.id" class="purpose-card" @mouseenter="speak(mode.title)" @click="chooseMode(mode.id, mode.path)">
        <span class="purpose-icon">{{ mode.icon }}</span>
        <span class="purpose-number">0{{ CARE_MODES.indexOf(mode) + 1 }}</span>
        <strong>{{ mode.title }}</strong>
        <small>{{ mode.short }}</small>
        <p>{{ mode.audience }}</p>
        <b>Open mode →</b>
      </button>
    </div>
    <p class="welcome-safety">Camera-based facial, eye and pain-like cues are assistive observations only. FingerSpeak does not diagnose pain, autism, psychiatric conditions, consciousness or medical emergencies.</p>
  </section>
</template>
