<script setup lang="ts">
import { onMounted, onUnmounted } from "vue";
import { RouterView } from "vue-router";
import AppShell from "./components/AppShell.vue";
import { useFingerSpeakStore } from "./stores/fingerspeak";

const store = useFingerSpeakStore();

onMounted(async () => {
  await store.bootstrap();
  store.startConnectivityLoop();
  if ("serviceWorker" in navigator) void navigator.serviceWorker.register("/sw.js");
  window.addEventListener("pagehide", store.endRemoteSession);
});

onUnmounted(() => {
  store.stopConnectivityLoop();
  window.removeEventListener("pagehide", store.endRemoteSession);
});
</script>

<template>
  <AppShell>
    <RouterView v-slot="{ Component, route }">
      <Transition name="route-shift" mode="out-in">
        <component :is="Component" :key="route.path" />
      </Transition>
    </RouterView>
  </AppShell>
</template>
