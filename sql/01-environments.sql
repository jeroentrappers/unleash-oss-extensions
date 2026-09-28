-- Provision the platform's flag environments: testing and staging.
-- (development and production are seeded by unleash-server's own migration
--  20210928080601-add-development-and-production-environments.js at
--  sort_order 100/200.)
--
-- Unleash OSS has no create-environment API or UI — environments are plain
-- rows in the `environments` table; this image's `ui.environment = "pro"`
-- setting (see index.js) makes non-default environments visible to the API.
--
-- Run once against the Unleash PostgreSQL database. Idempotent.

INSERT INTO environments (name, type, enabled, sort_order)
VALUES
    ('testing', 'test', true, 120),
    ('staging', 'pre-production', true, 150)
ON CONFLICT (name) DO NOTHING;

-- Make the new environments available to the default project.
INSERT INTO project_environments (project_id, environment_name)
VALUES
    ('default', 'testing'),
    ('default', 'staging')
ON CONFLICT DO NOTHING;
