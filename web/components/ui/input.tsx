import type { ComponentProps, ReactNode } from "react";
import { cn } from "@/lib/cn";

type InputProps = ComponentProps<"input"> & {
  invalid?: boolean;
  // Inside the box after the text, such as the show-password button.
  trailing?: ReactNode;
};

export function Input({ invalid = false, trailing, disabled, className, ...props }: InputProps) {
  return (
    <div
      className={cn(
        "flex h-12 items-center rounded-md bg-surface-raised transition-colors duration-120 ease-out focus-within:ring-2 focus-within:ring-ring focus-within:ring-offset-2 focus-within:ring-offset-surface",
        invalid ? "border-2 border-danger" : "border border-border-strong hover:border-muted",
        disabled && "opacity-60",
        trailing ? "pr-0.5" : undefined,
        className,
      )}
    >
      <input
        disabled={disabled}
        aria-invalid={invalid || undefined}
        className="h-full min-w-0 flex-1 bg-transparent px-3.5 text-base text-foreground outline-none placeholder:text-muted disabled:cursor-not-allowed"
        {...props}
      />
      {trailing}
    </div>
  );
}
