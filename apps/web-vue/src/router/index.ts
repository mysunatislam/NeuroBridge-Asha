import { createRouter, createWebHistory } from "vue-router";

export const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    { path: "/", name: "welcome", component: () => import("../views/WelcomeView.vue") },
    { path: "/care", name: "care-mode", meta: { mode: "communication" }, component: () => import("../views/ModeHubView.vue") },
    { path: "/autism", name: "autism-mode", meta: { mode: "autism" }, component: () => import("../views/ModeHubView.vue") },
    { path: "/rehab", name: "rehab-mode", meta: { mode: "rehab" }, component: () => import("../views/ModeHubView.vue") },
    { path: "/continuous", name: "continuous-mode", meta: { mode: "continuous" }, component: () => import("../views/ModeHubView.vue") },
    { path: "/wellbeing", name: "wellbeing-mode", meta: { mode: "wellbeing" }, component: () => import("../views/ModeHubView.vue") },
    { path: "/speak", name: "speak", component: () => import("../views/SpeakView.vue") },
    { path: "/calibrate", name: "calibrate", component: () => import("../views/CalibrateView.vue") },
    { path: "/caregiver", name: "caregiver", component: () => import("../views/CaregiverView.vue") },
    { path: "/:pathMatch(.*)*", redirect: "/" },
  ],
});
