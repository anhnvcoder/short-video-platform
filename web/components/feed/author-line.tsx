import Link from "next/link";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";

export type AuthorInfo = { displayName: string; handle: string };

type AuthorLineProps = {
  // Null when the feed came without the author (user-service slow): the line stays empty, as tall as with one.
  author: AuthorInfo | null;
  // Profile link of the author, or null where profiles are out of reach (a guest on the share page).
  href: string | null;
  // "2 ngày trước", already formatted.
  publishedAgo: string | null;
};

// The author's name, @handle and the video's age above the title, over the video (web/design/FeedMobile.dc.html M01).
// The name is the user's own text and is rendered as React text only (WEB-1); <bdi> keeps any right-to-left text in it
// from reordering the handle and the age after it (WEB-18).
export function AuthorLine({ author, href, publishedAgo }: AuthorLineProps) {
  const name = <bdi className="text-base font-semibold break-all">{author?.displayName}</bdi>;
  return (
    <div className="flex min-h-6 flex-wrap items-baseline gap-x-1.5 text-on-media text-shadow-media">
      {author && (
        <>
          {href ? (
            <Link href={href} className={cn("rounded-sm text-on-media hover:underline", focusRing)}>
              {name}
            </Link>
          ) : (
            name
          )}
          <span className="text-sm text-on-media-muted">
            @{author.handle}
            {publishedAgo && ` · ${publishedAgo}`}
          </span>
        </>
      )}
    </div>
  );
}
