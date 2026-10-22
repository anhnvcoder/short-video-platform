import { ChevronLeft, Share, UserCheck, UserPlus } from "lucide-react";
import { useTranslations } from "next-intl";
import { Avatar, Button, IconButton } from "@/components/ui";
import { cn } from "@/lib/cn";

type ProfileHeaderProps = {
  userId: string;
  handle: string;
  // The user's own text, rendered as React text only (WEB-1).
  displayName: string;
  following: boolean;
  // A follow change is on its way, or a rate limit runs.
  followDisabled: boolean;
  onToggleFollow: () => void;
  onCopyLink: () => void;
  onBack: () => void;
};

// Top of another user's profile (web/design/SVP Mobile.dc.html M35–M37; SVP Desktop.dc.html D10): on a phone a bar
// with back, @handle and copy link above the avatar, name and a full-width follow button; on a wide screen one row.
// The follow button is a toggle: aria-pressed says whether the user is followed, the label and icon say it too.
export function ProfileHeader({
  userId,
  handle,
  displayName,
  following,
  followDisabled,
  onToggleFollow,
  onCopyLink,
  onBack,
}: ProfileHeaderProps) {
  const t = useTranslations("profile.other");
  const copy = (className?: string) => (
    <IconButton
      label={t("copyLink")}
      icon={<Share aria-hidden="true" size={20} />}
      onClick={onCopyLink}
      className={className}
    />
  );
  return (
    <>
      <div className="relative flex h-14 shrink-0 items-center justify-center md:hidden">
        <IconButton
          label={t("back")}
          icon={<ChevronLeft aria-hidden="true" size={24} />}
          onClick={onBack}
          className="absolute top-1.5 left-1"
        />
        <span className="text-base font-semibold">@{handle}</span>
        {copy("absolute top-1.5 right-1")}
      </div>
      <div className="grid grid-cols-[auto_minmax(0,1fr)] items-center gap-x-4.5 gap-y-4 px-4 pt-2 pb-5 md:flex md:w-full md:max-w-240 md:gap-6 md:p-0">
        <Avatar seed={userId} name={displayName} className="size-20 text-[34px] md:size-26 md:text-[40px]" />
        <div className="flex min-w-0 flex-col gap-0.5 md:flex-1 md:gap-1">
          {/* <bdi>: right-to-left text in the name does not reorder what follows it (WEB-18). */}
          <h1 className="text-[22px] font-bold break-all md:text-[28px]">
            <bdi>{displayName}</bdi>
          </h1>
          <span className="text-[15px] text-muted md:text-base">@{handle}</span>
        </div>
        <Button
          variant={following ? "secondary" : "primary"}
          aria-pressed={following}
          disabled={followDisabled}
          onClick={onToggleFollow}
          className={cn("col-span-full w-full md:min-h-12 md:w-auto md:px-6", following && "bg-surface-raised")}
        >
          {following ? <UserCheck aria-hidden="true" size={18} /> : <UserPlus aria-hidden="true" size={18} />}
          {following ? t("following") : t("follow")}
        </Button>
        {copy("hidden size-12 rounded-md border border-border-strong md:inline-flex")}
      </div>
    </>
  );
}
