import type React from "react";
import { C, MONO } from "./theme";
import type { Snapshot } from "./decoder";

// The playground's text box (site/playground.js render()), drawn from a
// recorded decoder snapshot instead of live DOM editing.
export const Field: React.FC<{ snap: Snapshot; frame: number; fontSize: number }> = ({ snap, frame, fontSize }) => {
  const caretOn = Math.floor(frame / 16) % 2 === 0;
  const caret = (
    <span style={{ position: "relative", display: "inline-block", width: 0 }}>
      <span
        style={{
          display: "inline-block", height: "1.1em", verticalAlign: "-0.15em",
          borderLeft: `${Math.max(2, fontSize / 24)}px solid ${C.ink}`,
          opacity: caretOn || snap.preedit ? 1 : 0,
        }}
      />
      {snap.candidates.length > 0 && <Candidates snap={snap} fontSize={fontSize} />}
    </span>
  );

  const preedit = snap.segments.map(([start, end], i) => {
    const text = snap.preedit.slice(start, end);
    const focused = snap.focus && snap.focus[0] === start && snap.focus[1] === end;
    const inside = snap.caret >= start && (snap.caret < end || (snap.caret === end && end === snap.preedit.length));
    const cut = snap.caret - start;
    return (
      <span
        key={i}
        style={{ borderBottom: `${fontSize / 20}px solid ${focused ? C.mark : C.ink}`, paddingBottom: 2 }}
      >
        {inside ? (
          <>
            {text.slice(0, cut)}
            {caret}
            {text.slice(cut)}
          </>
        ) : (
          text
        )}
      </span>
    );
  });

  return (
    <div
      style={{
        background: C.card, border: `2px solid ${C.ink}`, borderRadius: 18,
        padding: `${fontSize * 0.45}px ${fontSize * 0.6}px`, minHeight: fontSize * 1.9,
        fontSize, lineHeight: 1.5, color: C.ink, whiteSpace: "pre-wrap",
      }}
    >
      {snap.committed}
      {snap.preedit ? preedit : caret}
    </div>
  );
};

const Candidates: React.FC<{ snap: Snapshot; fontSize: number }> = ({ snap, fontSize }) => {
  const size = fontSize * 0.42;
  return (
    <div
      style={{
        position: "absolute", top: "1.35em", left: 0, zIndex: 2, width: size * 9,
        background: "rgba(255,255,255,.98)", border: "1px solid rgba(0,0,0,.14)", borderRadius: 12,
        boxShadow: "0 18px 48px rgba(0,0,0,.16), 0 3px 9px rgba(0,0,0,.08)", padding: 8,
        fontSize: size, lineHeight: 1.4,
      }}
    >
      {snap.candidates.map((cand, i) => (
        <div
          key={i}
          style={{
            display: "flex", justifyContent: "space-between", alignItems: "center",
            padding: `${size * 0.25}px ${size * 0.5}px`, borderRadius: 8,
            background: i === snap.selected ? C.highlight : "transparent",
          }}
        >
          <span style={{ fontWeight: 500 }}>{cand}</span>
          {snap.keysActive && (
            <span style={{ fontFamily: MONO, fontSize: size * 0.6, color: C.muted }}>
              {(snap.selectionKeys[i] ?? `${i + 1}`).toUpperCase()}
            </span>
          )}
        </div>
      ))}
    </div>
  );
};
