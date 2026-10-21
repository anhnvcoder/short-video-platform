import { CircleAlert } from "lucide-react";
import { useId, type ReactNode } from "react";

// What a control inside a Field spreads on itself: its id for the label and the ids of the hint or error that
// describe it.
export type FieldControlProps = {
  id: string;
  "aria-describedby"?: string;
  invalid: boolean;
};

type FieldProps = {
  label: ReactNode;
  hint?: ReactNode;
  // Shown instead of the hint; marks the control invalid.
  error?: ReactNode;
  children: (control: FieldControlProps) => ReactNode;
};

export function Field({ label, hint, error, children }: FieldProps) {
  const id = useId();
  const noteId = `${id}-note`;
  const note = error ?? hint;
  return (
    <div className="flex flex-col gap-2">
      <label htmlFor={id} className="text-sm font-semibold">
        {label}
      </label>
      {children({ id, "aria-describedby": note ? noteId : undefined, invalid: Boolean(error) })}
      {error ? (
        <p id={noteId} className="flex items-start gap-1.5 text-sm leading-[1.4] text-danger">
          <CircleAlert aria-hidden="true" size={16} className="mt-0.5 shrink-0" />
          <span>{error}</span>
        </p>
      ) : (
        hint && (
          <p id={noteId} className="text-sm leading-[1.4] text-muted">
            {hint}
          </p>
        )
      )}
    </div>
  );
}
