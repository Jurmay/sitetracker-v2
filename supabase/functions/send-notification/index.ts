// supabase/functions/send-notification/index.ts
//
// Receives the POST from fn_dispatch_pending_notifications() (called via
// pg_net) and sends the actual email via Resend. The dispatcher marks the
// event sent or failed from this function's HTTP status, so any failure
// must return a non-2xx with the reason.

import { createClient } from "npm:@supabase/supabase-js@2";
import { Resend } from "npm:resend@4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
// Newer projects expose SUPABASE_SECRET_KEYS; this one only has the
// classic SUPABASE_SERVICE_ROLE_KEY. Reading only the former crashed the
// function on start, so no email was ever sent before Oct 2026.
const SUPABASE_SECRET_KEYS: Record<string, string> = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SUPABASE_SECRET_KEY = SUPABASE_SECRET_KEYS["default"] ?? SERVICE_ROLE_KEY;
// The dispatcher sends whichever key is stored in Vault as service_role_key.
const ACCEPTED_KEYS = new Set([SERVICE_ROLE_KEY, ...Object.values(SUPABASE_SECRET_KEYS)].filter(Boolean));
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const ACCOUNTS_EMAIL_FROM = Deno.env.get("ACCOUNTS_EMAIL_FROM") ?? "noreply@sitetracker.app";

// Created only when the key is set, so a missing key is a clear failure
// reason on each event rather than a crash on start.
const resend = RESEND_API_KEY ? new Resend(RESEND_API_KEY) : null;
const supabase = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY);

interface NotificationPayload {
  notification_event_id: string;
  event_type: string;
  target_user_id: string;
  project_id: string;
  payload: Record<string, unknown>;
}

interface SiteSummary {
  name: string;
  physical_progress_pct: number;
  financial_progress_pct: number;
  cost_variance: number;
  cash_balance: number;
  cash_low: boolean;
  coordinators_on_duty: number;
  submitted_today: number;
  coordinators_missing_today: string[];
  settlements_overdue: number;
  advances_pending_approval: number;
  fund_requisitions_pending: number;
  schedule_items_late: number;
  po_deliveries_overdue: number;
  po_open_value: number;
}

const nu = (n: number) => "Nu. " + new Intl.NumberFormat("en-IN", { maximumFractionDigits: 0 }).format(n ?? 0);
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

function siteAlerts(s: SiteSummary): string[] {
  const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;
  const alerts: string[] = [];
  if (s.settlements_overdue > 0) alerts.push(`${plural(s.settlements_overdue, "advance")} overdue for settlement`);
  if (s.cash_low) alerts.push(`cash low (${nu(s.cash_balance)} left)`);
  if (s.cost_variance < 0) alerts.push(`over cost by ${nu(-s.cost_variance)}`);
  if (s.advances_pending_approval > 0) alerts.push(`${plural(s.advances_pending_approval, "advance")} waiting for your approval`);
  if (s.fund_requisitions_pending > 0) alerts.push(`${plural(s.fund_requisitions_pending, "fund requisition")} waiting for approval`);
  if (s.coordinators_missing_today?.length) alerts.push(`not submitted today: ${s.coordinators_missing_today.join(", ")}`);
  if (s.schedule_items_late > 0) alerts.push(`${plural(s.schedule_items_late, "BOQ item")} behind schedule`);
  if (s.po_deliveries_overdue > 0) alerts.push(`${plural(s.po_deliveries_overdue, "purchase order")} past delivery date`);
  return alerts;
}

function buildOwnerSummary(payload: Record<string, unknown>): { subject: string; body: string; html: string } {
  const sites = (payload.sites ?? []) as SiteSummary[];
  const date = String(payload.date ?? "");
  const flagged = sites.filter((s) => siteAlerts(s).length > 0).length;
  const subject = `SiteTracker daily summary ${date}: ${sites.length} site${sites.length === 1 ? "" : "s"}` +
    (flagged ? `, ${flagged} need${flagged === 1 ? "s" : ""} attention` : ", all clear");

  const text = sites.map((s) => {
    const alerts = siteAlerts(s);
    return [
      s.name,
      `  Work done ${s.physical_progress_pct}% · money spent ${s.financial_progress_pct}% · cash ${nu(s.cash_balance)} · on order ${nu(s.po_open_value)}`,
      `  Submitted today: ${s.submitted_today}/${s.coordinators_on_duty}`,
      ...(alerts.length ? alerts.map((a) => `  ! ${a}`) : ["  All clear."]),
    ].join("\n");
  }).join("\n\n");

  const rows = sites.map((s) => {
    const alerts = siteAlerts(s);
    return `<tr><td style="padding:12px 0;border-top:1px solid #e5e0d6;vertical-align:top">
      <div style="font-weight:600;font-size:15px">${esc(s.name)}</div>
      <div style="color:#756d64;font-size:13px;margin-top:2px">Work done ${s.physical_progress_pct}% · spent ${s.financial_progress_pct}% · cash ${nu(s.cash_balance)} · on order ${nu(s.po_open_value)} · submitted today ${s.submitted_today}/${s.coordinators_on_duty}</div>
      ${alerts.length
        ? `<ul style="margin:6px 0 0;padding-left:18px;font-size:14px;color:#b62f1c">${alerts.map((a) => `<li>${esc(a)}</li>`).join("")}</ul>`
        : `<div style="margin-top:6px;font-size:14px;color:#245840">All clear.</div>`}
    </td></tr>`;
  }).join("");
  const html = `<div style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;max-width:600px;color:#1c1815">
    <h2 style="margin:0 0 4px">Daily summary</h2>
    <div style="color:#756d64;font-size:14px">${esc(date)} · ${sites.length} site${sites.length === 1 ? "" : "s"}</div>
    <table style="width:100%;border-collapse:collapse;margin-top:12px">${rows}</table>
    <p style="color:#756d64;font-size:12px;margin-top:16px">Open SiteTracker for details. Sent at 7 pm Bhutan time to Company Owners and Admins.</p>
  </div>`;

  return { subject, body: `Daily summary ${date}\n\n${text}`, html };
}

function buildMessage(eventType: string, payload: Record<string, unknown>): { subject: string; body: string; html?: string } {
  switch (eventType) {
    case "daily_owner_summary":
      return buildOwnerSummary(payload);
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
  if (!ACCEPTED_KEYS.has(apiKeyHeader)) {
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

  if (!resend) {
    return new Response(JSON.stringify({ error: "RESEND_API_KEY is not set for this function" }), { status: 500 });
  }

  const { subject, body: emailBody, html } = buildMessage(body.event_type, body.payload);

  try {
    // The Resend SDK reports API errors (bad key, unverified sender domain)
    // in the result instead of throwing.
    const { error } = await resend.emails.send({
      from: ACCOUNTS_EMAIL_FROM,
      to: [profile.email],
      subject,
      text: emailBody,
      ...(html ? { html } : {}),
    });
    if (error) {
      console.error("send-notification: Resend refused the email", error);
      return new Response(JSON.stringify({ error: "Resend refused the email", details: error }), { status: 502 });
    }
    return new Response(JSON.stringify({ status: "sent" }), { status: 200 });
  } catch (err) {
    console.error("send-notification: Resend send failed", err);
    return new Response(JSON.stringify({ error: "Failed to send email", details: String(err) }), { status: 500 });
  }
});
