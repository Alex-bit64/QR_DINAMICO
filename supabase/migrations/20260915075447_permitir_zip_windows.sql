BEGIN;

-- Windows suele identificar los .zip como application/x-zip-compressed en el
-- selector de archivos. Se conservan los demás tipos ya usados por la app.
UPDATE storage.buckets
SET allowed_mime_types = ARRAY[
    'application/vnd.android.package-archive',
    'application/zip',
    'application/x-zip-compressed',
    'application/octet-stream'
]::TEXT[]
WHERE id = 'actualizaciones';

COMMIT;
