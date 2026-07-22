# Security Policy / Política de seguridad

## Reporting / Cómo reportar

**Do not open public issues for vulnerabilities.** Use GitHub's private
vulnerability reporting ("Report a vulnerability" under the Security tab of
this repository). You will get an acknowledgment within a week.

**No abras issues públicos para vulnerabilidades.** Usa el reporte privado de
GitHub (pestaña Security → "Report a vulnerability"). Respuesta en menos de
una semana.

## Scope / Alcance

This project generates and operates a harness where **AI agents hold real
permissions** (git push via gates, secrets injection, deploy watching). That
makes certain bugs security-critical, not cosmetic. Report as vulnerabilities:

- **Gate/hook bypasses**: any way an agent (or a crafted ticket/prompt) can
  reach `git push origin main` without passing through `ship.sh`, or edit
  `ship.sh`/hooks/`settings.json` despite `guard-canonical`.
- **Secret exfiltration paths**: any flow where secret VALUES (not references)
  can reach chat context, commits, logs, or the panel, including redaction
  bypasses in `emit.sh` or the panel server.
- **Prompt-injection escalations**: ticket/README/dependency content that can
  expand an agent's permissions beyond its task (the harness treats ticket
  bodies as untrusted data; breaks in that envelope are vulnerabilities).
- **Panel**: anything reachable from non-localhost, CSRF-token bypasses, or
  DNS-rebinding despite the Host check.
- **Policy engine**: forging `state.json`/verdicts/evidence that
  `harness-policy.py` or `evidence.py` accept as valid.

Hardening suggestions that don't cross a trust boundary (e.g. stricter
defaults) are welcome as regular issues.

## Supported versions

The latest release. The plugin's update mode (`/harness-init .`) propagates
fixes to installed instances; security fixes are called out in the CHANGELOG.
