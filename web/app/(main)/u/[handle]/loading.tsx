import { GridSkeleton } from "@/components/profile/profile-states";

// While the profile and its first videos load.
export default function ProfileLoading() {
  return (
    <div className="flex h-full flex-col items-center pt-40 md:px-14 md:pt-50">
      <GridSkeleton />
    </div>
  );
}
