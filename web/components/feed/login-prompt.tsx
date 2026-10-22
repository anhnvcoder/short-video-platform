import { Heart, UserPlus, X } from "lucide-react";
import Link from "next/link";
import { useTranslations } from "next-intl";
import { useEffect, useRef } from "react";
import { focusRing } from "@/components/ui/styles";
import { cn } from "@/lib/cn";
import { primaryAction, secondaryAction } from "@/components/shell/error-screen";

type LoginPromptProps = {
  // What the guest tried: the title says what logging in gives.
  reason: "like" | "follow";
  // Login and register pages, each sending the user back to this page afterwards.
  loginHref: string;
  registerHref: string;
  onClose: () => void;
};

// Asks a guest to log in when they press like or follow (web/design/FeedMobile.dc.html M09: a bottom sheet;
// FeedDesktop.dc.html D03: a centered dialog). Modal: focus moves to its first action, Tab and Shift+Tab go round its
// own controls without reaching the page under the backdrop, and focus comes back to the button that opened it;
// Escape, the backdrop and "Later" close it.
export function LoginPrompt({ reason, loginHref, registerHref, onClose }: LoginPromptProps) {
  const t = useTranslations("share.prompt");
  const first = useRef<HTMLAnchorElement>(null);
  const dialog = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    first.current?.focus();
    return () => opener?.focus();
  }, []);

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        event.preventDefault();
        onClose();
        return;
      }
      if (event.key === "Tab" && dialog.current) {
        keepFocusIn(dialog.current, event);
      }
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  const title = reason === "like" ? t("likeTitle") : t("followTitle");
  const Icon = reason === "like" ? Heart : UserPlus;
  return (
    <>
      <div aria-hidden="true" onClick={onClose} className="fixed inset-0 z-40 bg-overlay" />
      <div
        ref={dialog}
        role="dialog"
        aria-modal="true"
        aria-labelledby="login-prompt-title"
        className={cn(
          "fixed inset-x-0 bottom-0 z-50 flex flex-col items-center gap-4 rounded-t-xl bg-surface-raised px-6 pt-3 pb-7 text-center text-foreground",
          "md:inset-x-auto md:top-1/2 md:bottom-auto md:left-1/2 md:w-105 md:-translate-1/2 md:rounded-xl md:p-7 md:shadow-raised",
        )}
      >
        <span aria-hidden="true" className="h-1 w-9 rounded-full bg-border-strong md:hidden" />
        <button
          type="button"
          aria-label={t("close")}
          onClick={onClose}
          className={cn(
            "absolute top-2.5 right-2.5 hidden size-11 items-center justify-center rounded-full text-muted hover:bg-surface-hover hover:text-foreground md:flex",
            focusRing,
          )}
        >
          <X aria-hidden="true" size={20} />
        </button>
        <span className="mt-2 flex size-14 items-center justify-center rounded-full bg-accent/20 text-accent-text md:mt-0">
          <Icon aria-hidden="true" size={28} fill={reason === "like" ? "currentColor" : "none"} />
        </span>
        <div className="flex flex-col gap-1.5">
          <h2 id="login-prompt-title" className="text-xl font-bold">
            {title}
          </h2>
          <p className="text-[15px] leading-normal text-pretty text-muted">{t("body")}</p>
        </div>
        <div className="flex w-full flex-col gap-2.5">
          <Link ref={first} href={loginHref} className={cn(primaryAction, "min-h-13 text-base", focusRing)}>
            {t("logIn")}
          </Link>
          <Link href={registerHref} className={cn(secondaryAction, "min-h-13 text-base", focusRing)}>
            {t("register")}
          </Link>
          <button
            type="button"
            onClick={onClose}
            className={cn(
              "min-h-11 rounded-md text-[15px] font-medium text-muted hover:text-foreground md:hidden",
              focusRing,
            )}
          >
            {t("later")}
          </button>
        </div>
      </div>
    </>
  );
}

// Wraps Tab from the dialog's last control to its first and Shift+Tab from the first to the last, and brings focus
// back in when it is outside (after a click on the dialog's text, focus is on the body). A control the screen size
// hides (the close button on a phone, "Later" on a wide screen) is display: none and is skipped.
function keepFocusIn(container: HTMLElement, event: KeyboardEvent) {
  const controls = Array.from(container.querySelectorAll<HTMLElement>("a[href], button:not([disabled])")).filter(
    (control) => getComputedStyle(control).display !== "none",
  );
  const start = controls[0];
  const end = controls.at(-1);
  if (!start || !end) {
    return;
  }
  const active = document.activeElement;
  const inside = active instanceof Node && container.contains(active);
  if (event.shiftKey ? !inside || active === start : !inside || active === end) {
    event.preventDefault();
    (event.shiftKey ? end : start).focus();
  }
}
