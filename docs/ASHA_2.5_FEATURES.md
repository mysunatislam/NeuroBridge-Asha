# Asha 2.5 — Illustrated Avatar + Bangla Voice

This update keeps the 2.4 multimodal/care-mode prototype and adds two presentation-facing improvements.

- Replaced the CSS-drawn Asha face in the welcome page, copilot panel, and floating orb with the supplied illustrated hospital-support avatar.
- Added optimized WebP assets at `public/asha-avatar.webp` (full illustration) and `public/asha-avatar-face.webp` (copilot crop) for faster loading and clearer small avatars.
- Strengthened bilingual Web Speech voice selection: Bangla uses `bn-BD`, English uses `en-US`, and Asha now avoids forcing a wrong-language installed voice.
- Added native voice availability feedback in the Asha language switcher.
- Localized female/male voice-selection confirmations into Bangla.
- Added Bangla speech for the built-in Yes, No, Water, Nurse, and Emergency gesture intents when Bangla is selected.
- Existing Bangla Asha prompts, empathy check-ins, exercise guidance, hydration reminders, and care-mode introductions remain active.

## Browser note

Voice quality depends on the voices installed by the browser/operating system. Chrome/Edge on a device with a Bengali voice will use it directly; otherwise the utterance is still tagged `bn-BD` so the platform can choose its best Bengali fallback.
