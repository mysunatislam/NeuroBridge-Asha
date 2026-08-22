import type { Gesture } from "./fingerspeak";

export type IntentState = "REST" | "CANDIDATE" | "WAIT_RELEASE";

export type IntentInput = {
  handPresent: boolean;
  gestureId: string | null;
  confidence: number;
  inDistribution: boolean;
};

export type IntentOutput = {
  state: IntentState;
  candidateId: string | null;
  progress: number;
  trigger: Gesture | null;
  reason: "idle" | "holding" | "confirmed" | "release" | "uncertain";
};

export class IntentMachine {
  private state: IntentState = "REST";
  private candidateId: string | null = null;
  private candidateSince = 0;
  private releaseStreak = 0;

  constructor(
    private readonly confidenceThreshold = 0.72,
    private readonly releaseTicks = 5,
  ) {}

  step(input: IntentInput, now: number, gestures: ReadonlyArray<Gesture>): IntentOutput {
    const gesture = gestures.find((item) => item.id === input.gestureId) ?? null;
    const recognized =
      input.handPresent &&
      input.inDistribution &&
      gesture !== null &&
      input.confidence >= this.confidenceThreshold;
    const isRest = !recognized || gesture?.id === "rest";

    if (this.state === "WAIT_RELEASE") {
      this.releaseStreak = isRest ? this.releaseStreak + 1 : 0;
      if (this.releaseStreak >= this.releaseTicks) this.reset();
      return this.output(null, 1, "release");
    }

    if (this.state === "REST") {
      if (!isRest && gesture) {
        this.state = "CANDIDATE";
        this.candidateId = gesture.id;
        this.candidateSince = now;
        return this.output(null, 0, "holding");
      }
      return this.output(null, 0, recognized ? "idle" : "uncertain");
    }

    if (isRest || !gesture || gesture.id !== this.candidateId) {
      this.reset();
      return this.output(null, 0, "uncertain");
    }

    const elapsed = Math.max(0, now - this.candidateSince);
    const progress = Math.min(1, elapsed / gesture.dwellMs);
    if (progress >= 1) {
      this.state = "WAIT_RELEASE";
      this.candidateId = null;
      this.releaseStreak = 0;
      return this.output(gesture, 1, "confirmed");
    }
    return this.output(null, progress, "holding");
  }

  snapshot(): IntentOutput {
    return this.output(null, 0, this.state === "REST" ? "idle" : "holding");
  }

  reset(): void {
    this.state = "REST";
    this.candidateId = null;
    this.candidateSince = 0;
    this.releaseStreak = 0;
  }

  private output(trigger: Gesture | null, progress: number, reason: IntentOutput["reason"]): IntentOutput {
    return { state: this.state, candidateId: this.candidateId, progress, trigger, reason };
  }
}

