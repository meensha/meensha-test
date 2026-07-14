ALTER TABLE inventory_skus ADD COLUMN IF NOT EXISTS india_available boolean NOT NULL DEFAULT true;
ALTER TABLE inventory_skus ADD COLUMN IF NOT EXISTS au_available    boolean NOT NULL DEFAULT false;
NOTIFY pgrst, 'reload schema';
