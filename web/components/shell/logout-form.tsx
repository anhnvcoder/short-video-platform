import type { ReactNode } from "react";

// A plain POST to the /logout Route Handler, so logging out works without JavaScript; never a GET link, which a
// prefetch or another site could trigger.
export function LogoutForm({ className, children }: { className?: string; children: ReactNode }) {
  return (
    <form method="post" action="/logout" className={className}>
      {children}
    </form>
  );
}
