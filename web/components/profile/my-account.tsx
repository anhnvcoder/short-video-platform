import { LogOut, Plus } from "lucide-react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import type { ReactNode } from "react";
import { LogoutForm } from "@/components/shell/logout-form";
import { Avatar, IconButton } from "@/components/ui";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";

type MyAccountProps = {
  userId: string;
  // Null when GET /me did not answer: the avatar alone shows.
  account: { displayName: string; handle: string } | null;
  // The display name form, under the account.
  children?: ReactNode;
};

// Top of "My videos" (web/design/SVP Mobile.dc.html M33–M34; SVP Desktop.dc.html D09). On a phone a bar with the title
// and log out: the bottom bar has no log out, so this page must. On a wide screen the side bar has it, and the account
// row gets the upload link instead.
export function MyAccount({ userId, account, children }: MyAccountProps) {
  const t = useTranslations("profile.my");
  return (
    <>
      <header className="flex h-14 shrink-0 items-center justify-between pr-1 pl-4 md:h-auto md:p-0">
        {/* The page's heading on every screen; a wide screen shows the account name in its place. */}
        <h1 className="text-xl font-bold md:sr-only">{t("title")}</h1>
        {/* A POST form, so logging out works without JavaScript and no link can trigger it. */}
        <LogoutForm className="md:hidden">
          <IconButton type="submit" tone="muted" label={t("logout")} icon={<LogOut aria-hidden="true" size={20} />} />
        </LogoutForm>
      </header>
      <div className="flex flex-col gap-3 border-b border-border px-4 pt-1 pb-4 md:border-0 md:p-0">
        <div className="flex items-center gap-3.5 md:gap-4.5">
          <Avatar seed={userId} name={account?.displayName} className="size-14 text-[22px] md:size-18 md:text-[28px]" />
          <div className="flex min-w-0 flex-1 flex-col gap-0.5">
            {account && (
              <>
                {/* <bdi>: right-to-left text in the name does not reorder what follows it (WEB-18). */}
                <strong className="text-[17px] font-semibold break-all md:text-2xl md:font-bold">
                  <bdi>{account.displayName}</bdi>
                </strong>
                <span className="text-sm text-muted md:text-[15px]">@{account.handle}</span>
              </>
            )}
          </div>
          <Link
            href="/upload"
            className={cn(
              "hidden min-h-12 items-center gap-2 rounded-md bg-accent px-5 text-[15px] font-semibold text-accent-foreground hover:bg-accent-hover hover:text-accent-foreground md:inline-flex",
              focusRing,
            )}
          >
            <Plus aria-hidden="true" size={18} />
            {t("upload")}
          </Link>
        </div>
        {children}
      </div>
    </>
  );
}
