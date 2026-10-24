-- Make settlement receipts private. Applied 2026-10-24 after the
-- frontend that opens receipts through signed URLs (src/lib/receipts.js,
-- sitetracker-v2-frontend PR #1) was deployed to production.
UPDATE storage.buckets SET public = false WHERE id = 'settlement-receipts';
