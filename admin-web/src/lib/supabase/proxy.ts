import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

import { supabaseConfig } from "./config";

export async function refreshSupabaseSession(request: NextRequest) {
  let response = NextResponse.next({ request });
  const { url, key } = supabaseConfig();
  const supabase = createServerClient(url, key, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll: (values) => {
        for (const { name, value } of values) request.cookies.set(name, value);
        response = NextResponse.next({ request });
        for (const { name, value, options } of values) response.cookies.set(name, value, options);
      },
    },
  });

  await supabase.auth.getClaims();
  response.headers.set("Cache-Control", "private, no-store");
  return response;
}
