import type { ReactNode } from "react";

type ErrorScreenProps = {
  appName: string;
  // Status shown above the icon (404, 429); the generic error has none.
  status?: string;
  icon: ReactNode;
  title: string;
  body: string;
  // Buttons and links, stacked under the text.
  children: ReactNode;
  footnote?: ReactNode;
};

// Full-page state of web/design/SVP Mobile.dc.html M39–M41 and SVP Desktop.dc.html D11: the app name on top, then a
// centered icon, title, explanation and actions.
export function ErrorScreen({ appName, status, icon, title, body, children, footnote }: ErrorScreenProps) {
  return (
    <div className="flex min-h-dvh flex-col bg-surface text-foreground">
      <header className="flex h-14 shrink-0 items-center px-4">
        <span className="text-lg font-bold tracking-[0.1em]">{appName}</span>
      </header>
      <main className="flex flex-1 flex-col items-center justify-center gap-3.5 p-8 text-center md:gap-4">
        {status && (
          <span className="font-mono text-[13px] leading-none font-medium tracking-[0.1em] text-muted">{status}</span>
        )}
        {icon}
        <h1 className="text-[22px] font-bold md:text-[28px]">{title}</h1>
        <p className="max-w-70 text-[15px] leading-normal text-pretty text-muted md:max-w-md md:text-base">{body}</p>
        <div className="mt-2 flex w-full max-w-70 flex-col items-stretch gap-2.5 md:items-center">{children}</div>
        {footnote}
      </main>
    </div>
  );
}

// Button-like link classes of the design's error actions; literal so Tailwind finds them.
export const primaryAction =
  "inline-flex min-h-12 items-center justify-center gap-2 rounded-md bg-accent px-6 text-[15px] font-semibold text-accent-foreground hover:bg-accent-hover hover:text-accent-foreground";
export const secondaryAction =
  "inline-flex min-h-12 items-center justify-center rounded-md border border-border-strong px-6 text-[15px] font-semibold text-foreground hover:bg-surface-hover hover:text-foreground";
