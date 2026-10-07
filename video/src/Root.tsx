import type React from "react";
import { type CalculateMetadataFunction, Composition, staticFile } from "remotion";
import { Demo, type DemoProps } from "./Demo";
import { replay } from "./decoder";
import { buildTimeline, FPS, type VoiceManifest } from "./timeline";

async function optionalJson<T>(path: string): Promise<T | null> {
  try {
    const res = await fetch(staticFile(path));
    return res.ok ? ((await res.json()) as T) : null;
  } catch {
    return null;
  }
}

async function exists(path: string): Promise<boolean> {
  try {
    return (await fetch(staticFile(path), { method: "HEAD" })).ok;
  } catch {
    return false;
  }
}

// Timing depends on the voiceover (if generated), and every frame's text
// comes from replaying the keys through the real decoder.
const calculateMetadata: CalculateMetadataFunction<DemoProps> = async ({ props }) => {
  const voices = (await optionalJson<VoiceManifest>("voice/manifest.json")) ?? {};
  const { beats, durationInFrames } = buildTimeline(voices);
  const snapshots = await replay(beats);
  const music = (await exists("music/bed.mp3")) ? "music/bed.mp3" : null;
  return { durationInFrames, props: { ...props, beats, snapshots, music } };
};

const defaults: DemoProps = { beats: [], snapshots: [], music: null };

export const Root: React.FC = () => (
  <>
    <Composition
      id="Demo" component={Demo} fps={FPS} width={1920} height={1080}
      durationInFrames={1} defaultProps={defaults} calculateMetadata={calculateMetadata}
    />
    <Composition
      id="DemoVertical" component={Demo} fps={FPS} width={1080} height={1920}
      durationInFrames={1} defaultProps={defaults} calculateMetadata={calculateMetadata}
    />
  </>
);
