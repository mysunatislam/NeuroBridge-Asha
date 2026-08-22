# FingerSpeak + Asha 2.2

## What changed

- Milo is renamed to **Asha** throughout the Vue interface.
- Asha is fixed to the **bottom-right** and periodically surfaces small proactive prompts.
- New animated Asha avatar with blinking eyes, mood expression changes, glow, pulse, and live status.
- English / বাংলা language toggle with browser SpeechSynthesis support (`en-US` / `bn-BD`).
- Asha guides users to calibration: **“Turn your camera on to calibrate.”**
- Contextual **“What do you need right now?”** communication assistance.
- Voice-only **Exercise Assistant** with gentle neck movement instructions, pause, repeat, and progress.
- Local one-hour **hydration reminder** with “I drank water” reset.
- Wellbeing cue demo for Smile / Sad / Pain / Okay. Sad or pain cues ask before escalating.
- Explicit **“Do you need me to call somebody?”** confirmation flow.
- Optional trusted-contact name and phone number. On supported mobile browsers, confirmed calls use a `tel:` handoff.
- Asha never automatically calls and wellbeing cues are not presented as emotion or pain diagnoses.

## Run

```bash
npm install
npm run dev
```

Open `http://localhost:3000`.

## Presentation demo

1. Open Asha from the bottom-right.
2. Switch between **EN** and **বাংলা** and use **Test Asha voice** in Settings.
3. Tap **Turn your camera on to calibrate** to jump to the gesture calibration flow.
4. Return to Speak and show **What do you need right now?** + contextual suggestions.
5. Open **Exercise assistant** and start the voice routine.
6. Use the Smile / Sad / Pain cue buttons to demonstrate Asha's supportive response and confirmation-first call flow.
7. Add a trusted mobile number in Settings to demonstrate the `tel:` handoff on a phone.
