import { Fragment } from "react";
import type React from "react";
import { type CalculateMetadataFunction, Composition, Freeze, Still, staticFile } from "remotion";
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
  const voices = (await optionalJson<VoiceManifest>(`voice/${props.lang}/manifest.json`)) ?? {};
  const { beats, durationInFrames } = buildTimeline(props.lang, voices);
  const snapshots = await replay(beats);
  const music = (await exists("music/bed.mp3")) ? "music/bed.mp3" : null;
  return { durationInFrames, props: { ...props, beats, snapshots, music } };
};

// The landing page poster: the neighbor-key beat just before it fades, with
// the red key and the corrected sentence both on screen. No caption: a
// half sentence frozen on a poster reads as a mistake.
const Poster: React.FC<DemoProps> = (props) => {
  const b = props.beats.find((x) => x.beat.id === "neighbor") ?? props.beats[0];
  return (
    <Freeze frame={b ? b.from + b.durationInFrames - 12 : 0}>
      <Demo {...props} captions={false} />
    </Freeze>
  );
};

const empty = { beats: [], snapshots: [], music: null };
const versions = [
  { suffix: "", props: { lang: "zh", ...empty } },
  { suffix: "En", props: { lang: "en", ...empty } },
] satisfies { suffix: string; props: DemoProps }[];

// Demo, DemoVertical and DemoPoster in Chinese; DemoEn, DemoEnVertical and
// DemoEnPoster in English. Same keys, same decoder output.
export const Root: React.FC = () => (
  <>
    {versions.map(({ suffix, props }) => (
      <Fragment key={suffix}>
        <Composition
          id={`Demo${suffix}`} component={Demo} fps={FPS} width={1920} height={1080}
          durationInFrames={1} defaultProps={props} calculateMetadata={calculateMetadata}
        />
        <Composition
          id={`Demo${suffix}Vertical`} component={Demo} fps={FPS} width={1080} height={1920}
          durationInFrames={1} defaultProps={props} calculateMetadata={calculateMetadata}
        />
        <Still
          id={`Demo${suffix}Poster`} component={Poster} width={1920} height={1080}
          defaultProps={props} calculateMetadata={calculateMetadata}
        />
      </Fragment>
    ))}
  </>
);
