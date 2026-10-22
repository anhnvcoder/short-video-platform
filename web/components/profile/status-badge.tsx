import { Check, CircleAlert, LoaderCircle, Upload, type LucideIcon } from "lucide-react";
import { useTranslations } from "next-intl";
import type { VideoStatus } from "@/features/profile/api";
import { cn } from "@/lib/cn";

// Literal class names, so Tailwind finds them.
const looks: Record<VideoStatus, { Icon: LucideIcon; tone: string }> = {
  UPLOADING: { Icon: Upload, tone: "bg-info-surface text-info" },
  PROCESSING: { Icon: LoaderCircle, tone: "bg-warning-surface text-warning" },
  READY: { Icon: Check, tone: "bg-success-surface text-success" },
  FAILED: { Icon: CircleAlert, tone: "bg-danger-surface text-danger" },
};

// The state of one of the user's videos (web/design/SVP Mobile.dc.html M33): an icon and a word as well as a color, so
// it does not rely on color alone.
export function StatusBadge({ status, className }: { status: VideoStatus; className?: string }) {
  const t = useTranslations("profile.status");
  const { Icon, tone } = looks[status];
  return (
    <span
      className={cn(
        "inline-flex h-6 items-center gap-1.5 self-start rounded-full px-2.5 text-xs font-semibold md:h-6.5",
        tone,
        className,
      )}
    >
      <Icon aria-hidden="true" size={13} />
      {t(status)}
    </span>
  );
}
