<script setup lang="ts">
import type { CommunicationContext } from "../stores/copilot";

defineProps<{ modelValue: CommunicationContext }>();
const emit = defineEmits<{ "update:modelValue": [value: CommunicationContext] }>();
const contexts: CommunicationContext[] = ["Hospital", "Home", "Classroom", "Work", "Social", "Custom"];
</script>

<template>
  <label class="context-selector">
    <span>Context</span>
    <select :value="modelValue" @change="emit('update:modelValue', ($event.target as HTMLSelectElement).value as CommunicationContext)">
      <option v-for="item in contexts" :key="item" :value="item">{{ item }}</option>
    </select>
  </label>
</template>
