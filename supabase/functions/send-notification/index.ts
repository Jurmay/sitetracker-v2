// supabase/functions/send-notification/index.ts
//
// Receives the POST from fn_dispatch_pending_notifications() (migration
// 007, called via pg_net) and sends the actual email via Resend.

import { createClient } from "npm:@supabase/supabase-js@2";
import { Resend } from "npm:resend@4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SECRET_KEYS = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
const SUPABASE_SECRET_KEY = SUPABASE_SECRET_KEYS["default"];
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
const ACCOUNTS_EMAIL_FROM = Deno.env.get("ACCOUNTS_EMAIL_FROM") ?? "noreply@sitetracker.app";

const resend = new Resend(RESEND_API_KEY);
const supabase = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY);

interface NotificationPayload {
  notification_event_id: string;
  event_type: string;
  target_user_id: string;
  project_id: string;
  payload: Record<string, unknown>;
}

function buildMessage(eventType: string, payload: Record<string, unknown>): { subject: string; body: string } {
  switch (eventType) {
    case "master_roll_reminder":
      return {
        subject: "Reminder: today's Master Roll is not yet submitted",
        body: `You haven't submitted today's (${payload.date}) Master Roll entry yet. Please submit it as soon as possible.`,
      };
    case "master_roll_final_reminder":
      return {
        subject: "Final reminder: Master Roll still missing",
        body: `Today's (${payload.date}) Master Roll is still missing. If it remains unsubmitted, new advance requisitions will be locked until it is filed.`,
      };
    case "master_roll_lock":
      return {
        subject: "Advance requisitions locked: Master Roll missing",
        body: `Your ability to raise new advance requisitions has been locked because today's (${payload.date}) Master Roll has not been submitted. Submit it to unlock.`,
      };
    case "progress_report_reminder":
      return {
        subject: "Reminder: today's Progress Report is not yet submitted",
        body: `You haven't submitted today's (${payload.date}) Daily Progress Report yet. Please submit it as soon as possible.`,
      };
    case "progress_report_final_reminder":
      return {
        subject: "Final reminder: Progress Report still missing",
        body: `Today's (${payload.date}) Progress Report is still missing. If it remains unsubmitted, new advance requisitions will be locked until it is filed.`,
      };
    case "progress_report_lock":
      return {
        subject: "Advance requisitions locked: Progress Report missing",
        body: `Your ability to raise new advance requisitions has been locked because today's (${payload.date}) Progress Report has not been submitted. Submit it to unlock.`,
      };
    case "settlement_reminder":
      return {
        subject: "Reminder: an advance is approaching its settlement deadline",
        body: `An advance you received (requisition ${payload.requisition_id}) is approaching its settlement deadline. Please submit your settlement with supporting bills soon.`,
      };
    case "settlement_final_reminder":
      return {
        subject: "Final reminder: settlement deadline approaching",
        body: `An advance you received (requisition ${payload.requisition_id}) will be locked from further advances soon if not settled. Please submit your settlement now.`,
      };
    case "settlement_lock":
      return {
        subject: "Advance requisitions locked: overdue settlement",
        body: `Your ability to raise new advance requisitions has been locked because requisition ${payload.requisition_id} was not settled within the grace period. Settle it to unlock.`,
      };
    case "cash_replenishment_alert":
      return {
        subject: "Cash balance below threshold",
        body: `The project's cash balance has dropped below the configured threshold. Consider raising a Fund Requisition.`,
      };
    default:
      return {
        subject: `SiteTracker notification: ${eventType}`,
        body: `Event payload: ${JSON.stringify(payload)}`,
      };
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405 });
  }

  const apiKeyHeader = req.headers.get("apikey") ?? "";
  if (apiKeyHeader !== SUPABASE_SECRET_KEY) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }

  let body: NotificationPayload;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), { status: 400 });
  }

  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .select("email, name")
    .eq("id", body.target_user_id)
    .single();

  if (profileError || !profile?.email) {
    console.error("send-notification: could not resolve target user's email", profileError);
    return new Response(JSON.stringify({ error: "Target user email not found" }), { status: 404 });
  }

  const { subject, body: emailBody } = buildMessage(body.event_type, body.payload);

  try {
    await resend.emails.send({
      from: ACCOUNTS_EMAIL_FROM,
      to: [profile.email],
      subject,
      text: emailBody,
    });
    return new Response(JSON.stringify({ status: "sent" }), { status: 200 });
  } catch (err) {
    console.error("send-notification: Resend send failed", err);
    return new Response(JSON.stringify({ error: "Failed to send email", details: String(err) }), { status: 500 });
  }
});
