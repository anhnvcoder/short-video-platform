import { CircleAlert, TriangleAlert, WifiOff } from "lucide-react";
import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

// The alert box at the top of an upload step (M21–M24, M27, M29). Danger for what stops the upload, warning for what
// the user may wait out.

const tones = {
  danger: { box: "bg-danger-surface", icon: "text-danger", Icon: CircleAlert },
  warning: { box: "bg-warning-surface", icon: "text-warning", Icon: TriangleAlert },
  offline: { box: "bg-warning-surface", icon: "text-warning", Icon: WifiOff },
} as const;

type UploadAlertProps = {
  tone: keyof typeof tones;
  title: string;
  body: string;
  // A link under the text, such as "See My videos".
  children?: ReactNode;
};

export function UploadAlert({ tone, title, body, children }: UploadAlertProps) {
  const { box, icon, Icon } = tones[tone];
  return (
    <div role="alert" className={cn("flex gap-3 rounded-md px-3.5 py-3 text-sm leading-[1.45]", box)}>
      <Icon aria-hidden="true" size={20} className={cn("flex-none", icon)} />
      <div className="flex flex-col gap-0.5">
        <strong className="font-semibold">{title}</strong>
        <span className="text-muted">{body}</span>
        {children}
      </div>
    </div>
  );
}
