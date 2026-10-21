// hls.js ships no type declarations for its light build; it is the same Hls class without alternate audio, subtitles,
// DRM and CMCD, so it takes the full build's types. Types only: the code loads the light build alone (hls-loader.ts).
declare module "hls.js/light" {
  import Hls from "hls.js";
  export default Hls;
  export * from "hls.js";
}
