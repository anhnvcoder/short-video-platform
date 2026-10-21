import type { ComponentProps } from "react";
import { cn } from "@/lib/cn";
import { Spinner } from "./spinner";
import { focusRing } from "./styles";

const variants = {
  primary: "bg-accent text-accent-foreground hover:bg-accent-hover",
  secondary: "border border-border-strong bg-transparent text-foreground hover:bg-surface-hover",
  ghost: "bg-transparent text-muted hover:bg-surface-hover",
  danger: "border border-danger bg-transparent text-danger hover:bg-danger-surface",
} as const;

const sizes = {
  md: { button: "min-h-11 px-4 text-[15px]", spinner: 18 },
  lg: { button: "min-h-13 px-5 text-base", spinner: 20 },
} as const;

type ButtonProps = ComponentProps<"button"> & {
  variant?: keyof typeof variants;
  size?: keyof typeof sizes;
  // Shows a spinner before the label (pass the verb form, "Đang gửi…") and blocks clicks while a request runs.
  loading?: boolean;
};

export function Button({
  variant = "primary",
  size = "md",
  loading = false,
  disabled = false,
  type = "button",
  className,
  children,
  ...props
}: ButtonProps) {
  return (
    <button
      type={type}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      className={cn(
        "inline-flex items-center justify-center gap-2 rounded-md leading-none font-semibold transition-[background-color,transform] duration-120 ease-out",
        focusRing,
        sizes[size].button,
        disabled && !loading
          ? "cursor-not-allowed border border-border bg-surface-hover text-muted"
          : cn(variants[variant], "active:scale-97"),
        loading && "opacity-85",
        className,
      )}
      {...props}
    >
      {loading && <Spinner size={sizes[size].spinner} />}
      {children}
    </button>
  );
}
