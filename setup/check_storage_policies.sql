SELECT policyname, roles, cmd, qual, with_check
FROM pg_policies
WHERE tablename = 'objects' AND schemaname = 'storage';

SELECT id, name, public FROM storage.buckets WHERE id = 'item-photos';
