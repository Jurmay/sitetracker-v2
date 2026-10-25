-- =====================================================================
-- Submissions saved on a phone without signal are sent later, and a send
-- can be retried if the signal drops before the reply arrives. A random
-- client_ref generated on the phone makes each submission count once:
-- the backend returns the existing row when the same ref arrives again.
-- (Master roll needs none: one entry per coordinator per day already.)
-- =====================================================================
ALTER TABLE public.progress_reports ADD COLUMN client_ref uuid;
ALTER TABLE public.labourers ADD COLUMN client_ref uuid;
CREATE UNIQUE INDEX uq_progress_reports_client_ref ON public.progress_reports USING btree (client_ref) WHERE client_ref IS NOT NULL;
CREATE UNIQUE INDEX uq_labourers_client_ref ON public.labourers USING btree (client_ref) WHERE client_ref IS NOT NULL;
