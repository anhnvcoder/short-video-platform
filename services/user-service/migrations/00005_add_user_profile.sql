-- +goose Up
-- Public profile: a handle that never changes and a display name. handle is stored normalized (lower case), so its
-- unique constraint compares case-insensitively, as users_email_key does. The constraints are named because the service
-- maps users_handle_key to HANDLE_ALREADY_TAKEN; the two CHECKs are a second layer under the service's own validation.
--
-- Existing users get the handle the service generates when a client sends none: 'u_' and the last 12 hex digits of the
-- id, which are random bits of the UUIDv7, not its timestamp. Their display name defaults to that handle. goose runs this
-- file in one transaction, so if two existing users shared those 12 digits the unique constraint fails and nothing
-- changes; fix that row by hand and run it again.
ALTER TABLE users ADD COLUMN handle text, ADD COLUMN display_name text;

UPDATE users SET handle = 'u_' || right(id::text, 12), display_name = 'u_' || right(id::text, 12);

-- Instances of the previous release keep serving while this runs (the migration job runs before their pods are
-- replaced), and their INSERT names neither column. A column DEFAULT cannot read the row's id, so this trigger fills
-- what such an INSERT leaves out, the way the service would, before the NOT NULL check runs; without it every
-- registration in that window fails. The current service always sends both columns, so the trigger leaves its rows
-- alone.
-- +goose StatementBegin
CREATE FUNCTION users_fill_profile() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.handle IS NULL THEN
        NEW.handle := 'u_' || right(NEW.id::text, 12);
    END IF;
    IF NEW.display_name IS NULL THEN
        NEW.display_name := NEW.handle;
    END IF;
    RETURN NEW;
END $$;
-- +goose StatementEnd

CREATE TRIGGER users_fill_profile BEFORE INSERT ON users
    FOR EACH ROW EXECUTE FUNCTION users_fill_profile();

ALTER TABLE users
    ALTER COLUMN handle SET NOT NULL,
    ALTER COLUMN display_name SET NOT NULL,
    ADD CONSTRAINT users_handle_key UNIQUE (handle),
    ADD CONSTRAINT users_handle_check CHECK (handle ~ '^[a-z][a-z0-9_]{2,29}$'),
    ADD CONSTRAINT users_display_name_check CHECK (char_length(display_name) BETWEEN 1 AND 50);

-- +goose Down
DROP TRIGGER users_fill_profile ON users;
DROP FUNCTION users_fill_profile();
ALTER TABLE users DROP COLUMN display_name, DROP COLUMN handle;
