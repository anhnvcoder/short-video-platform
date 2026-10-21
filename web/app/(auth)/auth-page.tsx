import { redirect } from "next/navigation";
import { AuthForm, type AuthMode } from "@/components/auth/auth-form";
import type { AuthState } from "@/server/auth-state";
import { getCurrentUser } from "@/server/current-user";

export type SearchParams = Promise<Record<string, string | string[] | undefined>>;

// Body of /login and /register. A visitor who is already logged in goes to the home page; `next` only fills the
// hidden field, the action checks it (WEB-4), so the page never redirects to it.
export async function AuthPage({
  mode,
  action,
  searchParams,
}: {
  mode: AuthMode;
  action: (previous: AuthState, form: FormData) => Promise<AuthState>;
  searchParams: SearchParams;
}) {
  // Session store out of reach (Redis down): show the form as to a logged-out visitor rather than the error page;
  // sending it answers UNAVAILABLE.
  const user = await getCurrentUser().catch(() => null);
  if (user) {
    redirect("/");
  }
  const { next } = await searchParams;
  return <AuthForm mode={mode} action={action} next={typeof next === "string" ? next : undefined} />;
}
