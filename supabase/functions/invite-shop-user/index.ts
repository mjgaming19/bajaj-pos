// BAJAJ secure user invitation endpoint
// Deploy with Supabase CLI after setting SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY secrets.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const respond = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond({ error: "Method not allowed." }, 405);

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) return respond({ error: "Server is not configured." }, 500);

    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token) return respond({ error: "Sign in is required." }, 401);

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: authData, error: authError } = await admin.auth.getUser(token);
    if (authError || !authData.user) return respond({ error: "Your session is invalid or expired." }, 401);
    const actorId = authData.user.id;

    const body = await req.json();
    const email = String(body.email || "").trim().toLowerCase();
    const shopId = String(body.shop_id || "");
    const role = String(body.role || "");
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return respond({ error: "Enter a valid email address." }, 400);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(shopId)) return respond({ error: "A valid shop is required." }, 400);
    if (!["sub_admin", "pos_user"].includes(role)) return respond({ error: "Invalid shop role." }, 400);

    const { data: platformAdmin, error: platformError } = await admin
      .from("platform_admins").select("user_id").eq("user_id", actorId).maybeSingle();
    if (platformError) return respond({ error: "Could not verify platform permissions." }, 500);

    const { data: membership, error: membershipError } = await admin
      .from("shop_members").select("role").eq("shop_id", shopId).eq("user_id", actorId).maybeSingle();
    if (membershipError) return respond({ error: "Could not verify shop permissions." }, 500);

    const isPlatformAdmin = !!platformAdmin;
    const isShopAdmin = membership?.role === "sub_admin";
    if (!isPlatformAdmin && !isShopAdmin) return respond({ error: "You cannot invite users to this shop." }, 403);
    if (!isPlatformAdmin && role !== "pos_user") return respond({ error: "Sub-admins may invite POS users only." }, 403);

    const { data: shop, error: shopError } = await admin.from("shops").select("id,name").eq("id", shopId).maybeSingle();
    if (shopError || !shop) return respond({ error: "Shop not found." }, 404);

    const { data: inviteData, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email);
    if (inviteError || !inviteData.user) {
      return respond({ error: inviteError?.message || "Invitation could not be created." }, 400);
    }

    const { error: assignError } = await admin.from("shop_members").upsert(
      { shop_id: shopId, user_id: inviteData.user.id, role },
      { onConflict: "shop_id,user_id" },
    );
    if (assignError) {
      return respond({
        error: "The invitation was created, but shop access could not be assigned. Ask the platform administrator to assign this user.",
        invited_user_id: inviteData.user.id,
      }, 500);
    }

    return respond({ success: true, email, shop: shop.name, role });
  } catch (error) {
    return respond({ error: error instanceof Error ? error.message : "Unexpected server error." }, 500);
  }
});
