import { Play } from "lucide-react";
import Link from "next/link";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";

export type GridVideo = {
  id: string;
  // The share page, /v/<id>.
  href: string;
  // The user's own text, already given a fallback when empty: read out first in the tile's accessible name.
  title: string;
  // On MEDIA_ORIGIN, checked by the caller.
  thumbnailUrl: string | null;
  // "8,3 N", or null without stats.
  views: string | null;
  // "0:58".
  duration: string | null;
};

// Another user's READY videos (web/design/SVP Mobile.dc.html M35–M36; SVP Desktop.dc.html D10): 3 columns on a phone,
// 6 on a wide screen, each tile a link to the video with its views and length over a shade at the bottom. The link is
// named by its content: the title, for screen readers only, then the views and length it shows. An aria-label would
// hide the shown text from the name (WCAG 2.5.3, axe's label-content-name-mismatch), and a voice user who says what
// they see would not reach the tile.
export function VideoGrid({ label, videos }: { label: string; videos: readonly GridVideo[] }) {
  return (
    <ul
      aria-label={label}
      className="grid w-full grid-cols-3 content-start gap-0.5 md:max-w-240 md:grid-cols-6 md:gap-2"
    >
      {videos.map((video) => (
        <li key={video.id}>
          <Link
            href={video.href}
            className={cn(
              "relative block aspect-9/16 overflow-hidden bg-skeleton text-on-media hover:text-on-media md:rounded-[10px]",
              focusRing,
            )}
          >
            {video.thumbnailUrl && (
              // A plain <img>: next/image always writes a style attribute, which the CSP (no 'unsafe-inline') blocks.
              // eslint-disable-next-line @next/next/no-img-element
              <img src={video.thumbnailUrl} alt="" className="absolute inset-0 size-full object-cover" />
            )}
            {/* The commas keep the parts apart when a screen reader reads the name in one go. */}
            <span className="sr-only">{video.views !== null || video.duration ? `${video.title}, ` : video.title}</span>
            <span className="absolute inset-x-0 bottom-0 h-1/2 bg-linear-to-t from-[oklch(0_0_0/0.7)] to-transparent" />
            <span className="absolute inset-x-1.5 bottom-1.5 flex items-center justify-between text-xs font-semibold md:inset-x-2 md:bottom-2 md:text-[13px]">
              {video.views !== null && (
                <span className="flex items-center gap-0.75">
                  <Play aria-hidden="true" size={12} fill="currentColor" />
                  {video.views}
                  {video.duration && <span className="sr-only">, </span>}
                </span>
              )}
              {video.duration && <span className="ml-auto font-mono font-medium">{video.duration}</span>}
            </span>
          </Link>
        </li>
      ))}
    </ul>
  );
}
