import { CircleAlert, CircleCheck, Info, type LucideIcon } from "lucide-react";
import type { ReactNode } from "react";
import { cn } from "@/lib/cn";
import { focusRing } from "./styles";

const tones = {
  danger: { icon: CircleAlert, color: "text-danger" },
  success: { icon: CircleCheck, color: "text-success" },
  info: { icon: Info, color: "text-info" },
} as const;

type ToastProps = {
  tone: keyof typeof tones;
  // Replaces the tone's icon (a link icon for "copied", a wifi icon for "back online").
  icon?: LucideIcon;
  children: ReactNode;
  action?: { label: string; onClick: () => void };
};

export function Toast({ tone, icon, children, action }: ToastProps) {
  const Icon = icon ?? tones[tone].icon;
  return (
    <div className="flex min-h-14 items-center gap-3 rounded-md border border-border bg-surface-raised py-1.5 pr-1.5 pl-3.5 text-foreground shadow-raised">
      <Icon aria-hidden="true" size={20} className={cn("shrink-0", tones[tone].color)} />
      <p className="flex-1 text-sm leading-[1.4]">{children}</p>
      {action && (
        <button
          type="button"
          onClick={action.onClick}
          className={cn(
            "min-h-11 rounded-sm px-3 text-sm leading-none font-semibold text-accent-text hover:bg-surface-hover",
            focusRing,
          )}
        >
          {action.label}
        </button>
      )}
    </div>
  );
}

type ToastRegionProps = {
  // Accessible name of the region ("Thông báo").
  label: string;
  children?: ReactNode;
  // Placement, e.g. above the mobile bottom navigation.
  className?: string;
};

// A live region that stays mounted: screen readers announce the toasts added to it, which they would miss if the region
// appeared together with its first toast.
export function ToastRegion({ label, children, className }: ToastRegionProps) {
  return (
    <div
      role="status"
      aria-live="polite"
      aria-label={label}
      className={cn("fixed inset-x-0 bottom-4 z-50 mx-auto flex w-full max-w-sm flex-col gap-2 px-4", className)}
    >
      {children}
    </div>
  );
}
