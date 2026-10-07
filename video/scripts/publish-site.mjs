// Renders the landing-page videos into site/media (committed): demo.mp4 for
// the Chinese page, demo-en.mp4 for the English one, each with its index
// moved to the front so browsers can start playing before the whole file
// arrives, and a poster (Demo*Poster) next to it.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const media = path.resolve(root, "../site/media");
fs.mkdirSync(media, { recursive: true });
const run = (cmd, args) => execFileSync(cmd, args, { cwd: root, stdio: "inherit" });

for (const [id, name] of [["Demo", "demo"], ["DemoEn", "demo-en"]]) {
  const raw = path.join(root, `out/site-${name}.mp4`);
  run("npx", ["remotion", "render", "src/index.ts", id, raw]);
  run("ffmpeg", ["-loglevel", "error", "-y", "-i", raw, "-c", "copy", "-movflags", "+faststart",
    path.join(media, `${name}.mp4`)]);
  run("npx", ["remotion", "still", "src/index.ts", `${id}Poster`, path.join(media, `${name}-poster.jpg`),
    "--image-format=jpeg", "--jpeg-quality=85", "--scale=0.5"]);
  console.log(`wrote site/media/${name}.mp4, ${name}-poster.jpg`);
}
