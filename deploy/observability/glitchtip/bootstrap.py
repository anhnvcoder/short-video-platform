# Creates what the services and the drills need in GlitchTip, through the image's ORM. GlitchTip, not Sentry: sentry.io
# is blocked on this machine on purpose, self-hosted Sentry needs far more RAM than the lab has, and GlitchTip speaks
# the Sentry protocol, so the SDKs only need another DSN to switch
# (docs/adr/0011-observability-stage3.md, section 7): the admin user, organization `svp`, team and
# project `svp` with its DSN, and the API token `svp-drill` (event:read, project:read).
# Idempotent: a second run creates nothing and changes no key, token or password.
#
# Run inside the glitchtip-init container: python manage.py shell < /init/bootstrap.py
# Reads GLITCHTIP_ADMIN_EMAIL and GLITCHTIP_ADMIN_PASSWORD. When SVP_GLITCHTIP_OUT names a file,
# writes the DSN and the token there (mode 600, `dsn=` and `token=` lines) for
# deploy/observability/glitchtip/init.sh; they are never printed. Prints only object counts.
import os

from allauth.account.models import EmailAddress

from apps.api_tokens.models import APIToken
from apps.organizations_ext.models import Organization, OrganizationUser
from apps.projects.models import Project, ProjectKey
from apps.teams.models import Team
from apps.users.models import User

SLUG = "svp"
TOKEN_LABEL = "svp-drill"
TOKEN_SCOPES = ["event:read", "project:read"]

email = os.environ["GLITCHTIP_ADMIN_EMAIL"]
password = os.environ["GLITCHTIP_ADMIN_PASSWORD"]
if not email or not password:
    raise SystemExit("bootstrap: GLITCHTIP_ADMIN_EMAIL and GLITCHTIP_ADMIN_PASSWORD must be set")

# 1. Admin user. The password is set only when the user is created, so a password changed in the
# UI stays.
admin, created = User.objects.get_or_create(email=email)
if created:
    admin.set_password(password)
    admin.is_staff = True
    admin.is_superuser = True
    admin.save()
EmailAddress.objects.get_or_create(
    user=admin, email=email, defaults={"primary": True, "verified": True}
)

# 2. Organization, with the admin as a member (the first member becomes its owner).
org, _ = Organization.objects.get_or_create(slug=SLUG, defaults={"name": SLUG})
org_user = OrganizationUser.objects.filter(organization=org, user=admin).first()
if org_user is None:
    org_user = org.add_user(admin)

# 3. One project for every service (the `service` tag tells them apart), in team `svp`. Creating
# the project creates its key.
project, _ = Project.objects.get_or_create(
    organization=org, slug=SLUG, defaults={"name": SLUG, "platform": "go"}
)
team, _ = Team.objects.get_or_create(organization=org, slug=SLUG)
team.members.add(org_user)
team.projects.add(project)
key = ProjectKey.objects.filter(project=project, is_active=True).order_by("pk").first()
if key is None:
    raise SystemExit("bootstrap: project svp has no active key")
dsn = key.get_dsn()
if not dsn:
    raise SystemExit("bootstrap: GLITCHTIP_DOMAIN gives no DSN")

# 4. Read-only API token of the drills. The model generates a random token.
token, _ = APIToken.objects.get_or_create(user=admin, label=TOKEN_LABEL)
token.add_permissions(TOKEN_SCOPES)

out = os.environ.get("SVP_GLITCHTIP_OUT")
if out:
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(f"dsn={dsn}\ntoken={token.token}\n")

print(
    "bootstrap: users={} organizations={} members={} teams={} projects={} active_keys={} tokens={}".format(
        User.objects.filter(email=email).count(),
        Organization.objects.filter(slug=SLUG).count(),
        OrganizationUser.objects.filter(organization=org, user=admin).count(),
        Team.objects.filter(organization=org, slug=SLUG).count(),
        Project.objects.filter(organization=org, slug=SLUG).count(),
        ProjectKey.objects.filter(project=project, is_active=True).count(),
        APIToken.objects.filter(user=admin, label=TOKEN_LABEL).count(),
    )
)
