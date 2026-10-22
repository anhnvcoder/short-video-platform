"use client";

import { CircleCheck } from "lucide-react";
import { useTranslations } from "next-intl";
import { useActionState, useEffect, useRef, useState, type FormEvent } from "react";
import { useFormStatus } from "react-dom";
import { useCountdown } from "@/components/shell/use-countdown";
import { Button, Field, Input } from "@/components/ui";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";
import {
  checkDisplayName,
  initialDisplayNameState,
  type DisplayNameError,
  type DisplayNameState,
} from "./display-name";

type DisplayNameFormProps = {
  // The name GET /me gave; empty when it did not answer.
  current: string;
  // updateDisplayNameAction of server/profile-actions.ts.
  action: (previous: DisplayNameState, form: FormData) => Promise<DisplayNameState>;
};

// Changes the display name on /me (the design has no screen for it: the primitives of the login form, in a disclosure
// under the account). It posts to a Server Action, so it works without JavaScript; with it, the name is checked first
// with the server's own rules and an error shows without a round trip. On success the action refreshes the page, which
// then shows the new name here and in the side bar.
export function DisplayNameForm({ current, action }: DisplayNameFormProps) {
  const t = useTranslations("profile.displayName");
  const [state, formAction, pending] = useActionState(action, initialDisplayNameState);
  const [clientError, setClientError] = useState<DisplayNameError | null>(null);
  const input = useRef<HTMLInputElement>(null);

  const rateLimited = state.formError === "RATE_LIMITED";
  const left = useCountdown(rateLimited ? state.retryAfterSeconds : null, state);

  // A new answer that refuses the name: back to the field.
  useEffect(() => {
    if (state.fieldError) {
      input.current?.focus();
    }
  }, [state]);

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    const checked = checkDisplayName(new FormData(event.currentTarget).get("display_name"));
    if (!checked.ok) {
      event.preventDefault();
      setClientError(checked.error);
      input.current?.focus();
      return;
    }
    setClientError(null);
  }

  const fieldError = clientError ?? state.fieldError;
  // Errors and confirmations belong to the last answer; a new client-side check hides them.
  const formError = clientError ? null : state.formError;
  const saved = !clientError && !pending && state.saved !== null;

  return (
    <details className="group" open={state !== initialDisplayNameState || undefined}>
      <summary
        className={cn(
          "inline-flex min-h-11 cursor-pointer items-center rounded-sm text-[15px] font-semibold text-accent-text",
          focusRing,
        )}
      >
        {t("summary")}
      </summary>
      <form action={formAction} onSubmit={onSubmit} noValidate className="flex max-w-md flex-col gap-3 pt-2">
        <Field label={t("label")} hint={t("hint")} error={fieldError ? t(`errors.${fieldError}`) : undefined}>
          {(control) => (
            <Input
              {...control}
              ref={input}
              name="display_name"
              type="text"
              autoComplete="nickname"
              // No maxLength: the browser counts UTF-16 units, so an emoji would count twice; the check names the
              // limit in characters.
              defaultValue={state.value ?? current}
              readOnly={pending}
              className={cn(pending && "opacity-60")}
            />
          )}
        </Field>
        {formError && (
          <p role="alert" className="text-sm leading-[1.4] text-danger tabular-nums">
            {formError === "RATE_LIMITED" ? t("errors.RATE_LIMITED", { seconds: left }) : t("errors.UNAVAILABLE")}
          </p>
        )}
        <p role="status" className="text-sm leading-[1.4] text-success empty:hidden">
          {saved && (
            <span className="inline-flex items-center gap-1.5">
              <CircleCheck aria-hidden="true" size={16} />
              {t("saved")}
            </span>
          )}
        </p>
        <SubmitButton label={t("submit")} pendingLabel={t("submitting")} locked={rateLimited && left > 0} />
      </form>
    </details>
  );
}

function SubmitButton({ label, pendingLabel, locked }: { label: string; pendingLabel: string; locked: boolean }) {
  const { pending } = useFormStatus();
  return (
    <Button type="submit" loading={pending} disabled={locked} className="self-start">
      {pending ? pendingLabel : label}
    </Button>
  );
}
