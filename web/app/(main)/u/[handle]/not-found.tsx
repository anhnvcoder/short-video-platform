import { ProfileNotFound } from "@/components/profile/profile-states";

// No user has the handle, or it cannot be one: the profile's own 404, inside the app's frame.
export default function ProfileNotFoundPage() {
  return (
    <div className="flex h-full flex-col">
      <ProfileNotFound />
    </div>
  );
}
