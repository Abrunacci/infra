-- v3: fails on purpose. The migrations run in one transaction, so 001 and
-- 002 stay as they were and nothing of this one is applied.
ALTER TABLE visits ADD COLUMN broken text;
SELECT * FROM this_table_does_not_exist;
