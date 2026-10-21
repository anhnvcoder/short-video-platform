import type { ComponentProps, ReactNode } from "react";
import { cn } from "@/lib/cn";
import { focusRing } from "./styles";

const tones = {
  default: "text-foreground hover:bg-surface-hover",
  muted: "text-muted hover:text-foreground",
  // Over video: white icon with a shadow, in both themes.
  media: "text-on-media drop-shadow-media",
} as const;

type IconButtonProps = Omit<ComponentProps<"button">, "aria-label" | "aria-pressed" | "children"> & {
  // The accessible name; the button shows only an icon.
  label: string;
  icon: ReactNode;
  tone?: keyof typeof tones;
  // A toggle (mute, like): announced as pressed or not.
  pressed?: boolean;
};

export function IconButton({
  label,
  icon,
  tone = "default",
  pressed,
  type = "button",
  className,
  ...props
}: IconButtonProps) {
  return (
    <button
      type={type}
      aria-label={label}
      aria-pressed={pressed}
      className={cn(
        "inline-flex size-11 shrink-0 items-center justify-center rounded-full bg-transparent transition-colors duration-120 ease-out active:scale-90 disabled:cursor-not-allowed disabled:opacity-60",
        focusRing,
        tones[tone],
        className,
      )}
      {...props}
    >
      {icon}
    </button>
  );
}
