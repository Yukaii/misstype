import type React from "react";
import { spring, useVideoConfig } from "remotion";
import { C, SANS } from "./theme";
import type { Stroke } from "./timeline";

const shown: Record<string, string> = { Enter: "⏎", Space: "␣", Down: "↓", Backspace: "⌫" };

// The keys typed so far in this beat; keys marked [..] in story.json are the
// mistakes and stay red.
export const KeyStrip: React.FC<{ strokes: Stroke[]; frame: number; size: number }> = ({ strokes, frame, size }) => {
  const { fps } = useVideoConfig();
  return (
    <div style={{ display: "flex", flexWrap: "wrap", justifyContent: "center", gap: size * 0.18 }}>
      {strokes
        .filter((s) => s.frame <= frame)
        .map((s, i) => {
          const pop = spring({ frame: frame - s.frame, fps, config: { damping: 14, stiffness: 220 } });
          return (
            <span
              key={i}
              style={{
                fontFamily: SANS, fontSize: size * 0.55, width: size, height: size,
                display: "inline-flex", alignItems: "center", justifyContent: "center",
                borderRadius: size * 0.18,
                background: s.typo ? C.markBg : C.card,
                color: s.typo ? C.mark : C.ink,
                border: `2px solid ${s.typo ? C.mark : C.line}`,
                boxShadow: `0 ${size * 0.06}px 0 ${s.typo ? C.mark : C.line}`,
                transform: `translateY(${(1 - pop) * size * 0.3}px) scale(${0.7 + 0.3 * pop})`,
                opacity: pop,
              }}
            >
              {shown[s.label] ?? s.label}
            </span>
          );
        })}
    </div>
  );
};
