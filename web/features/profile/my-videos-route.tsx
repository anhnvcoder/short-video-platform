import { NextIntlClientProvider, useMessages } from "next-intl";
import { Suspense } from "react";
import { MyAccount } from "@/components/profile/my-account";
import { ListSkeleton } from "@/components/profile/profile-states";
import { requireSession } from "@/server/current-user";
import { serverEnv } from "@/server/env";
import { loadMyProfile } from "@/server/me";
import { updateDisplayNameAction } from "@/server/profile-actions";
import { loadMyVideosFirstPage } from "@/server/profile-page";
import { DisplayNameForm } from "./display-name-form";
import { MyVideosScreen } from "./my-videos-screen";

// Server part of /me: the account with log out and the display name form, then the user's videos. The first page of
// videos can take up to the gateway's timeout, so it streams in behind a skeleton; the account does not wait for it.
export function MyVideosRoute() {
  const messages = useMessages();
  return (
    // Only the profile namespace goes to the browser.
    <NextIntlClientProvider messages={{ profile: messages.profile }}>
      <div className="h-full overflow-y-auto md:px-14 md:py-10">
        <div className="flex w-full flex-col md:max-w-270 md:gap-7">
          <Suspense>
            <LoadedAccount />
          </Suspense>
          <Suspense fallback={<ListSkeleton />}>
            <LoadedVideos />
          </Suspense>
        </div>
      </div>
    </NextIntlClientProvider>
  );
}

// The profile is the one the layout asked for (GET /me, once per request). Without it the avatar alone shows, and the
// form starts empty.
async function LoadedAccount() {
  const [user, profile] = await Promise.all([requireSession(), loadMyProfile()]);
  const account = profile ? { displayName: profile.displayName, handle: profile.handle } : null;
  return (
    <MyAccount userId={user.userId} account={account}>
      <DisplayNameForm current={account?.displayName ?? ""} action={updateDisplayNameAction} />
    </MyAccount>
  );
}

// When this render ran: the client counts "3 days ago" from it until its own clock takes over, so hydration reads the
// text the server wrote.
function renderTime(): number {
  return Date.now();
}

// The media origin goes down as a prop: it is not a secret, and the browser bundle reads no environment variable. No
// token reaches the client components. When the first page cannot be had now, the client fetches it, after the
// Retry-After the gateway gave here if any.
async function LoadedVideos() {
  const [user, first] = await Promise.all([requireSession(), loadMyVideosFirstPage()]);
  return (
    <MyVideosScreen
      userId={user.userId}
      initialPage={first.page}
      initialRetryAfterSeconds={first.retryAfterSeconds}
      mediaOrigin={serverEnv().mediaOrigin}
      renderedAt={renderTime()}
    />
  );
}
