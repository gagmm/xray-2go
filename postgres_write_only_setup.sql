-- xray2go PostgreSQL write-only ingest setup
-- Usage as database owner/admin:
--   psql -h 127.0.0.1 -U xray -d xray -v writer_password='CHANGE_ME' -f postgres_write_only_setup.sql
--
-- Writer credentials can call only public.xray2go_ingest_links(jsonb).
-- They cannot SELECT/UPDATE/DELETE/TRUNCATE the node tables.

\set ON_ERROR_STOP on

SELECT CASE
    WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'xray2go_writer')
    THEN format('ALTER ROLE xray2go_writer LOGIN PASSWORD %L', :'writer_password')
    ELSE format('CREATE ROLE xray2go_writer LOGIN PASSWORD %L', :'writer_password')
END
\gexec

CREATE TABLE IF NOT EXISTS public.xray_node_config_events (
    id bigserial PRIMARY KEY,
    node_id text NOT NULL,
    payload jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.xray_node_configs (
    node_id text PRIMARY KEY,
    hostname text NOT NULL DEFAULT '',
    public_ip inet,
    install_dir text NOT NULL DEFAULT '',
    cdn_host text NOT NULL DEFAULT '',
    argo_domain text NOT NULL DEFAULT '',
    sub_url text NOT NULL DEFAULT '',
    uuid text NOT NULL DEFAULT '',
    public_key text NOT NULL DEFAULT '',
    ports jsonb NOT NULL DEFAULT '{}'::jsonb,
    links jsonb NOT NULL DEFAULT '{}'::jsonb,
    config_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    raw_ports_env jsonb NOT NULL DEFAULT '{}'::jsonb,
    script_version text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.xray2go_ingest_links(payload jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_node_id text;
    v_public_ip inet;
BEGIN
    v_node_id := NULLIF(payload->>'node_id', '');
    IF v_node_id IS NULL THEN
        RAISE EXCEPTION 'node_id is required';
    END IF;

    BEGIN
        v_public_ip := NULLIF(payload->>'public_ip', '')::inet;
    EXCEPTION WHEN OTHERS THEN
        v_public_ip := NULL;
    END;

    INSERT INTO public.xray_node_config_events (node_id, payload)
    VALUES (v_node_id, payload);

    INSERT INTO public.xray_node_configs (
        node_id, hostname, public_ip, install_dir, cdn_host, argo_domain, sub_url,
        uuid, public_key, ports, links, config_json, raw_ports_env, script_version,
        created_at, updated_at
    ) VALUES (
        v_node_id,
        COALESCE(payload->>'hostname', ''),
        v_public_ip,
        COALESCE(payload->>'install_dir', ''),
        COALESCE(payload->>'cdn_host', ''),
        COALESCE(payload->>'argo_domain', ''),
        COALESCE(payload->>'sub_url', ''),
        COALESCE(payload->>'uuid', ''),
        COALESCE(payload->>'public_key', ''),
        COALESCE(payload->'ports', '{}'::jsonb),
        COALESCE(payload->'links', '{}'::jsonb),
        COALESCE(payload->'config_json', '{}'::jsonb),
        COALESCE(payload->'raw_ports_env', '{}'::jsonb),
        COALESCE(payload->>'script_version', 'links_latest_writeonly'),
        now(), now()
    )
    ON CONFLICT (node_id) DO UPDATE SET
        hostname = EXCLUDED.hostname,
        public_ip = EXCLUDED.public_ip,
        install_dir = EXCLUDED.install_dir,
        cdn_host = EXCLUDED.cdn_host,
        argo_domain = EXCLUDED.argo_domain,
        sub_url = EXCLUDED.sub_url,
        uuid = EXCLUDED.uuid,
        public_key = EXCLUDED.public_key,
        ports = EXCLUDED.ports,
        links = EXCLUDED.links,
        config_json = EXCLUDED.config_json,
        raw_ports_env = EXCLUDED.raw_ports_env,
        script_version = EXCLUDED.script_version,
        updated_at = now();
END;
$$;

ALTER FUNCTION public.xray2go_ingest_links(jsonb) OWNER TO CURRENT_USER;

REVOKE ALL ON TABLE public.xray_node_configs FROM PUBLIC;
REVOKE ALL ON TABLE public.xray_node_config_events FROM PUBLIC;
REVOKE ALL ON FUNCTION public.xray2go_ingest_links(jsonb) FROM PUBLIC;

REVOKE ALL ON TABLE public.xray_node_configs FROM xray2go_writer;
REVOKE ALL ON TABLE public.xray_node_config_events FROM xray2go_writer;
GRANT USAGE ON SCHEMA public TO xray2go_writer;
GRANT EXECUTE ON FUNCTION public.xray2go_ingest_links(jsonb) TO xray2go_writer;
