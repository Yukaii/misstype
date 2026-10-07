import { Config } from "@remotion/cli/config";

// Each worker tab is a full Chromium page; keep it modest on a laptop.
Config.setConcurrency(4);
Config.setVideoImageFormat("jpeg");
Config.setJpegQuality(92);
