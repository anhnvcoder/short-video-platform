import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";
import { NextIntlClientProvider } from "next-intl";
import { getMessages, getTranslations } from "next-intl/server";
import { isHandle, lowerHandle, profileHref } from "@/features/profile/api";
import { ProfileScreen } from "@/features/profile/profile-screen";
import { rateLimitedError } from "@/server/current-user";
import { serverEnv } from "@/server/env";
import { loadProfilePage } from "@/server/profile-page";

type Props = { params: Promise<{ handle: string }> };

// The title is the handle of the path, so the metadata needs no call to the gateway.
export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const handle = lowerHandle((await params).handle);
  return { title: isHandle(handle) ? `@${handle}` : (await getTranslations("profile"))("notFound.title") };
}

// Another user's profile. Handles are stored lower-case:
// A-Z in the path is lowered by a redirect, and anything that still cannot be a handle is the profile's 404 without a
// call to the gateway. The viewer's own handle goes to /me.
export default async function ProfilePage({ params }: Props) {
  const { handle } = await params;
  const lowered = lowerHandle(handle);
  if (!isHandle(lowered)) {
    notFound();
  }
  if (lowered !== handle) {
    redirect(profileHref(lowered));
  }
  const page = await loadProfilePage(lowered);
  switch (page.kind) {
    case "not-found":
      notFound();
    case "self":
      redirect("/me");
    case "rate-limited":
      throw rateLimitedError(page.retryAfterSeconds);
    case "unavailable":
      throw new Error("the profile cannot be loaded right now");
  }
  const messages = await getMessages();
  return (
    // Only the profile namespace goes to the browser.
    <NextIntlClientProvider messages={{ profile: messages.profile }}>
      <ProfileScreen
        profile={page.profile}
        initialPage={page.videos.page}
        initialRetryAfterSeconds={page.videos.retryAfterSeconds}
        mediaOrigin={serverEnv().mediaOrigin}
      />
    </NextIntlClientProvider>
  );
}
