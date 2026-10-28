// Supabase Edge Function: digistore24-ipn
// Required Supabase secrets:
// DIGISTORE_IPN_PASSPHRASE, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function sha512Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-512", bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("").toUpperCase();
}

async function verifySignature(params: Record<string, string>, passphrase: string): Promise<boolean> {
  const received = params.sha_sign ?? params.SHASIGN ?? "";
  if (!received || !passphrase) return false;

  for (const uppercaseKeys of [false, true]) {
    const entries = Object.entries(params)
      .filter(([key]) => !["SHA_SIGN", "SHASIGN"].includes(key.toUpperCase()))
      .map(([key, value]) => ({ key: uppercaseKeys ? key.toUpperCase() : key, value }))
      .sort((a, b) => a.key < b.key ? -1 : a.key > b.key ? 1 : 0);

    let signed = "";
    for (const { key, value } of entries) {
      if (value === undefined || value === null || value === "") continue;
      signed += key + "=" + value + passphrase;
    }

    const expected = await sha512Hex(signed);
    if (safeEqual(received.toUpperCase(), expected)) return true;
  }
  return false;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  // Used by IPN connection checks. It does not grant tokens.
  if (req.method === "GET") return new Response("OK", { status: 200 });

  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  try {
    const raw = await req.text();
    const contentType = req.headers.get("content-type") || "";
    const params: Record<string, string> = {};

    if (contentType.includes("application/json")) {
      const parsed = JSON.parse(raw);
      for (const [key, value] of Object.entries(parsed)) {
        if (value !== undefined && value !== null) params[key] = String(value);
      }
    } else {
      for (const [key, value] of new URLSearchParams(raw)) params[key] = value;
    }

    const event = params.event || "";
    if (event === "connection_test") return new Response("OK", { status: 200 });

    const passphrase = Deno.env.get("DIGISTORE_IPN_PASSPHRASE") || "";
    if (!await verifySignature(params, passphrase)) {
      return new Response("Invalid IPN signature", { status: 403 });
    }

    const orderId = params.order_id || "";
    const orderItemId = params.order_item_id || "";
    const productId = params.product_id || "";
    const buyerEmail = params.email || params.buyer_email || "";
    const paySequenceNo = Number.parseInt(params.pay_sequence_no || "0", 10) || 0;
    const transactionId = params.transaction_id || "";
    // Digistore24 documents transaction_id as unique for each payment/refund/chargeback.
    const transactionKey = transactionId || (orderId && productId ? orderId + ":" + productId + ":" + paySequenceNo : "");

    if (!orderId || !productId || !transactionKey) {
      return new Response("Missing order fields", { status: 400 });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    if (!supabaseUrl || !serviceRoleKey) {
      console.error("Supabase secrets are not configured");
      return new Response("Server configuration error", { status: 500 });
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data, error } = await supabase.rpc("credit_digistore24_order", {
      p_transaction_key: transactionKey,
      p_order_id: orderId,
      p_order_item_id: orderItemId,
      p_pay_sequence_no: paySequenceNo,
      p_product_id: productId,
      p_buyer_email: buyerEmail,
      p_event: event,
    });

    if (error) {
      console.error("Digistore24 fulfillment failed:", error.message);
      return new Response("Fulfillment failed", { status: 500 });
    }

    console.log("Digistore24 IPN processed:", { event, productId, result: data });
    return new Response("OK", { status: 200 });
  } catch (err) {
    console.error("Digistore24 IPN error:", err);
    return new Response("Invalid request", { status: 400 });
  }
});
