"use client";

import { ArrowDownToLine, FolderOpen, Upload } from "lucide-react";
import { useTranslations } from "next-intl";
import { useRef, useState, type DragEvent } from "react";
import { Button } from "@/components/ui";
import { cn } from "@/lib/cn";

// Step 1 (M20, D05, D06): a button that opens the file picker and, on a wide screen, a zone a file can be dropped on.
// Only the first file of a drop or a pick is taken.

type DropZoneProps = {
  onFile: (file: File) => void;
  // The chosen file is being checked (its duration is read).
  checking: boolean;
};

export function DropZone({ onFile, checking }: DropZoneProps) {
  const t = useTranslations("upload.pick");
  const input = useRef<HTMLInputElement>(null);
  const [dragging, setDragging] = useState(false);

  function take(files: FileList | null) {
    const file = files?.[0];
    if (file) {
      onFile(file);
    }
  }

  function dragOver(event: DragEvent<HTMLDivElement>) {
    if (!event.dataTransfer.types.includes("Files")) {
      return;
    }
    // Without this the browser opens the dropped file instead of handing it to the page.
    event.preventDefault();
    event.dataTransfer.dropEffect = "copy";
    setDragging(true);
  }

  function dragLeave(event: DragEvent<HTMLDivElement>) {
    // Moving over a child of the zone fires dragleave on the zone too.
    if (!(event.relatedTarget instanceof Node && event.currentTarget.contains(event.relatedTarget))) {
      setDragging(false);
    }
  }

  function drop(event: DragEvent<HTMLDivElement>) {
    event.preventDefault();
    setDragging(false);
    take(event.dataTransfer.files);
  }

  const Icon = dragging ? ArrowDownToLine : Upload;
  return (
    <div
      data-testid="drop-zone"
      onDragOver={dragOver}
      onDragLeave={dragLeave}
      onDrop={drop}
      className={cn(
        "flex min-h-80 flex-1 flex-col items-center justify-center gap-3.5 rounded-[20px] border-2 px-6 py-8 text-center transition-colors duration-150",
        dragging ? "border-solid border-accent bg-accent/10" : "border-dashed border-border-strong",
      )}
    >
      <span
        className={cn(
          "flex size-16 items-center justify-center rounded-full",
          dragging ? "bg-accent text-accent-foreground" : "bg-surface-raised text-foreground",
        )}
      >
        <Icon aria-hidden="true" size={28} />
      </span>
      <div className="flex flex-col gap-1.5">
        <strong className="text-lg font-semibold">
          {dragging ? (
            t("drop")
          ) : (
            <>
              <span className="md:hidden">{t("title")}</span>
              <span className="hidden md:inline">{t("titleDesktop")}</span>
            </>
          )}
        </strong>
        <span className="text-sm leading-normal text-muted">
          {dragging ? (
            t("limits")
          ) : (
            <>
              <span className="md:hidden">{t("limits")}</span>
              <span className="hidden md:inline">{t("limitsDesktop")}</span>
            </>
          )}
        </span>
      </div>
      {!dragging && (
        <Button size="lg" className="mt-1.5 px-6" loading={checking} onClick={() => input.current?.click()}>
          {!checking && <FolderOpen aria-hidden="true" size={18} />}
          {checking ? t("checking") : t("button")}
        </Button>
      )}
      <input
        ref={input}
        type="file"
        accept="video/*,.mp4,.mov,.webm"
        hidden
        aria-hidden="true"
        tabIndex={-1}
        onChange={(event) => {
          take(event.currentTarget.files);
          // The same file chosen again after an error still fires change.
          event.currentTarget.value = "";
        }}
      />
    </div>
  );
}
