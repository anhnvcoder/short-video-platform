// hls.js is loaded on first use, never in the page's first bundle, and only its light build (no alternate audio,
// subtitles, DRM or CMCD, which these clips do not use).

export type HlsClass = (typeof import("hls.js/light"))["default"];
export type HlsInstance = InstanceType<HlsClass>;
export type HlsConfig = NonNullable<ConstructorParameters<HlsClass>[0]>;

let loading: Promise<HlsClass> | undefined;

export function loadHls(): Promise<HlsClass> {
  loading ??= import("hls.js/light").then(
    (module) => module.default,
    (error: unknown) => {
      // A failed chunk download is tried again on the next video.
      loading = undefined;
      throw error;
    },
  );
  return loading;
}
