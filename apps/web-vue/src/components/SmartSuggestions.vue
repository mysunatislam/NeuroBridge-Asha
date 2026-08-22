<script setup lang="ts">
defineProps<{ suggestions: string[] }>();
const emit = defineEmits<{ select: [phrase: string] }>();
</script>

<template>
  <section class="smart-suggestions" aria-label="Smart communication suggestions">
    <div class="micro-heading"><span>✦</span><strong>Smart suggestions</strong><small>context-aware · patient confirms</small></div>
    <div class="suggestion-chips">
      <button v-for="phrase in suggestions.slice(0, 4)" :key="phrase" @click="emit('select', phrase)">{{ phrase }}</button>
    </div>
  </section>
</template>
