# Agent Rules

- Do not invent missing infrastructure, image names, domains, credentials, or deployment steps.
- Do not overengineer the deploy flow. Prefer the smallest change that matches the existing Makefile, env files, and stack layout.
- Do not build images, rewrite services, or add new moving parts unless the architect explicitly asks for it.
- Production HTTP services are expected to listen on port 80. Do not change stack service ports or Traefik service ports without explicit architect approval.
- If a command fails, read the exact error and verify the current state before changing anything.
- If the next step is unclear, risky, or depends on unavailable access, stop and ask the architect for advice.
- Keep server state clean. Remove temporary files, partial artifacts, and accidental local images before continuing.
- Preserve existing secrets, env files, volumes, and user data unless the architect explicitly asks to change them.
