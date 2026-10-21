import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { loginAction } from "@/server/auth-actions";
import { AuthPage, type SearchParams } from "../auth-page";

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations("auth"))("login.metaTitle") };
}

export default function LoginPage({ searchParams }: { searchParams: SearchParams }) {
  return <AuthPage mode="login" action={loginAction} searchParams={searchParams} />;
}
