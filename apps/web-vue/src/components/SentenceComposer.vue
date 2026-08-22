<script setup lang="ts">
import { nextTick, ref, watch } from "vue";
import { storeToRefs } from "pinia";
import { useCopilotStore } from "../stores/copilot";

const emit = defineEmits<{ speak: [phrase: string] }>();
const copilot = useCopilotStore();
const { composer, nextWords, composerFocusToken } = storeToRefs(copilot);
const input = ref<HTMLInputElement | null>(null);

watch(composerFocusToken, async () => {
  await nextTick();
  input.value?.focus();
});

function speak(): void {
  const phrase = composer.value.trim();
  if (phrase) emit("speak", /[.!?]$/.test(phrase) ? phrase : `${phrase}.`);
}
</script>

<template>
  <section class="sentence-composer">
    <div class="composer-topline">
      <div><span class="eyebrow">COMPOSE</span><strong>Build a sentence</strong></div>
      <button class="composer-reset" @click="copilot.resetComposer">Reset</button>
    </div>
    <div class="composer-input-row">
      <input ref="input" v-model="composer" aria-label="Sentence to speak" @keyup.enter="speak" />
      <button class="speak-sentence" :disabled="!composer.trim()" @click="speak"><span class="wave-mini">▮▯▮</span> Speak sentence</button>
    </div>
    <div class="prediction-row"><small>Asha predicts</small><button v-for="word in nextWords" :key="word" @click="copilot.appendWord(word)">{{ word }}</button></div>
  </section>
</template>
