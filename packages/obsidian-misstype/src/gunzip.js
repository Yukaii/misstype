/** Inflates gzip bytes with the platform's DecompressionStream (Electron, iOS 16.4+, Android WebView). */
export async function gunzip(bytes) {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}
