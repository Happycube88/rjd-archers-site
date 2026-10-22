export async function onRequestPost(context) {
  try {
    // Safely parse incoming request data
    let body;
    try {
      body = await context.request.json();
    } catch (e) {
      const formData = await context.request.formData();
      body = {
        name: formData.get('name'),
        email: formData.get('email'),
        mobile: formData.get('mobile')
      };
    }

    if (!body || !body.name || !body.email) {
      return new Response(JSON.stringify({ success: false, error: "Missing required fields (name or email)." }), {
        status: 400,
        headers: { "Content-Type": "application/json" }
      });
    }

    const SUPABASE_URL = 'https://onepmhddrqmvhyehagkth.supabase.co';
    const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9uZXBtaGRkcnFtdmh5aGFna3RoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0NTU4MTQsImV4cCI6MjEwODAzMTgxNH0.puqAvMFt-SpG6cVedHFVSrLIx4NifALgbcJka1aXbfw';

    // Execute request from Cloudflare's server to Supabase
    const supabaseRes = await fetch(`${SUPABASE_URL}/rest/v1/members`, {
      method: 'POST',
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
        'Content-Type': 'application/json',
        'Prefer': 'return=representation'
      },
      body: JSON.stringify({
        name: body.name,
        email: body.email,
        mobile: body.mobile || '',
        membertype: 'beginner'
      })
    });

    const responseText = await supabaseRes.text();
    let result;
    try {
      result = JSON.parse(responseText);
    } catch (err) {
      result = { message: responseText };
    }

    if (!supabaseRes.ok) {
      return new Response(JSON.stringify({ success: false, error: result.message || JSON.stringify(result) }), {
        status: 400,
        headers: { "Content-Type": "application/json" }
      });
    }

    return new Response(JSON.stringify({ success: true, data: result }), {
      status: 200,
      headers: { "Content-Type": "application/json" }
    });

  } catch (err) {
    // Catch-all to ensure 1016 never triggers
    return new Response(JSON.stringify({ success: false, error: "Server Exception: " + err.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" }
    });
  }
}
