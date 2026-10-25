-- Roles and database of one service: a migrator that owns the schema and an app role limited to DML, so a running
-- service that is compromised cannot change its schema. Idempotent: run it as the local superuser any number of
-- times. bootstrap.sh runs it once per service with
--   psql -v db=<database> -v migrator=<role> -v app=<role>
-- and the two role passwords in the environment variables SVP_MIGRATOR_PASSWORD and
-- SVP_APP_PASSWORD, so they never appear on a command line.
\set ON_ERROR_STOP on
-- Terse errors: no "LINE n:" excerpt that could echo a password back.
\set VERBOSITY terse
\getenv migrator_password SVP_MIGRATOR_PASSWORD
\getenv app_password SVP_APP_PASSWORD

-- Roles: created when missing; attributes and password set again on every run.
SELECT format('CREATE ROLE %I', :'migrator')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'migrator') \gexec
SELECT format('CREATE ROLE %I', :'app')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app') \gexec
ALTER ROLE :"migrator" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    PASSWORD :'migrator_password';
ALTER ROLE :"app" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    PASSWORD :'app_password';

-- Database owned by the migrator. Only the owner (implicitly) and the app role may connect:
-- roles of other services cannot.
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'migrator')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
ALTER DATABASE :"db" OWNER TO :"migrator";
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO :"app";

-- Schema and default privileges live inside the database, so the rest runs connected to it.
\connect :db
-- Since Postgres 15 the public schema belongs to pg_database_owner (the migrator here) and
-- PUBLIC has no CREATE on it; revoke anyway so the app role can never create objects.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO :"app";
-- Every table and sequence the migrator creates from now on is readable and writable by the app
-- role, which gets no DDL right. goose's version table is not among them: the migrator keeps it
-- in its own schema goose (internal/dbmigrate), out of reach of the app role.
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator" IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator" IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO :"app";
