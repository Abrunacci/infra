-- v1: the table the probe writes to, readable and writable by the app role.
CREATE TABLE visits (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT ON visits TO {app_user};
