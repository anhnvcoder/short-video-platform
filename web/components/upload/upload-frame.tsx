import { X } from "lucide-react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import type { ReactNode } from "react";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";

// Frame of the upload flow (web/design/UploadFlow.dc.html): a close button, the title, the three steps, then the step's
// content. Full screen on a phone; a 560 px card in the middle of the page on a wide screen (D05, D06).

export type UploadStep = 1 | 2 | 3;

const stepKeys = ["pick", "details", "publish"] as const;

export function UploadFrame({ step, children }: { step: UploadStep; children: ReactNode }) {
  const t = useTranslations("upload");
  return (
    <div className="flex h-full overflow-y-auto md:items-center md:justify-center md:p-6">
      <section
        aria-labelledby="upload-title"
        className="flex min-h-full w-full flex-col bg-surface text-foreground md:h-[min(800px,100%)] md:min-h-0 md:max-w-140 md:overflow-y-auto md:rounded-[20px] md:border md:border-border"
      >
        <header className="relative flex h-14 flex-none items-center justify-center px-4">
          <Link
            href="/"
            aria-label={t("close")}
            className={cn(
              "absolute top-1.5 left-1 flex size-11 items-center justify-center rounded-full text-foreground hover:bg-surface-hover hover:text-foreground",
              focusRing,
            )}
          >
            <X aria-hidden="true" size={22} />
          </Link>
          <h1 id="upload-title" className="text-[17px] font-semibold">
            {t("title")}
          </h1>
          <span className="absolute right-4 text-[13px] text-muted">{t("stepOf", { step })}</span>
        </header>
        <ol aria-label={t("steps.label")} className="grid grid-cols-3 gap-1.5 px-5 pt-1">
          {stepKeys.map((key, index) => {
            const number = index + 1;
            const current = number === step;
            return (
              <li key={key} aria-current={current ? "step" : undefined} className="flex flex-col gap-1.5">
                <span className={cn("h-1 rounded", number <= step ? "bg-accent" : "bg-border-strong")} />
                <span className={cn("text-xs", current ? "font-semibold text-foreground" : "text-muted")}>
                  {t(`steps.${key}`)}
                </span>
              </li>
            );
          })}
        </ol>
        <div className="flex min-h-0 flex-1 flex-col gap-4 p-5">{children}</div>
      </section>
    </div>
  );
}
