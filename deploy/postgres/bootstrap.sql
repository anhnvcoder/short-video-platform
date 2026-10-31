-- Roles and database of one service: a migrator that owns the schema and an app role limited to DML, so a running
-- service that is compromised cannot change its schema. Idempotent: run it any number of times, as a superuser (the
-- local Postgres, CloudNativePG's svp-pg) or as a role with only CREATEROLE and CREATEDB (the master user of Amazon
-- RDS, a member of rds_superuser, which is no superuser). bootstrap.sh runs it once per service with
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
-- Only a superuser may name SUPERUSER, REPLICATION or BYPASSRLS in ALTER ROLE, even to clear them. A superuser clears
-- them; any other role cannot have given them, so it checks instead that neither role has one (a superuser gave it) and
-- stops if so.
SELECT rolsuper AS is_superuser FROM pg_roles WHERE rolname = current_user \gset
\if :is_superuser
ALTER ROLE :"migrator" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    PASSWORD :'migrator_password';
ALTER ROLE :"app" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    PASSWORD :'app_password';
\else
ALTER ROLE :"migrator" WITH LOGIN NOCREATEDB NOCREATEROLE PASSWORD :'migrator_password';
ALTER ROLE :"app" WITH LOGIN NOCREATEDB NOCREATEROLE PASSWORD :'app_password';
SELECT format('DO $$BEGIN RAISE EXCEPTION %L; END$$',
    format('role %s has SUPERUSER, REPLICATION or BYPASSRLS, which only a superuser can clear', rolname))
FROM pg_roles
WHERE rolname IN (:'migrator', :'app') AND (rolsuper OR rolreplication OR rolbypassrls) \gexec
-- CREATE DATABASE ... OWNER, ALTER DATABASE ... OWNER TO and ALTER DEFAULT PRIVILEGES FOR ROLE need the running role
-- to be a member of the migrator (a superuser is taken as a member of every role). Granted again on every run, which
-- only notes it is there already.
GRANT :"migrator" TO CURRENT_USER;
\endif

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
