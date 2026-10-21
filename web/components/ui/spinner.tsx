import { LoaderCircle } from "lucide-react";
import { cn } from "@/lib/cn";

type SpinnerProps = {
  size?: number;
  // Announced to screen readers as a status; without it the spinner is decoration beside a visible text.
  label?: string;
  className?: string;
};

export function Spinner({ size = 20, label, className }: SpinnerProps) {
  const icon = <LoaderCircle aria-hidden="true" size={size} className={cn("animate-svp-spin", className)} />;
  if (!label) {
    return icon;
  }
  return (
    <span role="status" className="inline-flex">
      {icon}
      <span className="sr-only">{label}</span>
    </span>
  );
}
