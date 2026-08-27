-- Real schema drift found during QA: schema_combined.sql documents
-- `requests` as having item_id and notes columns from the start, but the
-- live table never actually had them — confirmed by testing each column
-- individually via the REST API. submit_saree_request's INSERT references
-- both, so request submission was failing with "column does not exist"
-- until this runs.

ALTER TABLE requests ADD COLUMN IF NOT EXISTS item_id text;
ALTER TABLE requests ADD COLUMN IF NOT EXISTS notes text;

NOTIFY pgrst, 'reload schema';
