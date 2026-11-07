export async function onRequestPost(context) {
  const json = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });
  try {
    let body;
    try { body = await context.request.json(); }
    catch (e) {
      const f = await context.request.formData();
      body = Object.fromEntries(['name','email','mobile','postcode','dob','guardian_name','guardian_email','guardian_phone','website'].map(k => [k, f.get(k)]));
    }

    // Trim and length-limit everything; reject obviously bad input before it reaches the database
    const clean = (v, max) => (typeof v === 'string' ? v.trim().slice(0, max) : '');
    const row = {
      name: clean(body.name, 100),
      email: clean(body.email, 254).toLowerCase(),
      mobile: clean(body.mobile, 30) || null,
      postcode: clean(body.postcode, 12) || null,
      dob: /^\d{4}-\d{2}-\d{2}$/.test(body.dob || '') ? body.dob : null,
      guardian_name: clean(body.guardian_name, 100) || null,
      guardian_email: clean(body.guardian_email, 254) || null,
      guardian_phone: clean(body.guardian_phone, 30) || null
    };
    // Spam trap: bots fill the hidden 'website' box. Pretend it worked, store nothing.
    if (body.website) return json({ success: true });

    // Under-18s must name a parent or guardian (server-side check; the form also checks)
    if (row.dob) {
      const d = new Date(row.dob), t = new Date();
      let age = t.getFullYear() - d.getFullYear();
      if (t.getMonth() < d.getMonth() || (t.getMonth() === d.getMonth() && t.getDate() < d.getDate())) age--;
      if (age >= 0 && age < 18 && (!row.guardian_name || !(row.guardian_email || row.guardian_phone))) {
        return json({ success: false, error: "Please give a parent or guardian name and an email or phone number." }, 400);
      }
    }
    if (!row.name || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(row.email)) {
      return json({ success: false, error: "Please give your name and a valid email address." }, 400);
    }

    const SUPABASE_URL = 'https://onepmhddrqmvhyhagkth.supabase.co';
    const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9uZXBtaGRkcnFtdmh5aGFna3RoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0NTU4MTQsImV4cCI6MjEwODAzMTgxNH0.puqAvMFt-SpG6cVedHFVSrLIx4NifALgbcJka1aXbfw';

    // Writes to the write-only 'enquiries' table. The public can add rows but never read them.
    const res = await fetch(`${SUPABASE_URL}/rest/v1/enquiries`, {
      method: 'POST',
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
        'Content-Type': 'application/json',
        'Prefer': 'return=minimal'
      },
      body: JSON.stringify(row)
    });

    if (!res.ok) {
      return json({ success: false, error: "Sorry, we could not record your enquiry. Please try again or contact us." }, 400);
    }
    return json({ success: true });
  } catch (err) {
    return json({ success: false, error: "Server error. Please try again later." }, 500);
  }
}
