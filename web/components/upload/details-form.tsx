"use client";

import { ArrowUp, CircleAlert, RefreshCw } from "lucide-react";
import { useTranslations } from "next-intl";
import { useId, type FormEvent, type ReactNode } from "react";
import { Button } from "@/components/ui";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";

// Step 2 (M25, M26): the chosen file and the title, then "Post video".

type DetailsFormProps = {
  fileName: string;
  // "19,2 MB · 0:42", or the size alone when the duration could not be read.
  fileMeta: string;
  // m:ss on the thumbnail, when known.
  duration: string | null;
  title: string;
  onTitleChange: (title: string) => void;
  // Characters counted the way the server counts them.
  titleLength: number;
  maxTitleLength: number;
  titleError: string | null;
  onChangeFile: () => void;
  onSubmit: () => void;
  // The upload form is being asked for, or waited for before asking again: "Post video" stays busy and the title is
  // read-only, because the upload already took the title given at "Post video" and a later edit would be dropped.
  submitting: boolean;
  // A request for the form is on its way. It may create a video, which takes one of the user's upload slots, so the
  // file cannot be changed until it answers.
  requesting: boolean;
  // An alert above the file (a failed or cancelled upload, a wait before the form).
  alert?: ReactNode;
};

export function DetailsForm({
  fileName,
  fileMeta,
  duration,
  title,
  onTitleChange,
  titleLength,
  maxTitleLength,
  titleError,
  onChangeFile,
  onSubmit,
  submitting,
  requesting,
  alert,
}: DetailsFormProps) {
  const t = useTranslations("upload.details");
  const id = useId();
  const noteId = `${id}-note`;

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    onSubmit();
  }

  return (
    <form noValidate onSubmit={submit} className="flex flex-1 flex-col gap-4">
      {alert}
      <div className="flex items-start gap-4">
        {/* A plain placeholder: the file is not decoded here. */}
        <div
          aria-hidden="true"
          className="relative h-46 w-26 flex-none overflow-hidden rounded-md bg-[repeating-linear-gradient(135deg,oklch(0.31_0.035_50)_0_12px,oklch(0.27_0.035_50)_12px_24px)]"
        >
          {duration && (
            <span className="absolute right-1.5 bottom-1.5 rounded-[6px] bg-[oklch(0_0_0/0.65)] px-1.5 py-0.5 font-mono text-xs font-medium text-on-media">
              {duration}
            </span>
          )}
        </div>
        <div className="flex min-w-0 flex-1 flex-col gap-1 pt-1">
          <strong className="text-[15px] font-semibold wrap-anywhere">{fileName}</strong>
          <span className="text-sm text-muted">{fileMeta}</span>
          <button
            type="button"
            onClick={onChangeFile}
            disabled={requesting}
            className={cn(
              "flex min-h-11 items-center gap-1.5 self-start text-sm font-semibold text-accent-text disabled:opacity-60",
              focusRing,
            )}
          >
            <RefreshCw aria-hidden="true" size={16} />
            {t("change")}
          </button>
        </div>
      </div>
      <div className="flex flex-col gap-2">
        <label htmlFor={id} className="text-sm font-semibold">
          {t("titleLabel")} <span className="font-normal text-muted">{t("required")}</span>
        </label>
        <textarea
          id={id}
          name="title"
          value={title}
          onChange={(event) => onTitleChange(event.currentTarget.value)}
          readOnly={submitting}
          placeholder={t("titlePlaceholder")}
          aria-invalid={titleError ? true : undefined}
          aria-describedby={noteId}
          rows={3}
          className={cn(
            "min-h-28 resize-none rounded-md bg-surface-raised px-3.5 py-3 text-base leading-normal text-foreground outline-none placeholder:text-muted focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-surface",
            titleError ? "border-2 border-danger" : "border border-border-strong",
          )}
        />
        <div className="flex justify-between gap-3 text-[13px] leading-[1.4]">
          {titleError ? (
            <span id={noteId} className="flex gap-1.5 text-danger">
              <CircleAlert aria-hidden="true" size={15} className="mt-px flex-none" />
              {titleError}
            </span>
          ) : (
            <span id={noteId} className="text-muted">
              {t("titleHint")}
            </span>
          )}
          <span className={cn("font-mono text-xs", titleLength > maxTitleLength ? "text-danger" : "text-muted")}>
            {titleLength}/{maxTitleLength}
          </span>
        </div>
      </div>
      <div className="mt-auto">
        <Button type="submit" size="lg" loading={submitting} className="w-full">
          {!submitting && <ArrowUp aria-hidden="true" size={18} />}
          {submitting ? t("submitting") : t("submit")}
        </Button>
      </div>
    </form>
  );
}
