-- v2: a new column with a default, so v1 keeps working with the new schema
-- (a rollback puts back the image, never the schema).
ALTER TABLE visits ADD COLUMN note text NOT NULL DEFAULT 'added by v2';
