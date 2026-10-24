-- Make settlement receipts private. Apply only AFTER the frontend that
-- opens receipts through signed URLs (src/lib/receipts.js) is deployed,
-- otherwise "View receipt" links stop working.
UPDATE storage.buckets SET public = false WHERE id = 'settlement-receipts';
