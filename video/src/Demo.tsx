import type React from "react";
import {
  AbsoluteFill, Html5Audio, interpolate, Sequence, spring, staticFile, useCurrentFrame, useVideoConfig,
} from "remotion";
import { C, SANS } from "./theme";
import { Field } from "./Field";
import { KeyStrip } from "./KeyStrip";
import type { Snapshot } from "./decoder";
import { FPS, type TimedBeat } from "./timeline";

export type DemoProps = {
  beats: TimedBeat[];
  snapshots: Snapshot[][];
  music: string | null;
};

export const Demo: React.FC<DemoProps> = ({ beats, snapshots, music }) => {
  const voiced = beats.filter((b) => b.voice);
  // Music sits under the narration: duck it while a line is being spoken.
  const musicVolume = (f: number) => {
    const speaking = voiced.some((b) => f >= b.from && f < b.from + b.voice!.durationSec * FPS);
    return speaking ? 0.08 : 0.22;
  };

  return (
    <AbsoluteFill style={{ background: C.paper, fontFamily: SANS, color: C.ink }}>
      {beats.map((b, i) => (
        <Sequence key={b.beat.id} from={b.from} durationInFrames={b.durationInFrames} name={b.beat.id}>
          {b.beat.keys ? <TypingScene timed={b} snaps={snapshots[i]} /> : <TitleCard timed={b} />}
          <Caption timed={b} />
          {b.voice && <Html5Audio src={staticFile(`voice/${b.voice.file}`)} />}
          {b.strokes.map((s, j) => (
            <Sequence key={j} from={s.frame} durationInFrames={8} layout="none">
              <Html5Audio src={staticFile("sfx/key.wav")} volume={s.label === "Enter" ? 0.5 : 0.3} />
            </Sequence>
          ))}
        </Sequence>
      ))}
      {music && <Html5Audio src={staticFile(music)} volume={musicVolume} />}
    </AbsoluteFill>
  );
};

const TitleCard: React.FC<{ timed: TimedBeat }> = ({ timed }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const enter = spring({ frame, fps, config: { damping: 18 } });
  const exit = interpolate(frame, [timed.durationInFrames - 10, timed.durationInFrames], [1, 0], {
    extrapolateLeft: "clamp", extrapolateRight: "clamp",
  });
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: exit }}>
      <div style={{ fontSize: 120, fontWeight: 700, transform: `translateY(${(1 - enter) * 40}px)`, opacity: enter }}>
        {timed.beat.title}
      </div>
      <div style={{ fontSize: 44, color: C.muted, marginTop: 24, opacity: interpolate(frame, [8, 24], [0, 1], { extrapolateRight: "clamp" }) }}>
        {timed.beat.subtitle}
      </div>
    </AbsoluteFill>
  );
};

const TypingScene: React.FC<{ timed: TimedBeat; snaps: Snapshot[] }> = ({ timed, snaps }) => {
  const frame = useCurrentFrame();
  const { fps, width } = useVideoConfig();
  const typed = timed.strokes.filter((s) => s.frame <= frame).length;
  const enter = spring({ frame, fps, config: { damping: 20 } });
  const exit = interpolate(frame, [timed.durationInFrames - 8, timed.durationInFrames], [1, 0], {
    extrapolateLeft: "clamp", extrapolateRight: "clamp",
  });
  const fontSize = width >= 1500 ? 84 : 72;

  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 64, opacity: exit }}>
      <div
        style={{
          fontSize: 40, fontWeight: 600, color: C.mark, background: C.markBg,
          padding: "8px 28px", borderRadius: 999, opacity: enter, transform: `scale(${0.9 + 0.1 * enter})`,
        }}
      >
        {timed.beat.label}
      </div>
      <div style={{ width: Math.min(1200, width * 0.88), transform: `translateY(${(1 - enter) * 30}px)` }}>
        <Field snap={snaps[typed]} frame={frame} fontSize={fontSize} />
      </div>
      <div style={{ width: Math.min(1400, width * 0.9), minHeight: 90 }}>
        <KeyStrip strokes={timed.strokes} frame={frame} size={width >= 1500 ? 76 : 64} />
      </div>
    </AbsoluteFill>
  );
};

// Narration subtitles: word-timed captions from the voiceover when present,
// otherwise the narration line for the whole beat, so drafts are captioned too.
// Vertical video keeps them clear of the Shorts/Reels overlay at the bottom.
const Caption: React.FC<{ timed: TimedBeat }> = ({ timed }) => {
  const frame = useCurrentFrame();
  const { width, height } = useVideoConfig();
  const t = frame / FPS;
  const text = timed.voice
    ? timed.voice.captions.find((c) => t >= c.startSec && t < c.endSec + 0.25)?.text
    : timed.beat.narration;
  if (!text) return null;
  return (
    <AbsoluteFill style={{ justifyContent: "flex-end", alignItems: "center", paddingBottom: height > width ? 360 : 72 }}>
      <div
        style={{
          fontSize: 44, color: "#fff", background: "rgba(38,44,52,.82)",
          padding: "10px 28px", borderRadius: 12, maxWidth: "86%", textAlign: "center",
        }}
      >
        {text}
      </div>
    </AbsoluteFill>
  );
};
