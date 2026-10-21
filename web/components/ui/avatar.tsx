import { User } from "lucide-react";
import { cn } from "@/lib/cn";

// Literal class names, so Tailwind finds them; the colors are the --color-avatar-* tokens.
const hues = [
  "bg-avatar-0",
  "bg-avatar-1",
  "bg-avatar-2",
  "bg-avatar-3",
  "bg-avatar-4",
  "bg-avatar-5",
  "bg-avatar-6",
  "bg-avatar-7",
] as const;

const sizes = {
  sm: { box: "size-8 text-[13px]", icon: 16 },
  md: { box: "size-12 text-xl", icon: 24 },
  lg: { box: "size-16 text-[26px]", icon: 32 },
  xl: { box: "size-22 text-[34px]", icon: 44 },
} as const;

// Index of the background hue for a seed (the author id): FNV-1a over the UTF-16 code units, so the same id gets the
// same color on the server, in every browser and on every visit.
export function avatarHue(seed: string): number {
  let hash = 0x811c9dc5;
  for (let i = 0; i < seed.length; i++) {
    hash ^= seed.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0) % hues.length;
}

type AvatarProps = {
  seed: string;
  // Display name; its first letter is shown. Without one, a person icon.
  name?: string;
  size?: keyof typeof sizes;
  // Accessible name when the avatar stands alone; without it the avatar is decoration beside a visible name.
  label?: string;
  className?: string;
};

export function Avatar({ seed, name, size = "md", label, className }: AvatarProps) {
  const initial = Array.from(name?.trim() ?? "")[0]?.toLocaleUpperCase();
  return (
    <span
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
      className={cn(
        "inline-flex shrink-0 items-center justify-center rounded-full font-semibold text-on-media",
        hues[avatarHue(seed)],
        sizes[size].box,
        className,
      )}
    >
      {initial ?? <User aria-hidden="true" size={sizes[size].icon} />}
    </span>
  );
}
