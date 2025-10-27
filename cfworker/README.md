# Hole Punch Cloudflare Worker

Attempt to have a Cloudflare Worker used to allow "hole punch" access to images protected by Cloudflare access on the main domain.

Scope:

- API endpoint for exposing/hiding images on admin hostname
- - Require protection on these endpoints via CF Access by validating JWT header from Access
- - - probably email allowlist for extra protection
- images exposed are available on public hostname
- - likely `/images/:secret/:filename`
- - not protected by access
- - requires filename to match DO filename

How images Are exposed:

- api endpoint PUT /exposed/:id
- - params (probably):
- - - filename (from philomena)
- - How:
- - - worker will take above and store in durable object
- - - also store "inputPost" which is raw input post json data (maybe stringified if required)
- - - sanitize filename (we expect it to have query params) and store in filename field
- - - also store field name "secret", generated on the fly (maybe 20chars of random sha256)
- - - returns secret and/or full URI to image
- api endpoint DELETE /exposed/:id
- api endpoint GET /exposed/:id
- - 404 if not found

Philomena parts:

- admin button in philomena to perform XHR call from frontend to admin hostname expose endpoint
- - show or open newtab to image
- another admin button to remove
- maybe a third to check
