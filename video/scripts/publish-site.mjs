// Copies the rendered video into the landing page (site/media, committed)
// with the index moved to the front so browsers can start playing before the
// whole file arrives, and renders the poster (DemoPoster) next to it.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const media = path.resolve(root, "../site/media");
fs.mkdirSync(media, { recursive: true });

execFileSync("ffmpeg", [
  "-loglevel", "error", "-y", "-i", path.join(root, "out/site.mp4"),
  "-c", "copy", "-movflags", "+faststart", path.join(media, "demo.mp4"),
], { stdio: "inherit" });

execFileSync("npx", [
  "remotion", "still", "src/index.ts", "DemoPoster", path.join(media, "demo-poster.jpg"),
  "--image-format=jpeg", "--jpeg-quality=85", "--scale=0.5",
], { cwd: root, stdio: "inherit" });
console.log("wrote site/media/demo.mp4, site/media/demo-poster.jpg");
