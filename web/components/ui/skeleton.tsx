import { cn } from "@/lib/cn";

// A pulsing block that keeps the size of the content still loading; size and corner radius come from className.
export function Skeleton({ className }: { className?: string }) {
  return <span aria-hidden="true" className={cn("block animate-svp-pulse rounded-sm bg-skeleton", className)} />;
}
