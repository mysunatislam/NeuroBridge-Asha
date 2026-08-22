# FingerSpeak 2.1 — Asha UI Upgrade

This upgrade keeps the cream + deep-green local-first identity while turning the Vue dashboard into a more dynamic personalized AAC experience.

## Added

- **Asha communication copilot** in the lower-left corner, with assistive actions and a clear patient-confirmation boundary.
- **Ambient animated spline curves** representing gesture → understanding → communication.
- **Context Mode** for Hospital, Home, Classroom, Work, Social, and Custom communication.
- **Live Intent upgrade** with confidence arc, prepared phrase, Speak/Edit/Save actions, and subtle idle breathing.
- **Camera intelligence overlay** showing hand tracking, 21 MediaPipe landmarks, measured local detection time, and on-device privacy status.
- **Smart suggestions** that change with communication context.
- **Sentence Composer** with next-phrase predictions and local speech output.
- **Custom saved phrases** for quick communication.
- **My Communication** settings inside Asha for voice style, speed, language, dominant hand, and gesture sensitivity.
- **Routine Intelligence** presented as a suggestion, never a medical conclusion or autonomous patient request.
- **Calibrate redesign** with animated model-readiness ring, gesture-flow nodes, capture animation, and local-model-ready state.
- **Gesture Health** showing sample-based per-gesture readiness and improvement prompts.
- **Caregiver dashboard upgrade** with confirmed-communication metrics, repeated-request count, false-activation feedback, and a live session activity curve.
- **Route transitions, hover lift, button press/micro-motion, and reduced-motion accessibility support.**

## Safety / product behavior

Asha prepares options but does not speak for the patient without an explicit patient action. Caregiver views continue to distinguish confirmed communication from suggestions. Custom composed phrases remain local and are not automatically synced as gesture events.

## Main new files

- `src/components/AshaCopilot.vue`
- `src/components/AmbientCurves.vue`
- `src/components/ContextSelector.vue`
- `src/components/SmartSuggestions.vue`
- `src/components/SentenceComposer.vue`
- `src/components/GestureHealth.vue`
- `src/stores/copilot.ts`

## Run

```powershell
cd apps\web-vue
npm install
npm run dev
```

For the standalone frontend ZIP:

```powershell
cd FingerSpeak-Vue
npm install
npm run dev
```
