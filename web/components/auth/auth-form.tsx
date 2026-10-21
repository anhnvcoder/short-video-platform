"use client";

import { CircleAlert, Eye, EyeOff, Timer, type LucideIcon } from "lucide-react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import {
  useActionState,
  useEffect,
  useRef,
  useState,
  useSyncExternalStore,
  type FormEvent,
  type ReactNode,
} from "react";
import { useFormStatus } from "react-dom";
import { useCountdown } from "@/components/shell/use-countdown";
import { Button, Field, IconButton, Input } from "@/components/ui";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";
import { initialAuthState, type AuthState } from "@/server/auth-state";

export type AuthMode = "login" | "register";

type FieldErrors = AuthState["fieldErrors"];

type AuthFormProps = {
  mode: AuthMode;
  // loginAction or registerAction of server/auth-actions.ts.
  action: (previous: AuthState, form: FormData) => Promise<AuthState>;
  // The `next` query of the page, passed on untouched: the action checks it (WEB-4).
  next?: string;
};

// A loose shape check: the server's is stricter, this only spares a round trip for an obvious typo.
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function checkFields(form: HTMLFormElement): FieldErrors {
  const data = new FormData(form);
  const email = String(data.get("email") ?? "").trim();
  const password = String(data.get("password") ?? "");
  return {
    ...(emailPattern.test(email) ? {} : { email: "INVALID_EMAIL" }),
    ...(password.length >= 8 ? {} : { password: "INVALID_PASSWORD" }),
  };
}

function subscribe(): () => void {
  return () => {};
}

// False in the server render and before hydration, true after: a form posted without JavaScript gets an enabled
// button, since no countdown would ever unlock it.
function useHydrated(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => true,
    () => false,
  );
}

function withNext(path: string, next: string | undefined): string {
  return next ? `${path}?${new URLSearchParams({ next })}` : path;
}

// Login and register form of web/design/AuthForm.dc.html. It posts to a Server Action, so it works without
// JavaScript; with it, the fields are checked first and errors show without a round trip. The action sends back the
// email to fill in again, never the password.
export function AuthForm({ mode, action, next }: AuthFormProps) {
  const t = useTranslations("auth");
  const [state, formAction, pending] = useActionState(action, initialAuthState);
  const [clientErrors, setClientErrors] = useState<FieldErrors | null>(null);
  const [showPassword, setShowPassword] = useState(false);
  const emailRef = useRef<HTMLInputElement>(null);
  const passwordRef = useRef<HTMLInputElement>(null);
  const hydrated = useHydrated();

  const rateLimited = state.formError === "RATE_LIMITED";
  const left = useCountdown(rateLimited ? state.retryAfterSeconds : null, state);
  const locked = hydrated && left > 0;

  // A new answer from the server: move the focus to the first field it rejects.
  useEffect(() => {
    if (state.fieldErrors.email || state.formError === "EMAIL_ALREADY_REGISTERED") {
      emailRef.current?.focus();
    } else if (state.fieldErrors.password) {
      passwordRef.current?.focus();
    }
  }, [state]);

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    const errors = checkFields(event.currentTarget);
    if (errors.email || errors.password) {
      event.preventDefault();
      setClientErrors(errors);
      (errors.email ? emailRef : passwordRef).current?.focus();
      return;
    }
    setClientErrors(null);
  }

  const fieldErrors = clientErrors ?? state.fieldErrors;
  // Errors of the whole form belong to the last answer; a new client-side check hides them.
  const formError = clientErrors ? null : state.formError;
  const emailError = fieldErrors.email
    ? t(`errors.${fieldErrors.email}`)
    : formError === "EMAIL_ALREADY_REGISTERED" && (
        <>
          {t("errors.EMAIL_ALREADY_REGISTERED")}{" "}
          <Link href={withNext("/login", next)} className="font-semibold text-inherit underline">
            {t("errors.emailTakenLogin")}
          </Link>
        </>
      );

  return (
    <form action={formAction} onSubmit={onSubmit} noValidate className="flex flex-col gap-5">
      <div className="flex flex-col gap-2">
        <h1 className="text-[28px] leading-[1.2] font-bold tracking-[-0.01em]">{t(`${mode}.title`)}</h1>
        <p className="text-[15px] leading-normal text-pretty text-muted">{t(`${mode}.subtitle`)}</p>
      </div>

      {formError === "INVALID_CREDENTIALS" && (
        <FormAlert
          icon={CircleAlert}
          tone="danger"
          title={t("errors.INVALID_CREDENTIALS.title")}
          body={t("errors.INVALID_CREDENTIALS.body")}
        />
      )}
      {formError === "UNAVAILABLE" && (
        <FormAlert
          icon={CircleAlert}
          tone="danger"
          title={t("errors.UNAVAILABLE.title")}
          body={t("errors.UNAVAILABLE.body")}
        />
      )}
      {formError === "RATE_LIMITED" && (state.retryAfterSeconds === null || left > 0) && (
        <FormAlert
          icon={Timer}
          tone="warning"
          title={t("errors.RATE_LIMITED.title")}
          body={
            state.retryAfterSeconds === null ? (
              t("errors.RATE_LIMITED.bodyNoTime")
            ) : (
              <>
                {/* Screen readers hear the wait once; the ticking copy is for the eyes only. */}
                <span className="sr-only">{t("errors.RATE_LIMITED.body", { seconds: state.retryAfterSeconds })}</span>
                <span aria-hidden="true" className="tabular-nums">
                  {t("errors.RATE_LIMITED.body", { seconds: left })}
                </span>
              </>
            )
          }
        />
      )}

      {next !== undefined && <input type="hidden" name="next" value={next} />}

      <Field label={t("email")} error={emailError || undefined}>
        {(control) => (
          <Input
            {...control}
            ref={emailRef}
            name="email"
            type="email"
            inputMode="email"
            autoComplete="email"
            autoCapitalize="none"
            spellCheck={false}
            maxLength={254}
            placeholder={t("emailPlaceholder")}
            defaultValue={state.email}
            readOnly={pending}
            className={cn(pending && "opacity-60")}
          />
        )}
      </Field>

      <Field
        label={t("password")}
        hint={mode === "register" ? t("passwordHint") : undefined}
        error={fieldErrors.password && t(`errors.${fieldErrors.password}`)}
      >
        {(control) => (
          <Input
            {...control}
            ref={passwordRef}
            name="password"
            type={showPassword ? "text" : "password"}
            autoComplete={mode === "login" ? "current-password" : "new-password"}
            // No maxLength: the browser counts it in UTF-16 units, so a password of emoji or other characters outside
            // the BMP would be cut at half the 128 characters the server allows, counted in code points. The server
            // checks the length.
            placeholder={t(`${mode}.passwordPlaceholder`)}
            readOnly={pending}
            className={cn(pending && "opacity-60")}
            trailing={
              <IconButton
                tone="muted"
                className="rounded-[10px]"
                // One fixed name (AuthForm.dc.html); the pressed state says whether the password shows.
                label={t("showPassword")}
                pressed={showPassword}
                icon={showPassword ? <EyeOff aria-hidden="true" size={20} /> : <Eye aria-hidden="true" size={20} />}
                onClick={() => setShowPassword((shown) => !shown)}
              />
            }
          />
        )}
      </Field>

      <SubmitButton
        label={t(`${mode}.submit`)}
        pendingLabel={t(`${mode}.submitting`)}
        lockedLabel={locked ? t("retryIn", { seconds: left }) : null}
      />

      <p className="text-center text-[15px] text-muted">
        {t(`${mode}.switchText`)}{" "}
        <Link
          href={withNext(mode === "login" ? "/register" : "/login", next)}
          className={cn("inline-block rounded-sm px-1 py-3 font-semibold text-accent-text", focusRing)}
        >
          {t(`${mode}.switchLink`)}
        </Link>
      </p>
    </form>
  );
}

type SubmitButtonProps = {
  label: string;
  pendingLabel: string;
  // Set while a rate limit runs: the button is locked and counts down.
  lockedLabel: string | null;
};

function SubmitButton({ label, pendingLabel, lockedLabel }: SubmitButtonProps) {
  const { pending } = useFormStatus();
  if (lockedLabel) {
    return (
      <Button type="submit" size="lg" disabled className="mt-1 w-full tabular-nums">
        <Timer aria-hidden="true" size={20} />
        {lockedLabel}
      </Button>
    );
  }
  return (
    <Button type="submit" size="lg" loading={pending} className="mt-1 w-full">
      {pending ? pendingLabel : label}
    </Button>
  );
}

const alertTones = {
  danger: { surface: "bg-danger-surface", icon: "text-danger" },
  warning: { surface: "bg-warning-surface", icon: "text-warning" },
} as const;

type FormAlertProps = {
  icon: LucideIcon;
  tone: keyof typeof alertTones;
  title: string;
  body: ReactNode;
};

// An error of the whole form: icon and title as well as color, announced when it appears.
function FormAlert({ icon: Icon, tone, title, body }: FormAlertProps) {
  return (
    <div
      role="alert"
      className={cn("flex gap-3 rounded-md px-3.5 py-3 text-sm leading-[1.45]", alertTones[tone].surface)}
    >
      <Icon aria-hidden="true" size={20} className={cn("shrink-0", alertTones[tone].icon)} />
      <div className="flex flex-col gap-0.5">
        <strong className="font-semibold">{title}</strong>
        <span className="text-muted">{body}</span>
      </div>
    </div>
  );
}
