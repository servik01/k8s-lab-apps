#!/usr/bin/env python3
"""Provision the exporter role and its Secret using the current kubectl context.

Run before syncing workloads/postgres/monitoring.yaml. The database must already
exist. Credentials are passed through stdin, never printed or committed to Git.
An existing Secret password is reused on subsequent runs.
"""

import base64
import json
import secrets
import subprocess


def kubectl(*args, input=None):
    return subprocess.run(
        ["kubectl", *args], input=input, text=True, capture_output=True, check=True
    ).stdout


def main():
    existing = kubectl(
        "-n", "postgres", "get", "secret", "postgres-exporter-auth",
        "--ignore-not-found", "-o", "json",
    )
    password = (
        base64.b64decode(json.loads(existing)["data"]["password"]).decode()
        if existing.strip() else secrets.token_hex(32)
    )
    # SQL string quoting also handles an existing password with quote characters.
    quoted = password.replace("'", "''")
    sql = """
BEGIN;
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgres_exporter') THEN
    CREATE ROLE postgres_exporter LOGIN;
  END IF;
END $$;
ALTER ROLE postgres_exporter WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
  INHERIT NOREPLICATION NOBYPASSRLS PASSWORD '%s';
GRANT pg_monitor TO postgres_exporter;
GRANT CONNECT ON DATABASE postgres TO postgres_exporter;
COMMIT;
""" % quoted
    kubectl(
        "-n", "postgres", "exec", "-i", "postgres-0", "--", "psql",
        "-U", "postgres", "-d", "postgres", "-q", "-v", "ON_ERROR_STOP=1",
        input=sql,
    )
    manifest = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": "postgres-exporter-auth", "namespace": "postgres"},
        "type": "Opaque",
        "data": {"password": base64.b64encode(password.encode()).decode()},
    }
    kubectl(
        "apply", "--server-side", "--field-manager=postgres-monitoring-bootstrap",
        "-f", "-", input=json.dumps(manifest),
    )
    print("PostgreSQL monitoring role and Secret configured; password not displayed.")


if __name__ == "__main__":
    main()
