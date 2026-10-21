import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { registerAction } from "@/server/auth-actions";
import { AuthPage, type SearchParams } from "../auth-page";

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations("auth"))("register.metaTitle") };
}

export default function RegisterPage({ searchParams }: { searchParams: SearchParams }) {
  return <AuthPage mode="register" action={registerAction} searchParams={searchParams} />;
}
