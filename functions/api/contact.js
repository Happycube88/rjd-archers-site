// Contact us form: saves the message (committee-only table) and, if Resend is set up, emails the club.
// Secrets live in Cloudflare (Settings > Variables and Secrets), never in this repo:
//   RESEND_API_KEY  (secret)   CONTACT_TO (optional, default rjdarchers.members@gmail.com)   CONTACT_FROM (optional)
const TOPICS = ['Beginners Course', 'Club Membership', 'Tournaments', 'General Enquiry'];
const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

export async function onRequestPost(context) {
  const json = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json' } });
  try {
    let body;
    try { body = await context.request.json(); } catch (e) { return json({ success: false, error: 'Bad request.' }, 400); }
    if (body.website) return json({ success: true });                       // spam trap: bots fill the hidden box
    const clean = (v, max) => (typeof v === 'string' ? v.trim().slice(0, max) : '');
    const row = { name: clean(body.name, 100), email: clean(body.email, 254).toLowerCase(), topic: clean(body.topic, 40), message: clean(body.message, 3000) };
    if (!row.name || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(row.email)) return json({ success: false, error: 'Please give your name and a valid email address.' }, 400);
    if (!TOPICS.includes(row.topic)) return json({ success: false, error: 'Please choose what your enquiry is about.' }, 400);
    if (!row.message) return json({ success: false, error: 'Please type your message.' }, 400);

    const SUPABASE_URL = 'https://onepmhddrqmvhyhagkth.supabase.co';
    const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9uZXBtaGRkcnFtdmh5aGFna3RoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0NTU4MTQsImV4cCI6MjEwODAzMTgxNH0.puqAvMFt-SpG6cVedHFVSrLIx4NifALgbcJka1aXbfw';
    const res = await fetch(`${SUPABASE_URL}/rest/v1/contact_messages`, {
      method: 'POST',
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
      body: JSON.stringify(row)
    });
    if (!res.ok) return json({ success: false, error: 'Sorry, we could not send your message. Please try again.' }, 400);

    // Email the club if Resend is configured. A failure here must not lose the message: it is already saved.
    const env = context.env || {};
    if (env.RESEND_API_KEY) {
      try {
        await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            from: env.CONTACT_FROM || 'RJD Archers website <onboarding@resend.dev>',
            to: [env.CONTACT_TO || 'rjdarchers.members@gmail.com'],
            reply_to: row.email,
            subject: `Website enquiry: ${row.topic} from ${row.name}`,
            html: `<p><b>${esc(row.name)}</b> (${esc(row.email)}) asked about <b>${esc(row.topic)}</b>:</p><p>${esc(row.message).replace(/\n/g, '<br>')}</p><p style="color:#666">Saved in Committee area, Messages. Reply to this email to answer them.</p>`
          })
        });
      } catch (e) { /* ignore */ }
    }
    return json({ success: true });
  } catch (err) {
    return json({ success: false, error: 'Server error. Please try again later.' }, 500);
  }
}
