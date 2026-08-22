# Asha 2.4 — Multimode + Multimodal Assist

## Experience
- New first page asks why FingerSpeak is being used and routes into five dedicated modes: Communication & Care, Autism Support, Rehabilitation Coach, Continuous Support, and Emotional/Psychiatric Support.
- Bright and dark themes now share a glowing/glitter visual system and can be switched from the persistent top bar.
- Asha stays available at bottom-right on every page.
- English and Bangla are global choices.
- Female and male browser voices are both supported and selectable. The exact installed voice still depends on the device/browser.
- Mode pages speak their introduction automatically when the browser permits speech and always provide a manual “Hear this mode” control.

## Vision
- MediaPipe HandLandmarker is configured for two hands (`numHands: 2`).
- Left/right hands are tracked simultaneously and can each produce a personalized gesture prediction.
- A safety selector sends only the strongest confirmed gesture into the existing dwell/release intent machine to prevent simultaneous accidental speech.
- Optional FaceLandmarker processing adds face presence, head direction, blink/gaze direction, rapid gaze-change observation, smile-like, sadness-like, discomfort-like, and distress-like cues.
- Face/head/eye cues do not directly trigger an emergency action or spoken patient intent.

## Safety language
- “Pain” means a possible discomfort-like facial cue that must be confirmed by the person/caregiver.
- “Crying” means possible distress/cry-like expression; a normal camera cannot verify tears reliably.
- “Rapid eye movement” is implemented as rapid visible gaze change, not REM-sleep detection.
- Continuous Support is not a coma/consciousness detector and is not a replacement for vital-sign monitoring or bedside clinical observation.
- Psychiatric support cues are supportive prompts, not mental-health diagnoses.

## Face model
The hand model remains bundled at `/models/hand_landmarker.task`. The FaceLandmarker task model defaults to the official hosted MediaPipe model URL so the feature can work without enlarging this archive further. You can self-host the model and set:

```bash
VITE_FACE_LANDMARKER_URL=/models/face_landmarker.task
```

Inference stays in the browser after the task model is loaded; raw camera frames are not intentionally uploaded by FingerSpeak.
